# UserVault V3 

## Overview

UserVault V3 is an advanced yield optimization contract that manages individual user vaults with automated asset swapping, vault rebalancing, and fee collection mechanisms. The contract integrates with MetaMorpho vaults via the Morpho bundler system and utilizes Aerodrome DEX for optimal asset swapping.

## Architecture

### Core Components

1. **Vault Management System** - Handles deposits, withdrawals, and rebalancing across whitelisted MetaMorpho vaults
2. **Asset Swapping Engine** - Integrates with Aerodrome DEX for optimal token swapping with pool selection
3. **Bundler Integration** - Uses Morpho's bundler system for gas-efficient vault interactions
4. **Fee Management System** - Implements profit-based fee collection with configurable parameters
5. **Access Control** - Multi-tier permission system with owner and admin roles

## Key Features

### 🔄 Automated Vault Management
- **Initial Deposits**: Predefined initial deposit amounts with automatic execution
- **Periodic Rebalancing**: Time-gated rebalancing to optimal performing vaults
- **Cross-Asset Support**: Automatic asset conversion when switching between vaults with different underlying assets

### 💱 Intelligent Asset Swapping
- **Optimal Pool Selection**: Automatically chooses between stable and volatile pools on Aerodrome
- **Slippage Protection**: Built-in slippage tolerance (5% default)
- **Pool Comparison**: Real-time comparison of stable vs volatile pool outputs

### 🏦 Bundler Integration
- **Gas Optimization**: Uses Morpho's bundler for efficient multicall operations
- **Atomic Operations**: Ensures deposit/withdrawal operations are executed atomically
- **Adapter Integration**: Leverages GeneralAdapter1 for standardized vault interactions

### 💰 Advanced Fee System
- **Profit-Only Fees**: Fees are only charged on profits, never on principal
- **Minimum Profit Threshold**: $10 minimum profit requirement before fees apply
- **Rebalance Fees**: 5% fee on profits during manual rebalancing
- **Configurable Rates**: Admin-adjustable fee percentages (max 10%)

## Contract Architecture

```
UserVault_V3
├── Vault Management
│   ├── initialDeposit()
│   ├── deposit() [periodic]
│   ├── withdraw()
│   └── rebalanceToVault()
├── Asset Swapping
│   ├── _swapTokens()
│   ├── _shouldUseStablePool()
│   └── getOptimalPoolInfo()
├── Bundler Integration
│   ├── _depositToVaultViaBundler()
│   └── _redeemFromVaultViaBundler()
├── Fee Management
│   ├── calculateFeeFromProfit()
│   ├── getTaxableProfit()
│   └── getPotentialFee()
└── Access Control
    ├── onlyOwner
    ├── onlyAdmin
    └── onlyOwnerOrAdmin
```

## Technical Specifications

### Dependencies
- **OpenZeppelin Contracts**: ReentrancyGuard, Pausable, SafeERC20
- **MetaMorpho Protocol**: ERC-4626 vault standard
- **Morpho Bundler**: Multicall execution system
- **Aerodrome DEX**: Automated market maker

### Constants
```solidity
address public constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
address public constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address public constant ADAPTER_ADDRESS = 0xb98c948CFA24072e58935BC004a8A7b376AE746A;
address public constant BUNDLER_ADDRESS = 0x6BFd8137e702540E7A42B74178A4a49Ba43920C4;
uint256 public constant DEPOSIT_INTERVAL = 24 hours;
uint256 public constant SLIPPAGE_TOLERANCE = 500; // 5%
uint256 public constant REBALANCE_FEE_PERCENTAGE = 500; // 5%
uint256 public constant MIN_PROFIT_FOR_FEE = 10e6; // $10 USDC
```

## Interface Structure

### File Organization
```
contracts/
├── UserVault_V3.sol
└── Interfaces/
    ├── IAerodrome.sol      # Aerodrome DEX interfaces
    ├── IMetaMorpho.sol     # MetaMorpho vault interfaces  
    ├── IBundler.sol        # Morpho bundler interfaces
    └── IERC20Extended.sol  # Extended ERC20 interface
```

