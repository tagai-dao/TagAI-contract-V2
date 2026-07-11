// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Uniswap V3 SwapRouter02 surface used on RH (ExactInputSingleParams *without* deadline).
/// @dev Selector `exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))` = 0x04e45aaf.
///      Classic SwapRouter (with deadline) uses a different selector and will not match this ABI.
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function refundETH() external payable;
}
