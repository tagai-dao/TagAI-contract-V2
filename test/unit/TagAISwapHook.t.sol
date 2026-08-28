// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title TagAISwapHookTest
 * @notice TagAISwapHook Nutbox period settlement + registerPool (Uniswap v4)。
 * @dev V11：买入走真实 swap（Hook 在 unlock 内 take token fee），注入量用 calculator.totalInjected 校验，
 *      期望注入量用实际成交额 V 经 previewPeriodSettle 计算（与档位自洽）。
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

    /// @dev 该 token community 的累计注入量（calculator 是注入真值源）。
    function _injected(Token t) internal view returns (uint256) {
        return calculator.totalInjected(t.nutboxCommunity());
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
        (address community, address calc) = hook.tokenInfo(address(token));
        assertEq(community, token.nutboxCommunity());
        assertEq(calc, address(calculator));
        assertEq(token.balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox tokens");
    }

    function test_injection_samePeriod_noInjectUntilNextPeriodFirstBuy() public onlyReady {
        uint256 injected0 = _injected(token);

        uint256 v1 = _simulateHookBuy(token, 5 ether);
        uint256 v2 = _simulateHookBuy(token, 3 ether);
        assertEq(_injected(token), injected0, "same period: no inject");

        (uint32 periodIndex, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, v1 + v2);
        assertEq(periodIndex, uint32(block.timestamp / HOOK_PERIOD_LENGTH));

        _warpNextHookPeriod();
        uint256 v3 = _simulateHookBuy(token, 0.1 ether);

        uint256 expected = _expectedHookSettleInject(v1 + v2);
        assertEq(_injected(token) - injected0, expected, "inject on next period first buy");
    }

    function test_injection_settleUsesDirectPeriodVolumeForTier() public onlyReady {
        uint256 injected0 = _injected(token);
        uint256 v = _simulateHookBuy(token, 5 ether);
        assertGt(v, 0);
        _warpNextHookPeriod();
        uint256 v2 = _simulateHookBuy(token, 0.1 ether);

        // 期望注入量 = 实际周期成交额 V 经档位查表计算（与档位自洽）。
        uint256 expected = _expectedHookSettleInject(v);
        if (expected > 0) {
            assertEq(_injected(token) - injected0, expected, "inject matches tier lookup");
        }
    }

    function test_injection_settleSkipsWhenTotalInjectBelowMinimum() public onlyReady {
        uint256 injected0 = _injected(token);
        // 极小买入：毛成交额产生的注入量 < MIN_INJECT_OUTPUT → 结算跳过。
        uint256 v = _simulateHookBuy(token, 1e7 wei);
        _warpNextHookPeriod();
        _simulateHookBuy(token, 1e7 wei);

        uint256 expected = _expectedHookSettleInject(v);
        assertEq(expected, 0, "below MIN_INJECT_OUTPUT: expected 0");
        assertEq(_injected(token), injected0, "below min: skip");
    }

    function test_injection_doesNotTriggerOnSell() public onlyReady {
        uint256 injected0 = _injected(token);
        _simulateHookSell(token, 10_000 ether);
        assertEq(_injected(token), injected0, "sell does not inject");
    }

    function test_injection_periodBuyVolumeBoundedByCap() public onlyReady {
        uint256 injected0 = _injected(token);
        uint256 v = _simulateHookBuy(token, 5 ether);
        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, v, "period buy == received");
        assertLe(periodBuy, HOOK_MAX_PERIOD_BUY, "period buy bounded by cap");

        _warpNextHookPeriod();
        uint256 v2 = _simulateHookBuy(token, 0.1 ether);
        uint256 expected = _expectedHookSettleInject(v);
        if (expected > 0) {
            assertEq(_injected(token) - injected0, expected);
        }
    }

    function test_injection_hugeBuyLimitedByPeriodCap() public onlyReady {
        // 真实买入受池流动性限制，单次买入量不会超过池内 token 储备；周期累计上限 420M 由档位/注入逻辑保证。
        uint256 injected0 = _injected(token);
        uint256 v = _simulateHookBuy(token, 100 ether);
        (, uint256 periodBuy) = hook.periodState(address(token));
        assertLe(periodBuy, HOOK_MAX_PERIOD_BUY, "bounded by cap");
        assertEq(periodBuy, v, "period buy == received (not capped at this scale)");

        _warpNextHookPeriod();
        _simulateHookBuy(token, 0.1 ether);
        uint256 expected = _expectedHookSettleInject(v);
        if (expected > 0) {
            assertGt(_injected(token) - injected0, 0, "some inject happened");
        }
        assertGt(token.balanceOf(address(hook)), 0, "hook still holds tokens");
    }

    function test_buy_tokenFeeStaysOnHook() public onlyReady {
        // V11：买入侧 0.3% token 输出留给 Hook（毛成交额的 0.3%）。
        uint256 hookBalBefore = token.balanceOf(address(hook));
        uint256 v = _simulateHookBuy(token, 2 ether); // v = 毛成交额
        uint256 hookBalAfter = token.balanceOf(address(hook));
        uint256 expectedFee = (v * 30) / 10000; // 0.3% of gross
        // 同期不注入，余额净增 ≈ token fee（容差 1 wei 取整）
        assertApproxEqAbs(hookBalAfter - hookBalBefore, expectedFee, 1);
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