### Interface Specifications

#### IAerodrome.sol
```solidity
struct Route {
    address from;
    address to; 
    bool stable;
    address factory;
}

interface IAerodromeRouter {
    function swapExactTokensForTokens(...) external returns (uint256[] memory);
    function getAmountsOut(...) external view returns (uint256[] memory);
}

interface IAerodromeFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}
```

#### IBundler.sol
```solidity
struct Call {
    address to;
    bytes data;
    uint256 value;
    bool skipRevert;
    bytes32 callbackHash;
}

interface IBundler3 {
    function multicall(Call[] calldata calls) external payable;
}

interface IGeneralAdapter1 {
    function erc4626Deposit(...) external;
    function erc4626Redeem(...) external;
    function erc20TransferFrom(...) external;
}
```

## Core Functions

### Deposit Functions

#### `initialDeposit(address vault, uint256 amount)`
- **Purpose**: Execute initial deposit with predefined minimum amount
- **Access**: Owner only
- **Features**: 
  - Automatic asset swapping if vault asset differs from primary asset
  - Sets up initial vault position and tracking
  - Handles vault switching with existing balance rebalancing

#### `deposit(address bestVault)`
- **Purpose**: Periodic rebalancing to optimal vault
- **Access**: Owner or Admin
- **Restrictions**: 24-hour interval between deposits
- **Features**:
  - Automatic rebalancing between vaults
  - Cross-asset swapping support
  - Gas-optimized via bundler

### Withdrawal Functions

#### `withdraw(address vault, uint256 amount)`
- **Purpose**: Withdraw funds with automatic fee calculation
- **Access**: Owner only  
- **Features**:
  - Profit-based fee calculation
  - Automatic asset conversion to primary asset
  - Partial or full withdrawal support

#### `emergencyWithdraw(address vault)`
- **Purpose**: Emergency fund recovery when contract is paused
- **Access**: Owner only
- **Requirements**: Contract must be paused

### Administrative Functions

#### Vault Management
```solidity
function addVault(address vault) external onlyAdmin
function removeVault(address vault) external onlyAdmin
```

#### Fee Configuration
```solidity
function updateFeePercentage(uint256 newFeePercentage) external onlyAdmin
function updateRevenueAddress(address newRevenueAddress) external onlyAdmin
```

#### Access Control
```solidity
function updateAdmin(address newAdmin) external onlyAdmin
function pause() external onlyAdmin
function unpause() external onlyAdmin
```

## Fee Structure

### Fee Types

1. **Withdrawal Fees**: Applied only on profits exceeding $10
   - Rate: Configurable (max 10%)
   - Calculation: `(profit * feePercentage) / 10000`

2. **Rebalance Fees**: Applied on profits during manual rebalancing
   - Rate: 5% fixed
   - Minimum: $10 profit threshold

### Fee Calculation Logic
```solidity
function calculateFeeFromProfit(uint256 totalAmount) 
    returns (uint256 feeAmount, uint256 userAmount) {
    
    if (totalAmount <= totalDeposited) return (0, totalAmount); // No profit
    
    uint256 profit = totalAmount - totalDeposited;
    if (profit <= MIN_PROFIT_FOR_FEE) return (0, totalAmount); // Under $10
    
    feeAmount = (profit * feePercentage) / 10000;
    userAmount = totalAmount - feeAmount;
}
```

## Asset Swapping Algorithm

### Pool Selection Logic
1. **Pool Discovery**: Check both stable and volatile pools for token pair
2. **Output Comparison**: Calculate expected outputs from both pools
3. **Optimization**: Select pool with higher output (with 0.1% bias toward stable)
4. **Execution**: Execute swap with slippage protection

