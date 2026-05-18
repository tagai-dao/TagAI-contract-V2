// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";

/**
 * @title MockCLPoolManager
 * @notice Simplified CLPoolManager mock for integration testing.
 *         Supports initialize, modifyLiquidity, and swap with hook callbacks.
 */
contract MockCLPoolManager {
    using PoolIdLibrary for PoolKey;

    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        bool initialized;
    }

    mapping(bytes32 => PoolState) public pools;

    // Track calls
    uint256 public initializeCount;
    uint256 public swapCount;

    event PoolInitialized(PoolId indexed id, uint160 sqrtPriceX96);
    event SwapExecuted(PoolId indexed id, bool zeroForOne, int256 amountSpecified);

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();

        // Call beforeInitialize on hook
        address hookAddr = address(key.hooks);
        if (hookAddr != address(0)) {
            ICLHooks(hookAddr).beforeInitialize(msg.sender, key, sqrtPriceX96);
        }

        pools[PoolId.unwrap(id)] = PoolState({
            sqrtPriceX96: sqrtPriceX96,
            tick: 0,
            initialized: true
        });

        initializeCount++;
        emit PoolInitialized(id, sqrtPriceX96);

        // Call afterInitialize on hook
        if (hookAddr != address(0)) {
            ICLHooks(hookAddr).afterInitialize(msg.sender, key, sqrtPriceX96, 0);
        }

        return 0;
    }

    function modifyLiquidity(
        PoolKey memory /* key */,
        ICLPoolManager.ModifyLiquidityParams memory params,
        bytes calldata /* hookData */
    ) external returns (BalanceDelta delta, BalanceDelta feeDelta) {
        // Simplified: return deltas based on liquidity delta
        // For listing: negative means pool needs tokens from caller
        int128 ethNeeded = -int128(int256(19 ether));
        int128 tokenNeeded = -int128(int256(200_000_000 ether));

        if (params.liquidityDelta > 0) {
            delta = toBalanceDelta(ethNeeded, tokenNeeded);
        } else {
            delta = toBalanceDelta(int128(0), int128(0));
        }
        feeDelta = toBalanceDelta(int128(0), int128(0));
    }

    /// @notice Simulate a swap and call hook callbacks
    function swap(
        PoolKey memory key,
        ICLPoolManager.SwapParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        address hookAddr = address(key.hooks);

        // Call beforeSwap
        if (hookAddr != address(0)) {
            ICLHooks(hookAddr).beforeSwap(msg.sender, key, params, hookData);
        }

        // Simulate swap delta
        if (params.zeroForOne) {
            // Buy: ETH in, Token out
            int128 ethIn = params.amountSpecified < 0
                ? int128(params.amountSpecified)
                : int128(int256(1 ether));
            int128 tokenOut = -int128(int256(10_000 ether)); // Simplified: 10k tokens per swap
            delta = toBalanceDelta(ethIn, tokenOut);
        } else {
            // Sell: Token in, ETH out
            int128 tokenIn = params.amountSpecified < 0
                ? int128(params.amountSpecified)
                : int128(int256(10_000 ether));
            int128 ethOut = -int128(int256(1 ether));
            delta = toBalanceDelta(ethOut, tokenIn);
        }

        // Call afterSwap
        if (hookAddr != address(0)) {
            ICLHooks(hookAddr).afterSwap(msg.sender, key, params, delta, hookData);
        }

        swapCount++;
        emit SwapExecuted(key.toId(), params.zeroForOne, params.amountSpecified);
    }

    // Stub functions to satisfy interface expectations
    function getSlot0(PoolId /* id */) external pure returns (uint160, int24, uint24, uint24) {
        return (0, 0, 0, 0);
    }

    function getLiquidity(PoolId /* id */) external pure returns (uint128) {
        return 0;
    }

    receive() external payable {}
}
