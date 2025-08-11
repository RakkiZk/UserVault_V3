// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Aerodrome swap interfaces
struct Route {
    address from;
    address to;
    bool stable;
    address factory;
}

interface IAerodromeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);
}

interface IAerodromeFactory {
    function getPool(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address);
}