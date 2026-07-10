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

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        uint256 tokensReceived = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(tokensReceived, 0);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
        assertEq(calculator.totalInjected(community), totalInjectedBefore);

        (uint32 periodIdx, uint256 periodBuy) = _readPeriodState(tokenAddr);
        assertEq(periodIdx, uint32(block.timestamp / PERIOD_LENGTH));
        assertEq(periodBuy, tokensReceived);
    }

    function test_fork_nutboxInject_nextPeriod_settlesPriorPeriod() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ2");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);
        uint256 communityBalBefore = IERC20(tokenAddr).balanceOf(community);

        _warpToNextPeriod();
        uint256 period2Buy = _swapBuyExactIn(poolKey, buyer2, 2 ether);
        assertGt(period2Buy, 0);

        uint256 expectedInject =
            _capInjectAmount(_expectedPeriodSettleInject(period1Buy), uint256(remainingBefore));
        assertGe(expectedInject, MIN_INJECT_OUTPUT);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
        assertEq(calculator.totalInjected(community) - totalInjectedBefore, expectedInject);
        assertEq(IERC20(tokenAddr).balanceOf(community) - communityBalBefore, expectedInject);

        (uint32 p2, uint256 p2Buy) = _readPeriodState(tokenAddr);
        assertEq(p2, uint32(block.timestamp / PERIOD_LENGTH));
        assertEq(p2Buy, period2Buy);
    }

    function test_fork_nutboxInject_skipsWhenPeriodSettleBelowMinimum() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ3");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        _simulateHookBuy(token, 50 ether);
        _warpToNextPeriod();
        _simulateHookBuy(token, 1 ether);

        assertLt(_expectedPeriodSettleInject(50 ether), MIN_INJECT_OUTPUT);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
        assertEq(calculator.totalInjected(community), totalInjectedBefore);
    }

    function test_fork_nutboxInject_skippedPeriod_settlesOnNextActivePeriod() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ4");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);

        _warpToNextPeriod();
        _warpToNextPeriod();

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 period3Buy = _swapBuyExactIn(poolKey, buyer2, 2 ether);
        assertGt(period3Buy, 0);

        uint256 expectedInject =
            _capInjectAmount(_expectedPeriodSettleInject(period1Buy), uint256(remainingBefore));
        if (expectedInject > 0) {
            (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
            assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
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

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        _swapSellExactIn(poolKey, buyer, tokenBal / 3);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
        assertEq(calculator.totalInjected(community), totalInjectedBefore);
    }

    function test_fork_nutboxInject_eventsOnPeriodSettle() public onlyRhFork {
        Token token = _createAndListToken("FORKINJ6");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertGt(period1Buy, 0);

        _warpToNextPeriod();

        vm.recordLogs();
        _swapBuyExactIn(poolKey, buyer2, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 settledTopic = keccak256("PeriodSettled(address,uint32,uint256,uint256,uint32,uint256)");
        bytes32 injectTopic = keccak256("NutboxInjected(address,address,uint256,uint96)");
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
        uint256 injectOut = _expectedPeriodSettleInject(period1Buy);
        if (injectOut >= MIN_INJECT_OUTPUT) {
            assertTrue(sawInject);
        }
        assertGt(calculator.totalInjected(community), 0);
    }
}
