// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMetaMorpho
 * @dev Interface for MetaMorpho vault interactions
 */
interface IMetaMorpho {
    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    function balanceOf(address account) external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function asset() external view returns (address);
    
    function approve(address spender, uint256 amount) external returns (bool);
    
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    
    function previewRedeem(uint256 shares) external view returns (uint256);
}