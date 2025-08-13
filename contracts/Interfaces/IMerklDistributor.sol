// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Merkl Distributor interface
interface IMerklDistributor {

    function toggleOperator(address user, address operator) external;
    
    function operators(address user, address operator) external view returns (bool);
}