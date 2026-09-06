// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Token} from "../../src/pump/Token.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import "./RHForkBase.t.sol";

/**
 * @title RHForkNutboxInject
 * @notice RH fork: TagAISwapHook 10-minute Nutbox period settlement on live PM.
 * @dev V11 余额制注入：注入量用 calculator.totalInjected 校验，cap 用 hook 余额。
 *
 * Run:
 *   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkNutboxInject -vvv
 */
contract RHForkNutboxInject is RHForkBase {
    function test_fork_nutboxInject_samePeriod_accumulatesOnly() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ1");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 totalInjectedBefore = calculator.totalInjected(community);

        uint256 tokensReceived = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(tokensReceived, 0);

        assertEq(calculator.totalInjected(community), totalInjectedBefore, "same period: no inject");

        (uint32 periodIdx, uint256 periodBuy) = _readPeriodState(tokenAddr);
        assertEq(periodIdx, uint32(block.timestamp / PERIOD_LENGTH));
        // periodBuy 为毛成交额（含 0.3% token fee），net ≈ gross * 9970/10000。
        assertApproxEqAbs(periodBuy * 9970 / 10000, tokensReceived, 2, "periodBuy = gross of buy");
    }

    function test_fork_nutboxInject_nextPeriod_settlesPriorPeriod() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ2");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);
        // 注入档位按毛成交额查表（periodBuy 含 0.3% token fee）。
        (, uint256 gross1) = _readPeriodState(tokenAddr);

        uint256 totalInjectedBefore = calculator.totalInjected(community);
        uint256 communityBalBefore = IERC20(tokenAddr).balanceOf(community);

        _warpToNextPeriod();
        uint256 period2Buy = _swapBuyExactIn(poolKey, buyer2, 2 ether);
        assertGt(period2Buy, 0);

        uint256 expectedInject =
            _capInjectAmount(_expectedPeriodSettleInject(gross1), IERC20(tokenAddr).balanceOf(address(hook)));
        assertGe(expectedInject, MIN_INJECT_OUTPUT);

        assertEq(calculator.totalInjected(community) - totalInjectedBefore, expectedInject, "inject amount");
        assertEq(IERC20(tokenAddr).balanceOf(community) - communityBalBefore, expectedInject, "community received");

        (uint32 p2, uint256 p2Buy) = _readPeriodState(tokenAddr);
        assertEq(p2, uint32(block.timestamp / PERIOD_LENGTH));
        assertApproxEqAbs(p2Buy * 9970 / 10000, period2Buy, 2, "p2Buy = gross of period2 buy");
    }

    function test_fork_nutboxInject_skipsWhenPeriodSettleBelowMinimum() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ3");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 totalInjectedBefore = calculator.totalInjected(community);

        // 极小 ETH 买入：毛成交额产生的注入量 < MIN_INJECT_OUTPUT → 结算跳过。
        _swapBuyExactIn(poolKey, buyer, 1e10 wei);
        (, uint256 gross1) = _readPeriodState(tokenAddr);
        _warpToNextPeriod();
        _swapBuyExactIn(poolKey, buyer2, 1e10 wei);

        assertLt(_expectedPeriodSettleInject(gross1), MIN_INJECT_OUTPUT);
        assertEq(calculator.totalInjected(community), totalInjectedBefore, "below min: skip");
    }

    function test_fork_nutboxInject_skippedPeriod_settlesOnNextActivePeriod() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ4");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);
        (, uint256 gross1) = _readPeriodState(tokenAddr);

        _warpToNextPeriod();
        _warpToNextPeriod();

        uint256 period3Buy = _swapBuyExactIn(poolKey, buyer2, 2 ether);
        assertGt(period3Buy, 0);

        uint256 expectedInject =
            _capInjectAmount(_expectedPeriodSettleInject(gross1), IERC20(tokenAddr).balanceOf(address(hook)));
        if (expectedInject > 0) {
            assertGt(calculator.totalInjected(token.nutboxCommunity()), 0, "skipped period settles later");
        }
    }

    function test_fork_nutboxInject_sellDoesNotInject() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ5");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 3 ether);
        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertGt(tokenBal, 0);

        uint256 totalInjectedBefore = calculator.totalInjected(community);

        _swapSellExactIn(poolKey, buyer, tokenBal / 3);

        assertEq(calculator.totalInjected(community), totalInjectedBefore, "sell never injects");
    }

    function test_fork_nutboxInject_eventsOnPeriodSettle() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ6");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);
        (, uint256 gross1) = _readPeriodState(tokenAddr);

        _warpToNextPeriod();

        vm.recordLogs();
        _swapBuyExactIn(poolKey, buyer2, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // V11: NutboxInjected(address,address,uint256,uint256) — last param 为注入后余额。
        bytes32 settledTopic = keccak256("PeriodSettled(address,uint32,uint256,uint256,uint32,uint256)");
        bytes32 injectTopic = keccak256("NutboxInjected(address,address,uint256,uint256)");
        bool sawSettled;
        bool sawInject;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == settledTopic && logs[i].topics[1] == bytes32(uint256(uint160(tokenAddr)))) {
                sawSettled = true;
            }
            if (logs[i].topics[0] == injectTopic && logs[i].topics[1] == bytes32(uint256(uint160(tokenAddr)))) {
                sawInject = true;
            }
        }

        assertTrue(sawSettled);
        uint256 injectOut = _expectedPeriodSettleInject(gross1);
        if (injectOut >= MIN_INJECT_OUTPUT) {
            assertTrue(sawInject);
        }
        assertGt(calculator.totalInjected(community), 0);
    }
}
