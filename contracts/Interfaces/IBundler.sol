// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

struct Call {
    address to;
    bytes data;
    uint256 value;
    bool skipRevert;
    bytes32 callbackHash;
}

interface IBundler3 {
    function multicall(Call[] calldata calls) external payable;
    function initiator() external view returns (address);
}

interface IGeneralAdapter1 {
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver) external;
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner) external;
    function erc20TransferFrom(address token, address receiver, uint256 amount) external;
}