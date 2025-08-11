// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Interfaces/IAerodrome.sol";
import "./Interfaces/IMetaMorpho.sol";
import "./Interfaces/IBundler.sol";
import "./Interfaces/IERC20Extended.sol";

/**
 * @title UserVault
 * @dev Individual user vault contract for yield optimization with asset swapping and bundler integration
 */
contract UserVault_V3 is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Aerodrome contract addresses
    address public constant AERODROME_ROUTER =
        0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address public constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    // Bundler addresses
    address public constant ADAPTER_ADDRESS = 0xb98c948CFA24072e58935BC004a8A7b376AE746A;
    address public constant BUNDLER_ADDRESS = 0x6BFd8137e702540E7A42B74178A4a49Ba43920C4;
    
    IBundler3 public constant bundler = IBundler3(BUNDLER_ADDRESS);

    // State variables
    address public immutable owner;
    address public admin;
    address public immutable asset; // Primary asset (USDC)
    address public currentVault;
    bool public hasInitialDeposit;

    uint256 public totalDeposited;
    uint256 public lastDepositTime;
    uint256 public constant DEPOSIT_INTERVAL = 24 hours;
    uint256 public constant SLIPPAGE_TOLERANCE = 500; // 5% in basis points

    address public revenueAddress;
    uint256 public feePercentage; // Fee percentage in basis points (e.g., 100 = 1%)
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // Maximum 10% fee
    uint256 public totalFeesCollected;

    // Enhanced fee configurations
    uint256 public constant REBALANCE_FEE_PERCENTAGE = 500; // 5% on rebalance profits
    uint256 public constant MIN_PROFIT_FOR_FEE = 10e6; // $10 in USDC (6 decimals)
    uint256 public initialDepositAmount; // Initial deposit amount set during deployment
    bool public initialDepositMade; // Track if initial deposit has been made

    mapping(address => bool) public isAllowedVault;
    address[] public allowedVaults;

    // Events
    event InitialDeposit(address indexed vault, uint256 amount);
    event PeriodicDeposit(
        address indexed fromVault,
        address indexed toVault,
        uint256 amount
    );
    event Withdrawal(
        address indexed vault,
        address indexed recipient,
        uint256 amount
    );
    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event Rebalanced(
        address indexed fromVault,
        address indexed toVault,
        uint256 amount
    );
    event AssetSwapped(
        address indexed fromAsset,
        address indexed toAsset,
        uint256 amountIn,
        uint256 amountOut
    );

    event RevenueAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );
    event FeePercentageUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollected(
        address indexed vault,
        uint256 feeAmount,
        uint256 userAmount
    );
    event RebalanceFeeCollected(
        address indexed fromVault,
        address indexed toVault,
        uint256 profit,
        uint256 feeAmount
    );
    event InitialDepositExecuted(address indexed vault, uint256 amount);

    constructor(
        address _owner,
        address _admin,
        address _asset,
        address[] memory _initialVaults,
        address _revenueAddress,
        uint256 _feePercentage,
        uint256 _initialDepositAmount
    ) {
        require(_owner != address(0), "Invalid owner");
        require(_admin != address(0), "Invalid admin");
        require(_asset != address(0), "Invalid asset");
        require(_initialVaults.length > 0, "No initial vaults");
        require(_revenueAddress != address(0), "Invalid revenue address");
        require(_feePercentage <= MAX_FEE_PERCENTAGE, "Fee too high");
        require(_initialDepositAmount > 0, "Initial deposit must be positive");

        owner = _owner;
        admin = _admin;
        asset = _asset;
        revenueAddress = _revenueAddress;
        feePercentage = _feePercentage;
        initialDepositAmount = _initialDepositAmount;

        // Add initial vaults to whitelist
        for (uint256 i = 0; i < _initialVaults.length; i++) {
            require(_initialVaults[i] != address(0), "Invalid vault address");
            isAllowedVault[_initialVaults[i]] = true;
            allowedVaults.push(_initialVaults[i]);
        }
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyOwnerOrAdmin() {
        require(
            msg.sender == owner || msg.sender == admin,
            "Only owner or admin"
        );
        _;
    }

    modifier onlyAllowedVault(address vault) {
        require(isAllowedVault[vault], "Vault not allowed");
        _;
    }

    modifier onlyAfterInterval() {
        require(
            block.timestamp >= lastDepositTime + DEPOSIT_INTERVAL ||
                lastDepositTime == 0,
            "Deposit interval not met"
        );
        _;
    }

    /**
     * @dev NEW: Deposit to vault using bundler
     * @param vault The vault address to deposit into
     * @param amount The amount of assets to deposit
     * @param vaultAsset The asset token address for the vault
     */
    function _depositToVaultViaBundler(
        address vault,
        uint256 amount,
        address vaultAsset
    ) internal {
        // Approve the adapter to spend tokens
        IERC20(vaultAsset).approve(ADAPTER_ADDRESS, amount);
        
        // Create calls array
        Call[] memory calls = new Call[](2);
        
        // First call: erc20TransferFrom - transfer tokens from this contract to adapter
        calls[0] = Call({
            to: ADAPTER_ADDRESS,
            data: abi.encodeWithSelector(
                bytes4(0xd96ca0b9), // erc20TransferFrom selector
                vaultAsset,          // token address
                ADAPTER_ADDRESS,     // receiver (adapter)
                amount              // amount
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        
        // Second call: erc4626Deposit - deposit into vault
        calls[1] = Call({
            to: ADAPTER_ADDRESS,
            data: abi.encodeWithSelector(
                bytes4(0x6ef5eeae), // erc4626Deposit selector
                vault,               // vault address
                amount,              // assets
                type(uint256).max,   // maxSharePriceE27
                address(this)       // receiver (this contract receives the shares)
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        
        // Execute multicall
        bundler.multicall(calls);
    }

    /**
     * @dev NEW: Redeem from vault using bundler
     * @param vault The vault address to redeem from
     * @param shares The amount of shares to redeem
     * @return The amount of assets received
     */
    function _redeemFromVaultViaBundler(address vault, uint256 shares)
        internal
        returns (uint256)
    {
        // Get the amount of assets we expect to receive
        uint256 expectedAssets = IMetaMorpho(vault).previewRedeem(shares);
        
        // Approve the adapter to spend the shares
        IMetaMorpho(vault).approve(ADAPTER_ADDRESS, shares);
        
        // Create calls array
        Call[] memory calls = new Call[](2);
        
        // First call: erc20TransferFrom - transfer vault shares from this contract to adapter
        calls[0] = Call({
            to: ADAPTER_ADDRESS,
            data: abi.encodeWithSelector(
                bytes4(0xd96ca0b9), // erc20TransferFrom selector
                vault,               // token address (vault contract = shares token)
                ADAPTER_ADDRESS,     // receiver (adapter needs the shares)
                shares              // amount of shares
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        
        // Second call: erc4626Redeem - redeem from vault
        calls[1] = Call({
            to: ADAPTER_ADDRESS,
            data: abi.encodeWithSelector(
                bytes4(0xa7f6e606), // erc4626Redeem selector
                vault,               // vault address
                shares,              // shares to redeem
                0,                   // minSharePriceE27 (using 0 for no minimum)
                address(this),       // receiver of assets (this contract)
                ADAPTER_ADDRESS      // owner of shares (adapter has them now)
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        
        // Execute multicall
        bundler.multicall(calls);
        
        // Return the expected assets (you might want to check actual balance change)
        return expectedAssets;
    }

    /**
     * @dev Internal function to swap tokens using Aerodrome with optimal pool selection
     */
    function _swapTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        require(tokenIn != tokenOut, "Same token");
        require(amountIn > 0, "Zero amount");

        // Check both stable and volatile pools
        address stablePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            true
        );
        address volatilePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            false
        );

        require(
            stablePool != address(0) || volatilePool != address(0),
            "No pools exist"
        );

        // Determine which pool to use based on expected output
        bool useStablePool = _shouldUseStablePool(
            tokenIn,
            tokenOut,
            amountIn,
            stablePool,
            volatilePool
        );

        // Approve router to spend tokens
        IERC20(tokenIn).approve(AERODROME_ROUTER, amountIn);

        // Prepare route with selected pool type
        Route[] memory routes = new Route[](1);
        routes[0] = Route({
            from: tokenIn,
            to: tokenOut,
            stable: useStablePool,
            factory: AERODROME_FACTORY
        });

        // Get expected output amount
        uint256[] memory expectedAmounts = IAerodromeRouter(AERODROME_ROUTER)
            .getAmountsOut(amountIn, routes);
        uint256 minAmountOut = (expectedAmounts[1] *
            (10000 - SLIPPAGE_TOLERANCE)) / 10000;

        // Execute swap
        uint256[] memory amounts = IAerodromeRouter(AERODROME_ROUTER)
            .swapExactTokensForTokens(
                amountIn,
                minAmountOut,
                routes,
                address(this),
                block.timestamp + 300
            );

        amountOut = amounts[1];

        emit AssetSwapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @dev Determines which pool (stable or volatile) should be used for the swap
     */
    function _shouldUseStablePool(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address stablePool,
        address volatilePool
    ) internal view returns (bool useStablePool) {
        // If only one pool exists, use it
        if (stablePool == address(0) && volatilePool != address(0)) {
            return false; // Use volatile pool
        }
        if (volatilePool == address(0) && stablePool != address(0)) {
            return true; // Use stable pool
        }

        // If both pools exist, compare expected outputs
        uint256 stableOutput = 0;
        uint256 volatileOutput = 0;

        // Get expected output from stable pool
        if (stablePool != address(0)) {
            stableOutput = _getPoolOutput(tokenIn, tokenOut, amountIn, true);
        }

        // Get expected output from volatile pool
        if (volatilePool != address(0)) {
            volatileOutput = _getPoolOutput(tokenIn, tokenOut, amountIn, false);
        }

        // Use the pool that gives better output
        // Add a small bias towards stable pools (e.g., 0.1%) for similar outputs
        uint256 stableBias = (stableOutput * 1001) / 1000; // 0.1% bias

        return stableBias >= volatileOutput;
    }

    /**
     * @dev Get expected output from a specific pool type
     */
    function _getPoolOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool stable
    ) internal view returns (uint256 expectedOutput) {
        // Check if pool exists
        address pool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            stable
        );
        if (pool == address(0)) {
            return 0;
        }

        // Prepare route
        Route[] memory routes = new Route[](1);
        routes[0] = Route({
            from: tokenIn,
            to: tokenOut,
            stable: stable,
            factory: AERODROME_FACTORY
        });

        // Try to get amounts out
        try
            IAerodromeRouter(AERODROME_ROUTER).getAmountsOut(amountIn, routes)
        returns (uint256[] memory amounts) {
            return amounts[1];
        } catch {
            return 0; // Return 0 if call fails (e.g., insufficient liquidity)
        }
    }

    /**
     * @dev Updated view function to get estimated swap output with optimal pool selection
     */
    function _getEstimatedSwapOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        if (tokenIn == tokenOut || amountIn == 0) return amountIn;

        // Check both pool types
        address stablePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            true
        );
        address volatilePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            false
        );

        if (stablePool == address(0) && volatilePool == address(0)) return 0;

        // Determine which pool to use
        bool useStablePool = _shouldUseStablePool(
            tokenIn,
            tokenOut,
            amountIn,
            stablePool,
            volatilePool
        );

        // Get output from selected pool
        return _getPoolOutput(tokenIn, tokenOut, amountIn, useStablePool);
    }

    /**
     * @dev Update revenue address
     */
    function updateRevenueAddress(address newRevenueAddress)
        external
        onlyAdmin
    {
        require(newRevenueAddress != address(0), "Invalid revenue address");
        address oldAddress = revenueAddress;
        revenueAddress = newRevenueAddress;
        emit RevenueAddressUpdated(oldAddress, newRevenueAddress);
    }

    /**
     * @dev Update fee percentage
     */
    function updateFeePercentage(uint256 newFeePercentage) external onlyAdmin {
        require(newFeePercentage <= MAX_FEE_PERCENTAGE, "Fee too high");
        uint256 oldFee = feePercentage;
        feePercentage = newFeePercentage;
        emit FeePercentageUpdated(oldFee, newFeePercentage);
    }

    /**
     * @dev Calculate fee amount from profit with minimum profit threshold
     */
    function calculateFeeFromProfit(uint256 totalAmount)
        public
        view
        returns (uint256 feeAmount, uint256 userAmount)
    {
        if (
            !hasInitialDeposit ||
            totalDeposited == 0 ||
            totalAmount <= totalDeposited
        ) {
            // NO PROFIT = NO FEE (includes losses and break-even)
            return (0, totalAmount);
        }

        // Calculate profit
        uint256 profit = totalAmount - totalDeposited;

        // Only charge fee if profit is greater than $10
        if (profit <= MIN_PROFIT_FOR_FEE) {
            return (0, totalAmount);
        }

        // Calculate fee ONLY on profit portion
        feeAmount = (profit * feePercentage) / 10000;
        userAmount = totalAmount - feeAmount;

        return (feeAmount, userAmount);
    }

    /**
     * @dev UPDATED: Initial deposit function with bundler integration
     */
    function initialDeposit(address vault, uint256 amount)
        external
        onlyOwner
        onlyAllowedVault(vault)
        nonReentrant
        whenNotPaused
    {
        require(amount >= 0, "Amount cannot be negative");

        uint256 totalAmountToDeposit;
        
        // Handle the automatic initial deposit first if not done yet
        if (!initialDepositMade) {
            require(initialDepositAmount > 0, "No initial deposit amount set");
            require(amount >= initialDepositAmount, "Amount must be greater than or equal to initial deposit amount for first deposit");
            
            totalAmountToDeposit = amount;
            initialDepositMade = true;
        } else {
            totalAmountToDeposit = amount;
        }

        require(totalAmountToDeposit > 0, "No amount to deposit");

        // Transfer total amount from user to this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), totalAmountToDeposit);

        // Get the vault's required asset
        address vaultAsset = IMetaMorpho(vault).asset();
        uint256 depositAmount = totalAmountToDeposit;

        // If vault asset is different from primary asset, swap is needed
        if (vaultAsset != asset) {
            depositAmount = _swapTokens(asset, vaultAsset, totalAmountToDeposit);
        }

        // Handle initial deposit logic
        if (!hasInitialDeposit) {
            // First time deposit - use bundler
            _depositToVaultViaBundler(vault, depositAmount, vaultAsset);
            currentVault = vault;
            totalDeposited = totalAmountToDeposit; // Track in primary asset terms
            hasInitialDeposit = true;
            lastDepositTime = block.timestamp;

            emit InitialDeposit(vault, depositAmount);
        } else {
            // Subsequent deposits
            if (currentVault != vault) {
                // If switching vaults, rebalance existing funds first
                uint256 currentBalance = _getVaultBalance(currentVault);
                if (currentBalance > 0) {
                    uint256 redeemedAmount = _redeemFromVaultViaBundler(
                        currentVault,
                        currentBalance
                    );
                    address currentVaultAsset = IMetaMorpho(currentVault)
                        .asset();

                    // Convert redeemed amount to primary asset if needed
                    if (currentVaultAsset != asset) {
                        redeemedAmount = _swapTokens(
                            currentVaultAsset,
                            asset,
                            redeemedAmount
                        );
                    }

                    // Combine redeemed amount with new deposit amount in primary asset
                    uint256 totalAmountInPrimaryAsset = redeemedAmount + totalAmountToDeposit;
                    
                    // Convert combined amount to new vault asset if needed
                    uint256 totalAmountForNewVault = totalAmountInPrimaryAsset;
                    if (vaultAsset != asset) {
                        totalAmountForNewVault = _swapTokens(
                            asset,
                            vaultAsset,
                            totalAmountInPrimaryAsset
                        );
                    }

                    _depositToVaultViaBundler(vault, totalAmountForNewVault, vaultAsset);
                    currentVault = vault;
                    emit Rebalanced(currentVault, vault, totalAmountForNewVault);
                } else {
                    // No existing funds, just deposit to new vault
                    _depositToVaultViaBundler(vault, depositAmount, vaultAsset);
                    currentVault = vault;
                }
            } else {
                // Same vault, just add to existing position
                _depositToVaultViaBundler(vault, depositAmount, vaultAsset);
            }

            totalDeposited += totalAmountToDeposit; // Always track in primary asset terms
            lastDepositTime = block.timestamp;
            emit InitialDeposit(vault, depositAmount);
        }
    }

    /**
     * @dev Periodic deposit function with bundler integration
     */
    function deposit(address bestVault)
        external
        onlyOwnerOrAdmin
        onlyAllowedVault(bestVault)
        onlyAfterInterval
        nonReentrant
        whenNotPaused
    {
        require(hasInitialDeposit, "Initial deposit not made");
        require(totalDeposited > 0, "No funds to rebalance");

        // If already in the best vault, no rebalancing needed
        if (currentVault == bestVault) {
            lastDepositTime = block.timestamp;
            return;
        }

        // Rebalance from current vault to best vault
        uint256 currentBalance = _getVaultBalance(currentVault);
        if (currentBalance > 0) {
            // Redeem from current vault using bundler
            uint256 redeemedAmount = _redeemFromVaultViaBundler(
                currentVault,
                currentBalance
            );
            address currentVaultAsset = IMetaMorpho(currentVault).asset();
            address bestVaultAsset = IMetaMorpho(bestVault).asset();

            // Swap assets if needed
            if (currentVaultAsset != bestVaultAsset) {
                redeemedAmount = _swapTokens(
                    currentVaultAsset,
                    bestVaultAsset,
                    redeemedAmount
                );
            }

            // Deposit into best vault using bundler
            _depositToVaultViaBundler(bestVault, redeemedAmount, bestVaultAsset);

            emit PeriodicDeposit(currentVault, bestVault, redeemedAmount);
        }

        currentVault = bestVault;
        lastDepositTime = block.timestamp;
    }

    /**
     * @dev UPDATED: Withdraw function with bundler integration
     */
    function withdraw(address vault, uint256 amount)
        external
        onlyOwner
        onlyAllowedVault(vault)
        nonReentrant
        whenNotPaused
    {
        require(hasInitialDeposit, "Initial deposit not made");
        require(vault == currentVault, "Not the current vault");

        uint256 vaultBalance = _getVaultBalance(vault);
        require(vaultBalance > 0, "No funds in vault");

        uint256 withdrawAmount = amount;
        if (amount == 0 || amount > vaultBalance) {
            withdrawAmount = vaultBalance; // Full withdrawal
        }

        // Redeem from vault using bundler
        uint256 redeemedAmount = _redeemFromVaultViaBundler(vault, withdrawAmount);
        address vaultAsset = IMetaMorpho(vault).asset();

        // Convert to primary asset if needed
        if (vaultAsset != asset) {
            redeemedAmount = _swapTokens(vaultAsset, asset, redeemedAmount);
        }

        // Calculate fee and user amount with new logic
        (uint256 feeAmount, uint256 userAmount) = calculateFeeFromProfit(
            redeemedAmount
        );

        // Transfer fee to revenue address if there's a fee
        if (feeAmount > 0) {
            IERC20(asset).safeTransfer(revenueAddress, feeAmount);
            totalFeesCollected += feeAmount;
            emit FeeCollected(vault, feeAmount, userAmount);
        }

        // Transfer remaining amount to owner
        IERC20(asset).safeTransfer(owner, userAmount);

        // Update total deposited
        totalDeposited = totalDeposited > redeemedAmount
            ? totalDeposited - redeemedAmount
            : 0;

        emit Withdrawal(vault, owner, userAmount);
    }

    /**
     * @dev UPDATED: Manual rebalance function with bundler integration
     */
    function rebalanceToVault(address fromVault, address toVault)
        external
        onlyAdmin
        onlyAllowedVault(fromVault)
        onlyAllowedVault(toVault)
        nonReentrant
        whenNotPaused
    {
        require(hasInitialDeposit, "Initial deposit not made");
        require(fromVault == currentVault, "Not the current vault");
        require(fromVault != toVault, "Same vault");

        uint256 balance = _getVaultBalance(fromVault);
        require(balance > 0, "No funds to rebalance");

        // Redeem from current vault using bundler
        uint256 redeemedAmount = _redeemFromVaultViaBundler(fromVault, balance);
        address fromVaultAsset = IMetaMorpho(fromVault).asset();

        // Convert to primary asset (USDC) to calculate profit
        uint256 redeemedInPrimaryAsset = redeemedAmount;
        if (fromVaultAsset != asset) {
            redeemedInPrimaryAsset = _swapTokens(fromVaultAsset, asset, redeemedAmount);
        }

        // Calculate profit and rebalance fee (5% of profit)
        uint256 rebalanceFeeAmount = 0;
        uint256 netAmountForDeposit = redeemedInPrimaryAsset;
        
        if (redeemedInPrimaryAsset > totalDeposited) {
            uint256 profit = redeemedInPrimaryAsset - totalDeposited;
            rebalanceFeeAmount = (profit * REBALANCE_FEE_PERCENTAGE) / 10000; // 5% of profit
            
            // Transfer rebalance fee to revenue address
            if (rebalanceFeeAmount > 0) {
                IERC20(asset).safeTransfer(revenueAddress, rebalanceFeeAmount);
                totalFeesCollected += rebalanceFeeAmount;
                netAmountForDeposit = redeemedInPrimaryAsset - rebalanceFeeAmount;
                
                emit RebalanceFeeCollected(fromVault, toVault, profit, rebalanceFeeAmount);
            }
        }

        // Convert net amount to target vault asset if needed
        address toVaultAsset = IMetaMorpho(toVault).asset();
        uint256 finalDepositAmount = netAmountForDeposit;
        
        if (toVaultAsset != asset) {
            finalDepositAmount = _swapTokens(asset, toVaultAsset, netAmountForDeposit);
        }

        // Deposit into new vault using bundler
        _depositToVaultViaBundler(toVault, finalDepositAmount, toVaultAsset);

        currentVault = toVault;

        emit Rebalanced(fromVault, toVault, finalDepositAmount);
    }

    /**
     * @dev Add a new vault to the whitelist
     */
    function addVault(address vault) external onlyAdmin {
        require(vault != address(0), "Invalid vault address");
        require(!isAllowedVault[vault], "Vault already allowed");

        isAllowedVault[vault] = true;
        allowedVaults.push(vault);

        emit VaultAdded(vault);
    }

    /**
     * @dev Remove a vault from the whitelist
     */
    function removeVault(address vault) external onlyAdmin {
        require(isAllowedVault[vault], "Vault not allowed");
        require(vault != currentVault, "Cannot remove current vault");

        isAllowedVault[vault] = false;

        // Remove from array
        for (uint256 i = 0; i < allowedVaults.length; i++) {
            if (allowedVaults[i] == vault) {
                allowedVaults[i] = allowedVaults[allowedVaults.length - 1];
                allowedVaults.pop();
                break;
            }
        }

        emit VaultRemoved(vault);
    }

    /**
     * @dev Update admin address
     */
    function updateAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin address");
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminUpdated(oldAdmin, newAdmin);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyAdmin {
        _unpause();
    }

    /**
     * @dev Updated emergency withdraw function with bundler integration
     */
    function emergencyWithdraw(address vault)
        external
        onlyOwner
        whenPaused
        nonReentrant
    {
        require(isAllowedVault[vault], "Vault not allowed");

        uint256 balance = _getVaultBalance(vault);
        if (balance > 0) {
            uint256 redeemedAmount = _redeemFromVaultViaBundler(vault, balance);
            address vaultAsset = IMetaMorpho(vault).asset();

            // Convert to primary asset if needed
            if (vaultAsset != asset) {
                redeemedAmount = _swapTokens(vaultAsset, asset, redeemedAmount);
            }

            // Calculate fee and user amount
            (uint256 feeAmount, uint256 userAmount) = calculateFeeFromProfit(
                redeemedAmount
            );

            // Transfer fee to revenue address if there's a fee
            if (feeAmount > 0) {
                IERC20(asset).safeTransfer(revenueAddress, feeAmount);
                totalFeesCollected += feeAmount;
                emit FeeCollected(vault, feeAmount, userAmount);
            }

            // Transfer remaining amount to owner
            IERC20(asset).safeTransfer(owner, userAmount);
            totalDeposited = 0;
            emit Withdrawal(vault, owner, userAmount);
        }
    }

    /**
     * @dev Get potential fee for a withdrawal amount
     */
    function getWithdrawFeePreview(uint256 withdrawAmount)
        external
        view
        returns (uint256 feeAmount, uint256 userAmount)
    {
        if (!hasInitialDeposit || withdrawAmount == 0) {
            return (0, withdrawAmount);
        }

        // Get current vault balance in primary asset terms
        uint256 currentVaultValue = getCurrentVaultAssetsInPrimaryAsset();

        // Calculate what portion of total value this withdrawal represents
        uint256 totalShares = _getVaultBalance(currentVault);
        if (totalShares == 0) {
            return (0, 0);
        }

        // Calculate proportional value in primary asset terms
        uint256 proportionalValue = (currentVaultValue * withdrawAmount) /
            totalShares;

        return calculateFeeFromProfit(proportionalValue);
    }

    /**
     * @dev Get current profit that would be subject to fees
     */
    function getTaxableProfit() external view returns (uint256) {
        if (!hasInitialDeposit || totalDeposited == 0) return 0;

        uint256 currentValue = getCurrentVaultAssetsInPrimaryAsset();

        if (currentValue > totalDeposited) {
            return currentValue - totalDeposited;
        } else {
            return 0; // No profit, no taxable amount
        }
    }

    /**
     * @dev Get potential fee on current profit
     */
    function getPotentialFee() external view returns (uint256) {
        uint256 taxableProfit = this.getTaxableProfit();
        if (taxableProfit == 0) return 0;

        return (taxableProfit * feePercentage) / 10000;
    }

    /**
     * @dev Get fee information
     */
    function getFeeInfo()
        external
        view
        returns (
            address _revenueAddress,
            uint256 _feePercentage,
            uint256 _totalFeesCollected
        )
    {
        return (revenueAddress, feePercentage, totalFeesCollected);
    }

    // Internal functions - REMOVED direct vault interactions, replaced with bundler calls
    function _getVaultBalance(address vault) internal view returns (uint256) {
        return IMetaMorpho(vault).balanceOf(address(this));
    }

    // View functions
    function getCurrentVaultBalance() external view returns (uint256) {
        if (currentVault == address(0)) return 0;
        return _getVaultBalance(currentVault);
    }

    function getCurrentVaultAssets() external view returns (uint256) {
        if (currentVault == address(0)) return 0;
        uint256 shares = _getVaultBalance(currentVault);
        return IMetaMorpho(currentVault).convertToAssets(shares);
    }

    function getAllowedVaultsCount() external view returns (uint256) {
        return allowedVaults.length;
    }

    function getAllowedVaults() external view returns (address[] memory) {
        return allowedVaults;
    }

    function canDeposit() external view returns (bool) {
        return
            block.timestamp >= lastDepositTime + DEPOSIT_INTERVAL ||
            lastDepositTime == 0;
    }

    function timeUntilNextDeposit() external view returns (uint256) {
        if (lastDepositTime == 0) return 0;
        uint256 nextDepositTime = lastDepositTime + DEPOSIT_INTERVAL;
        if (block.timestamp >= nextDepositTime) return 0;
        return nextDepositTime - block.timestamp;
    }

    /**
     * @dev Get the asset address of the specified vault
     */
    function getVaultAsset(address vault) external view returns (address) {
        if (vault == address(0)) return address(0);
        return IMetaMorpho(vault).asset();
    }

    /**
     * @dev Check if a swap is needed for the given vault
     */
    function needsSwap(address vault) external view returns (bool) {
        if (vault == address(0)) return false;
        return IMetaMorpho(vault).asset() != asset;
    }

    /**
     * @dev Get current vault assets value in primary asset terms
     */
    function getCurrentVaultAssetsInPrimaryAsset()
        public
        view
        returns (uint256)
    {
        if (currentVault == address(0) || !hasInitialDeposit) return 0;

        uint256 currentAssets = this.getCurrentVaultAssets();
        if (currentAssets == 0) return 0;

        address vaultAsset = IMetaMorpho(currentVault).asset();

        // If vault asset is same as primary asset, return as is
        if (vaultAsset == asset) {
            return currentAssets;
        }

        // For different assets, get estimated conversion via Aerodrome router
        return _getEstimatedSwapOutput(vaultAsset, asset, currentAssets);
    }

    /**
     * @dev Normalize amount to 18 decimals for consistent calculations
     */
    function _normalizeToDecimals(uint256 amount, address tokenAddress)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;

        // Get token decimals
        uint256 decimals = _getTokenDecimals(tokenAddress);

        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10**(18 - decimals));
        } else {
            return amount / (10**(decimals - 18));
        }
    }

    /**
     * @dev Get token decimals
     */
    function _getTokenDecimals(address tokenAddress)
        internal
        view
        returns (uint256)
    {
        // Common token decimals - you might want to implement a more robust solution
        // For USDC and similar stablecoins
        if (tokenAddress == asset) {
            return 6; // USDC has 6 decimals
        }

        // Try to get decimals from token contract
        try IERC20Extended(tokenAddress).decimals() returns (uint8 decimals) {
            return uint256(decimals);
        } catch {
            return 18; // Default to 18 decimals
        }
    }

    /**
     * @dev Get the current profit in absolute terms (in primary asset)
     */
    function getProfit() external view returns (int256) {
        if (!hasInitialDeposit || totalDeposited == 0) return 0;

        uint256 currentValue = getCurrentVaultAssetsInPrimaryAsset();

        // Both values are in primary asset terms, so we can compare directly
        if (currentValue >= totalDeposited) {
            return int256(currentValue - totalDeposited);
        } else {
            return -int256(totalDeposited - currentValue);
        }
    }

    /**
     * @dev Get the current profit percentage
     */
    function getProfitPercentage() external view returns (int256) {
        if (!hasInitialDeposit || totalDeposited == 0) return 0;

        uint256 currentValue = getCurrentVaultAssetsInPrimaryAsset();

        // Calculate percentage with 4 decimal places
        if (currentValue >= totalDeposited) {
            uint256 profit = currentValue - totalDeposited;
            return int256((profit * 1000000) / totalDeposited);
        } else {
            uint256 loss = totalDeposited - currentValue;
            return -int256((loss * 1000000) / totalDeposited);
        }
    }

    /**
     * @dev Public view function to check which pool type would be used for a swap
     */
    function getOptimalPoolInfo(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        external
        view
        returns (
            bool useStable,
            uint256 stableOutput,
            uint256 volatileOutput
        )
    {
        if (tokenIn == tokenOut || amountIn == 0) {
            return (true, 0, 0);
        }

        address stablePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            true
        );
        address volatilePool = IAerodromeFactory(AERODROME_FACTORY).getPool(
            tokenIn,
            tokenOut,
            false
        );

        stableOutput = _getPoolOutput(tokenIn, tokenOut, amountIn, true);
        volatileOutput = _getPoolOutput(tokenIn, tokenOut, amountIn, false);

        useStable = _shouldUseStablePool(
            tokenIn,
            tokenOut,
            amountIn,
            stablePool,
            volatilePool
        );

        return (useStable, stableOutput, volatileOutput);
    }
}