### Swap Process
```solidity
function _swapTokens(address tokenIn, address tokenOut, uint256 amountIn) 
    returns (uint256 amountOut) {
    
    // 1. Pool discovery and selection
    bool useStablePool = _shouldUseStablePool(...);
    
    // 2. Route preparation  
    Route[] memory routes = [Route({...})];
    
    // 3. Slippage calculation
    uint256 minAmountOut = (expectedOutput * 9500) / 10000; // 5% slippage
    
    // 4. Swap execution
    amounts = router.swapExactTokensForTokens(...);
}
```

## Bundler Integration

### Deposit Flow
```solidity
Call[] memory calls = new Call[](2);

// Transfer tokens to adapter
calls[0] = Call({
    to: ADAPTER_ADDRESS,
    data: abi.encodeWithSelector(0xd96ca0b9, asset, ADAPTER_ADDRESS, amount),
    ...
});

// Execute vault deposit
calls[1] = Call({
    to: ADAPTER_ADDRESS, 
    data: abi.encodeWithSelector(0x6ef5eeae, vault, amount, maxPrice, receiver),
    ...
});

bundler.multicall(calls);
```

### Withdrawal Flow
```solidity
Call[] memory calls = new Call[](2);

// Transfer shares to adapter
calls[0] = Call({...}); // Share transfer

// Execute vault redemption  
calls[1] = Call({...}); // Share redemption

bundler.multicall(calls);
```

## Security Features

### Access Control Matrix
| Function | Owner | Admin | Public |
|----------|-------|-------|--------|
| initialDeposit | ✅ | ❌ | ❌ |
| deposit | ✅ | ✅ | ❌ |
| withdraw | ✅ | ❌ | ❌ |
| rebalanceToVault | ❌ | ✅ | ❌ |
| addVault | ❌ | ✅ | ❌ |
| updateFees | ❌ | ✅ | ❌ |
| pause/unpause | ❌ | ✅ | ❌ |
| View functions | ✅ | ✅ | ✅ |

### Protection Mechanisms
- **ReentrancyGuard**: Prevents reentrancy attacks
- **Pausable**: Emergency stop functionality  
- **SafeERC20**: Safe token transfer operations
- **Slippage Protection**: Maximum 5% slippage on swaps
- **Vault Whitelist**: Only approved vaults can be used
- **Time Locks**: 24-hour interval between periodic deposits

## Deployment Configuration

### Constructor Parameters
```solidity
constructor(
    address _owner,              // Vault owner address
    address _admin,              // Administrative address  
    address _asset,              // Primary asset (USDC)
    address[] _initialVaults,    // Initial vault whitelist
    address _revenueAddress,     // Fee collection address
    uint256 _feePercentage,      // Fee rate in basis points
    uint256 _initialDepositAmount // Required initial deposit
)
```

### Deployment Checklist
- [ ] Verify all contract addresses (Router, Factory, Bundler, Adapter)
- [ ] Set appropriate fee percentages (≤ 1000 basis points)
- [ ] Configure initial vault whitelist
- [ ] Set revenue collection address
- [ ] Define minimum initial deposit amount
- [ ] Test with small amounts before production use

## View Functions

### Portfolio Monitoring
```solidity
function getCurrentVaultBalance() external view returns (uint256)
function getCurrentVaultAssets() external view returns (uint256) 
function getCurrentVaultAssetsInPrimaryAsset() public view returns (uint256)
function getProfit() external view returns (int256)
function getProfitPercentage() external view returns (int256)
```

### Fee Calculations
```solidity
function getTaxableProfit() external view returns (uint256)
function getPotentialFee() external view returns (uint256)
function getWithdrawFeePreview(uint256 amount) external view returns (uint256, uint256)
```

### System Status
```solidity
function canDeposit() external view returns (bool)
function timeUntilNextDeposit() external view returns (uint256)
function getAllowedVaults() external view returns (address[] memory)
```

## Events

### Core Operations
```solidity
event InitialDeposit(address indexed vault, uint256 amount)
event PeriodicDeposit(address indexed fromVault, address indexed toVault, uint256 amount)
event Withdrawal(address indexed vault, address indexed recipient, uint256 amount)
event Rebalanced(address indexed fromVault, address indexed toVault, uint256 amount)
```

