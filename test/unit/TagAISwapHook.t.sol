// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title TagAISwapHookTest
 * @notice TagAISwapHook Nutbox period settlement + registerPool (Uniswap v4).
 */
contract TagAISwapHookTest is V4PumpTestBase {
    using PoolIdLibrary for PoolKey;

    Token public token;

    uint256 constant MIN_INJECT_OUTPUT = 168 ether / 10;

    function setUp() public override {
        super.setUp();
        if (!envReady) return;
        token = _createAndListToken("HOOK");
    }

    function test_registerPool_revertsIfNotTokenCaller() public onlyReady {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.registerPool(PoolId.wrap(bytes32(uint256(99))), address(token));
    }

    function test_registerPool_revertsIfTokenNotCreatedByPump() public onlyReady {
        vm.prank(makeAddr("fakeToken"));
        vm.expectRevert();
        hook.registerPool(PoolId.wrap(bytes32(uint256(99))), makeAddr("fakeToken"));
    }

    function test_registerPool_succeededDuringListing() public onlyReady {
        (address community, uint96 remaining, address calc) = hook.tokenInfo(address(token));
        assertEq(community, token.nutboxCommunity());
        assertEq(uint256(remaining), NUTBOX_ALLOCATION);
        assertEq(calc, address(calculator));
    }

    function test_injection_samePeriod_noInjectUntilNextPeriodFirstBuy() public onlyReady {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

        _simulateHookBuy(token, 20_000 ether);
        _simulateHookBuy(token, 30_000 ether);

        (, uint96 remainingSamePeriod,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingSamePeriod), uint256(initialRemaining));

        (uint32 periodIndex, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 50_000 ether);
        assertEq(periodIndex, uint32(block.timestamp / HOOK_PERIOD_LENGTH));

        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);

        (, uint96 remainingAfterSettle,) = hook.tokenInfo(address(token));
        uint256 expected = _expectedHookSettleInject(50_000 ether);
        assertEq(uint256(initialRemaining) - uint256(remainingAfterSettle), expected);
    }

    function test_injection_settleUsesDirectPeriodVolumeForTier() public onlyReady {
        _simulateHookBuy(token, 50_000 ether);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _warpNextHookPeriod();
        _simulateHookBuy(token, 10_000 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = 50_000 ether * HOOK_TIER1_RATIO_PPM / HOOK_RATIO_SCALE;
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expected);
    }

    function test_injection_settleSkipsWhenTotalInjectBelowMinimum() public onlyReady {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

        _simulateHookBuy(token, 50 ether);
        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(initialRemaining));
    }

    function test_injection_doesNotTriggerOnSell() public onlyReady {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));
        _simulateHookSell(token, 10_000 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(initialRemaining));
    }

    function test_injection_periodBuyVolumeCapAt420M() public onlyReady {
        (, uint96 remainingStart,) = hook.tokenInfo(address(token));

        _simulateHookBuy(token, 419_000_000 ether);
        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 419_000_000 ether);

        _simulateHookBuy(token, 2_000_000 ether);
        (, periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, HOOK_MAX_PERIOD_BUY);

        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = _expectedHookSettleInject(HOOK_MAX_PERIOD_BUY);
        assertEq(uint256(remainingStart) - uint256(remainingAfter), expected);
    }

    function test_injection_hugeBuyLimitedByPeriodCap() public onlyReady {
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));

        _simulateHookBuy(token, 200_000_000_000 ether);

        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, HOOK_MAX_PERIOD_BUY);

        (, uint96 remainingSamePeriod,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingSamePeriod), uint256(remainingBefore));

        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expectedInject = _expectedHookSettleInject(HOOK_MAX_PERIOD_BUY);
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
        assertGt(uint256(remainingAfter), 0);
    }

    function test_previewPeriodSettle_matchesSettlement() public onlyReady {
        (uint256 lookup, uint32 ratio, uint256 injectAmount) = hook.previewPeriodSettle(50_000 ether);
        assertEq(lookup, 50_000 ether);
        assertEq(ratio, uint32(HOOK_TIER1_RATIO_PPM));
        assertEq(injectAmount, 50_000 ether * HOOK_TIER1_RATIO_PPM / HOOK_RATIO_SCALE);
    }

    function test_hookAddress_hasCorrectV4Flags() public onlyReady {
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), HOOK_FLAGS);
    }
}
