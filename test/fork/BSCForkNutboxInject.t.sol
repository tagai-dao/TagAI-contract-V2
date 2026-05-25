// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";

/**
 * @title BSCForkNutboxInject
 * @notice BSC mainnet fork integration tests for TagAISwapHook 10-minute period Nutbox injection.
 *
 * Run (requires BSC_RPC_URL):
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkNutboxInject --fork-url "$BSC_RPC_URL" -vvv
 */
contract BSCForkNutboxInject is BSCForkBase {
    /// @dev Same 10-minute period: accumulate only, no inject until next period.
    function test_fork_nutboxInject_samePeriod_accumulatesOnly() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ1");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        uint256 tokensReceived = _swapBuyExactIn(poolKey, buyer, 50 ether);
        assertTrue(tokensReceived > 0, "buy delivered tokens");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "same period: no inject");
        assertEq(calculator.totalInjected(community), totalInjectedBefore, "same period: calculator unchanged");

        (uint32 periodIdx, uint256 periodBuy) = _readPeriodState(tokenAddr);
        assertEq(periodIdx, uint32(block.timestamp / PERIOD_LENGTH), "period index");
        assertEq(periodBuy, tokensReceived, "period buy accumulator");
    }

    /// @dev Next period first buy settles prior period using direct 10-minute volume tier lookup.
    function test_fork_nutboxInject_nextPeriod_settlesPriorPeriod() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ2");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 50 ether);
        assertTrue(period1Buy > 0, "period1 buy");

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);
        uint256 communityBalBefore = IERC20(tokenAddr).balanceOf(community);

        _warpToNextPeriod();

        uint256 period2Buy = _swapBuyExactIn(poolKey, buyer2, 30 ether);
        assertTrue(period2Buy > 0, "period2 buy triggers settlement");

        uint256 expectedInject = _capInjectAmount(
            _expectedPeriodSettleInject(period1Buy),
            uint256(remainingBefore)
        );
        assertTrue(expectedInject >= MIN_INJECT_OUTPUT, "inject output above minimum");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(
            uint256(remainingBefore) - uint256(remainingAfter),
            expectedInject,
            "hook remaining matches period settlement"
        );
        assertEq(
            calculator.totalInjected(community) - totalInjectedBefore,
            expectedInject,
            "calculator totalInjected"
        );
        assertEq(
            IERC20(tokenAddr).balanceOf(community) - communityBalBefore,
            expectedInject,
            "community received tokens"
        );

        (uint32 p2, uint256 p2Buy) = _readPeriodState(tokenAddr);
        assertEq(p2, uint32(block.timestamp / PERIOD_LENGTH), "now in period2");
        assertEq(p2Buy, period2Buy, "period2 accumulator");
    }

    /// @dev Period settlement below 16.8 tokens is skipped entirely.
    function test_fork_nutboxInject_skipsWhenPeriodSettleBelowMinimum() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ3");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        _simulateHookBuy(poolKey, 800 ether);

        _warpToNextPeriod();
        _simulateHookBuy(poolKey, 1000 ether);

        assertEq(_expectedPeriodSettleInject(800 ether), 0, "settle below minimum");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "no remaining change");
        assertEq(calculator.totalInjected(community), totalInjectedBefore, "no calculator inject");
    }

    /// @dev Skipped period with no trades: prior period settles on next active period's first buy.
    function test_fork_nutboxInject_skippedPeriod_settlesOnNextActivePeriod() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ4");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 60 ether);
        assertTrue(period1Buy > 0);

        _warpToNextPeriod();
        // Skip period 2 entirely (no trades).
        _warpToNextPeriod();

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 period3Buy = _swapBuyExactIn(poolKey, buyer2, 25 ether);
        assertTrue(period3Buy > 0);

        uint256 expectedInject = _capInjectAmount(
            _expectedPeriodSettleInject(period1Buy),
            uint256(remainingBefore)
        );
        if (expectedInject > 0) {
            (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
            assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject, "period1 settled on period3");
        }
    }

    /// @dev Sell path must not inject or change hook remaining / calculator totals.
    function test_fork_nutboxInject_sellDoesNotInject() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ5");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 40 ether);

        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertTrue(tokenBal > 0);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        uint256 sellAmount = tokenBal / 3;
        _swapSellExactIn(poolKey, buyer, sellAmount);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "sell: remaining unchanged");
        assertEq(calculator.totalInjected(community), totalInjectedBefore, "sell: no new inject");
    }

    /// @dev Emits PeriodSettled + NutboxInjected when next period settles a qualifying prior period.
    function test_fork_nutboxInject_eventsOnPeriodSettle() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ6");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 period1Buy = _swapBuyExactIn(poolKey, buyer, 50 ether);
        assertTrue(period1Buy > 0);

        _warpToNextPeriod();

        vm.recordLogs();
        _swapBuyExactIn(poolKey, buyer2, 35 ether);
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

        assertTrue(sawSettled, "PeriodSettled emitted");
        uint256 injectOut = _expectedPeriodSettleInject(period1Buy);
        if (injectOut >= MIN_INJECT_OUTPUT) {
            assertTrue(sawInject, "NutboxInjected emitted when settle >= min");
        }
        assertTrue(calculator.totalInjected(community) > 0, "calculator has injections");
    }
}