### Asset Management
```solidity
event AssetSwapped(address indexed fromAsset, address indexed toAsset, uint256 amountIn, uint256 amountOut)
```

### Fee Collection
```solidity
event FeeCollected(address indexed vault, uint256 feeAmount, uint256 userAmount)
event RebalanceFeeCollected(address indexed fromVault, address indexed toVault, uint256 profit, uint256 feeAmount)
```

### Administrative
```solidity
event VaultAdded(address indexed vault)
event VaultRemoved(address indexed vault)
event AdminUpdated(address indexed oldAdmin, address indexed newAdmin)
event RevenueAddressUpdated(address indexed oldAddress, address indexed newAddress)
event FeePercentageUpdated(uint256 oldFee, uint256 newFee)
```

## Error Handling

### Common Errors
- `"Invalid owner"` - Zero address provided for owner
- `"Invalid admin"` - Zero address provided for admin  
- `"Invalid asset"` - Zero address provided for primary asset
- `"Vault not allowed"` - Attempting to use non-whitelisted vault
- `"Deposit interval not met"` - Attempting periodic deposit too soon
- `"No funds to rebalance"` - No vault balance available for rebalancing
- `"Fee too high"` - Fee percentage exceeds maximum (10%)
- `"Initial deposit not made"` - Attempting operations before initial deposit

### Recovery Mechanisms
- Emergency withdraw function for fund recovery
- Pause/unpause functionality for emergency stops
- Admin role for operational adjustments
- Owner role for fund management

## Gas Optimization

### Bundler Benefits
- **Reduced Gas Costs**: Batched operations reduce transaction overhead
- **Atomic Operations**: Multiple operations in single transaction
- **Optimized Routing**: Bundler handles optimal execution paths

### Design Optimizations
- Minimal external calls in loops
- Efficient storage variable packing
- Lazy evaluation in view functions
- Optimized pool selection algorithm

## Integration Guide

### For Frontend Applications
1. **Monitor Events**: Subscribe to relevant events for real-time updates
2. **View Functions**: Use view functions for portfolio dashboard
3. **Transaction Building**: Build transactions with proper gas limits
4. **Error Handling**: Implement proper error handling for failed transactions

### For Other Contracts
1. **Interface Usage**: Import and use provided interfaces
2. **Access Control**: Respect access control mechanisms  
3. **State Changes**: Monitor contract state via events
4. **Integration Testing**: Thorough testing in development environment

## Testing Strategy

### Unit Tests
- Individual function testing with mock contracts
- Edge case validation (zero amounts, invalid addresses)
- Access control verification
- Fee calculation accuracy

### Integration Tests  
- End-to-end deposit/withdrawal flows
- Multi-vault rebalancing scenarios
- Asset swapping with various token pairs
- Bundler integration testing

### Security Tests
- Reentrancy attack simulation
- Access control bypass attempts
- Integer overflow/underflow testing
- Slippage attack scenarios

## Monitoring & Maintenance

### Key Metrics to Monitor
- Total value locked (TVL)
- Profit/loss tracking
- Fee collection rates
- Gas usage optimization
- Vault performance comparison

### Maintenance Tasks
- Regular vault whitelist updates
- Fee parameter adjustments
- Revenue address updates
- Emergency response procedures

## Troubleshooting

### Common Issues
1. **Transaction Failures**: Check gas limits and slippage tolerance
2. **Access Denied**: Verify caller has appropriate permissions
3. **Insufficient Balance**: Ensure adequate token balances
4. **Pool Not Found**: Verify token pairs have liquidity on Aerodrome

### Debug Functions
- Use view functions to check current state
- Monitor events for transaction history
- Verify vault and token approvals
- Check time restrictions for periodic operations

---

## License
MIT License - See LICENSE file for details

## Support
For technical support and questions, please refer to the project repository or contact the development team.