// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

/**
 * @title GasBenchmark
 * @notice Gas measurements for Hook + Calculator on Uniswap v4 stack.
 */
contract GasBenchmarkTest is V4ListedTokenTestBase {
    function test_gas_calculatorInject_firstInject() public onlyReady {
        address community = token.nutboxCommunity();
        vm.warp(block.timestamp + 3600);

        vm.startPrank(address(hook));
        IERC20(address(token)).approve(address(calculator), type(uint256).max);
        uint256 gasStart = gasleft();
        calculator.inject(community, 1000 ether);
        uint256 gasUsed = gasStart - gasleft();
        vm.stopPrank();

        console.log("[BENCHMARK] Calculator.inject (first) gas:", gasUsed);
        assertLt(gasUsed, 200_000);
    }

    function test_gas_calculatorInject_sameHourMerge() public onlyReady {
        address community = token.nutboxCommunity();
        vm.warp(block.timestamp + 3600);

        vm.startPrank(address(hook));
        IERC20(address(token)).approve(address(calculator), type(uint256).max);
        calculator.inject(community, 1000 ether);

        uint256 gasStart = gasleft();
        calculator.inject(community, 1000 ether);
        uint256 gasUsed = gasStart - gasleft();
        vm.stopPrank();

        console.log("[BENCHMARK] Calculator.inject (merge) gas:", gasUsed);
        assertLt(gasUsed, 100_000);
    }

    function test_gas_calculatorCalculateReward() public onlyReady {
        address community = token.nutboxCommunity();
        vm.warp(block.timestamp + 3600);

        vm.startPrank(address(hook));
        IERC20(address(token)).approve(address(calculator), type(uint256).max);
        calculator.inject(community, 168_000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 * 3600);

        uint256 gasStart = gasleft();
        calculator.calculateReward(community, 3600, calculator.rewardHead());
        uint256 gasUsed = gasStart - gasleft();

        console.log("[BENCHMARK] Calculator.calculateReward gas:", gasUsed);
        assertLt(gasUsed, 100_000);
    }

    function test_gas_hookAfterSwap_buyWithInject() public onlyReady {
        // 真实 swap：accumulate 期 + 结算期，测量结算期 swap gas（含 Hook settle+inject）。
        _simulateHookBuy(token, 0.5 ether);
        vm.warp(block.timestamp + 600);

        uint256 gasStart = gasleft();
        _simulateHookBuy(token, 0.01 ether);
        uint256 gasUsed = gasStart - gasleft();

        console.log("[BENCHMARK] Hook.afterSwap (period settle + inject) gas:", gasUsed);
        assertLt(gasUsed, 600_000);
    }

    function test_gas_hookAfterSwap_buyAccumulateOnly() public onlyReady {
        // 真实 swap：同期 accumulate，无结算。测量 swap gas（含 Hook accumulate + token fee take）。
        uint256 gasStart = gasleft();
        _simulateHookBuy(token, 0.1 ether);
        uint256 gasUsed = gasStart - gasleft();

        console.log("[BENCHMARK] Hook.afterSwap (buy accumulate only) gas:", gasUsed);
        assertLt(gasUsed, 600_000);
    }

    function test_gas_hookAfterSwap_buyBelowMin_skipInject() public onlyReady {
        // 真实 swap：极小买入 accumulate（注入量 < MIN），warp 后结算期 swap 触发 skip。测量结算 swap gas。
        _simulateHookBuy(token, 1e10 wei);
        vm.warp(block.timestamp + 600);

        uint256 gasStart = gasleft();
        _simulateHookBuy(token, 0.01 ether);
        uint256 gasUsed = gasStart - gasleft();

        console.log("[BENCHMARK] Hook.afterSwap (buy below MIN, skip) gas:", gasUsed);
        assertLt(gasUsed, 600_000);
    }

    function test_gas_hookAfterSwap_sell() public onlyReady {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        // exact-output ETH path — early return, no PoolManager.take
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-1 ether, int128(int256(10_000 ether)));

        vm.prank(address(manager));
        uint256 gasStart = gasleft();
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
        uint256 gasUsed = gasStart - gasleft();

        console.log("[BENCHMARK] Hook.afterSwap (sell, no inject) gas:", gasUsed);
        assertLt(gasUsed, 200_000);
    }
}
