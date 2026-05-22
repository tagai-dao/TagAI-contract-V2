// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";

/**
 * @title BSCForkNutboxInject
 * @notice BSC mainnet fork integration tests for TagAISwapHook dynamic Nutbox injection on DEX buys.
 *
 * Run (requires BSC_RPC_URL):
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkNutboxInject --fork-url "$BSC_RPC_URL" -vvv
 */
contract BSCForkNutboxInject is BSCForkBase {
    /// @dev First listed-hour buy on fork: 0.1% ratio, inject reaches Calculator + Community.
    function test_fork_nutboxInject_firstHour_pointOnePercentOnRealPCS() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ1");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        assertTrue(community != address(0), "nutbox community");
        assertTrue(ICommittee(COMMITTEE).verifyContract(address(calculator)), "calculator whitelisted");

        uint256 totalInjectedBefore = calculator.totalInjected(community);
        uint256 communityBalBefore = IERC20(tokenAddr).balanceOf(community);
        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);

        uint256 ethIn = 50 ether;
        uint256 tokensReceived = _swapBuyExactIn(poolKey, buyer, ethIn);
        assertTrue(tokensReceived > 0, "buy delivered tokens");

        uint32 ratioPpm = hook.getCurrentHourRatioPpm(tokenAddr);
        assertEq(ratioPpm, FIRST_HOUR_RATIO_PPM, "first hour ratio");

        uint256 expectedInject = _capInjectAmount(
            _expectedInjectAmount(tokensReceived, ratioPpm),
            uint256(remainingBefore)
        );
        assertTrue(expectedInject >= MIN_INJECT_OUTPUT, "inject output above minimum");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(
            uint256(remainingBefore) - uint256(remainingAfter),
            expectedInject,
            "hook remaining matches inject"
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

        (uint32 hourIdx, uint32 cachedRatio, uint256 hourBuy,) = _readHourlyState(tokenAddr);
        assertEq(hourIdx, uint32(block.timestamp / 3600), "hour index");
        assertEq(cachedRatio, FIRST_HOUR_RATIO_PPM, "cached hour ratio");
        assertEq(hourBuy, tokensReceived, "hour buy accumulator");
    }

    /// @dev Buy delta with 1000 tokens @ 0.1% → 1 token inject, below 16.8 minimum.
    function test_fork_nutboxInject_skipsWhenOutputBelowMinimum() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ2");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        _simulateHookBuy(poolKey, 1000 ether);

        uint256 injectOut = _expectedInjectAmount(1000 ether, FIRST_HOUR_RATIO_PPM);
        assertEq(injectOut, 0, "inject below minimum");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "no remaining change");
        assertEq(calculator.totalInjected(community), totalInjectedBefore, "no calculator inject");
    }

    /// @dev Second calendar hour uses prior hour buy volume for tier ratio (cached on first buy).
    function test_fork_nutboxInject_secondHour_usesPriorHourVolumeTier() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ3");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 hour1Buy = _swapBuyExactIn(poolKey, buyer, 80 ether);
        assertTrue(hour1Buy > 0, "hour1 buy");

        (,, uint256 accumulated,) = _readHourlyState(tokenAddr);
        assertEq(accumulated, hour1Buy, "hour1 volume recorded");
        assertEq(hook.getCurrentHourRatioPpm(tokenAddr), FIRST_HOUR_RATIO_PPM, "hour1 still first-hour ratio");

        _warpToNextHour();

        // Hour 2 preview must come from hour 1 buy volume, not the first-hour default.
        uint32 expectedTierRatio = hook.getCurrentHourRatioPpm(tokenAddr);
        assertTrue(expectedTierRatio != FIRST_HOUR_RATIO_PPM, "hour2 preview not first-hour default");
        if (hour1Buy < 400_000 ether) {
            assertEq(expectedTierRatio, TIER_LOW_VOLUME_RATIO_PPM, "low-volume tier");
        }

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 totalInjectedBefore = calculator.totalInjected(community);

        uint256 hour2Buy = _swapBuyExactIn(poolKey, buyer2, 30 ether);
        assertTrue(hour2Buy > 0, "hour2 buy");

        uint32 hour2Ratio = hook.getCurrentHourRatioPpm(tokenAddr);
        assertEq(hour2Ratio, expectedTierRatio, "hour2 cached ratio");

        uint256 expectedInject = _capInjectAmount(
            _expectedInjectAmount(hour2Buy, hour2Ratio),
            uint256(remainingBefore)
        );
        if (expectedInject > 0) {
            (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
            assertEq(
                uint256(remainingBefore) - uint256(remainingAfter),
                expectedInject,
                "hour2 inject amount"
            );
            assertEq(
                calculator.totalInjected(community) - totalInjectedBefore,
                expectedInject,
                "hour2 calculator inject"
            );
        }

        (uint32 h2, uint32 cached,, uint256 lastNonZero) = _readHourlyState(tokenAddr);
        assertEq(h2, uint32(block.timestamp / 3600), "hour2 index");
        assertEq(cached, expectedTierRatio, "hour2 cached");
        assertEq(lastNonZero, hour1Buy, "last non-zero hour snapshot");
    }

    /// @dev Calendar hour with zero buys: next hour still uses last non-zero hour volume.
    function test_fork_nutboxInject_emptyHour_keepsLastNonZeroVolume() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ4");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 hour1Buy = _swapBuyExactIn(poolKey, buyer, 60 ether);
        assertTrue(hour1Buy > 0);

        _warpToNextHour();
        uint256 hour2Buy = _swapBuyExactIn(poolKey, buyer, 5 ether);
        assertTrue(hour2Buy > 0);

        // Skip one full hour with no trades.
        _warpToNextHour();
        _warpToNextHour();

        uint32 ratioBeforeHour4Buy = hook.getCurrentHourRatioPpm(tokenAddr);
        assertTrue(ratioBeforeHour4Buy != FIRST_HOUR_RATIO_PPM, "empty hour: not first-hour default");
        if (hour1Buy < 400_000 ether) {
            assertEq(ratioBeforeHour4Buy, TIER_LOW_VOLUME_RATIO_PPM, "still tier from hour1");
        }

        uint256 hour4Buy = _swapBuyExactIn(poolKey, buyer2, 25 ether);
        assertTrue(hour4Buy > 0);

        // Hour 3 had no trades → lastNonZero stays at hour 2 volume (not hour 1).
        (,,, uint256 lastNonZero) = _readHourlyState(tokenAddr);
        assertEq(lastNonZero, hour2Buy, "last non-zero is hour2 across empty hour3");
        assertTrue(lastNonZero != hour1Buy, "hour3 empty did not revert to hour1");

        assertEq(hook.getCurrentHourRatioPpm(tokenAddr), ratioBeforeHour4Buy, "ratio stable across empty hour");
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

    /// @dev Emits HourlyRatioSet when a new hour starts; NutboxInjected on qualifying buys.
    function test_fork_nutboxInject_eventsOnBuy() public onlyBscFork {
        Token token = _createAndListToken("FORKINJ6");
        address tokenAddr = address(token);
        address community = token.nutboxCommunity();
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 50 ether);

        _warpToNextHour();

        vm.recordLogs();
        uint256 tokensReceived = _swapBuyExactIn(poolKey, buyer2, 35 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 ratioTopic = keccak256("HourlyRatioSet(address,uint32,uint256,uint32)");
        bytes32 injectTopic = keccak256("NutboxInjected(address,address,uint256,uint96)");
        bool sawRatio;
        bool sawInject;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == ratioTopic && logs[i].topics[1] == bytes32(uint256(uint160(tokenAddr)))) {
                sawRatio = true;
            }
            if (logs[i].topics[0] == injectTopic && logs[i].topics[1] == bytes32(uint256(uint160(tokenAddr)))) {
                sawInject = true;
            }
        }

        assertTrue(sawRatio, "HourlyRatioSet emitted");
        uint256 injectOut = _expectedInjectAmount(tokensReceived, hook.getCurrentHourRatioPpm(tokenAddr));
        if (injectOut >= MIN_INJECT_OUTPUT) {
            assertTrue(sawInject, "NutboxInjected emitted when inject >= min");
        }
        assertTrue(calculator.totalInjected(community) > 0, "calculator has injections");
    }
}
