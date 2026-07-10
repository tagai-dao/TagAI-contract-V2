// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

/**
 * @title HookProperty
 * @notice Property-based tests for TagAISwapHook (P4, P6, P7) on Uniswap v4.
 */
contract HookPropertyTest is V4ListedTokenTestBase {
    function testFuzz_P4_allocationCap_invariant(uint256 boughtAmount) public onlyReady {
        boughtAmount = bound(boughtAmount, 0, 100_000_000_000 ether);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateHookBuy(token, boughtAmount);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        assertEq(NUTBOX_ALLOCATION - uint256(remainingAfter) + uint256(remainingAfter), NUTBOX_ALLOCATION);
        assertLe(uint256(remainingAfter), uint256(remainingBefore));
    }

    function testFuzz_P4_multipleBuys_neverExceedsCap(uint256 amount1, uint256 amount2, uint256 amount3)
        public
        onlyReady
    {
        amount1 = bound(amount1, _minPeriodVolumeForSettle(), 50_000_000_000 ether);
        amount2 = bound(amount2, 1, 50_000_000_000 ether);
        amount3 = bound(amount3, 1, 50_000_000_000 ether);

        _simulateHookBuy(token, amount1);
        _warpNextHookPeriod();
        _simulateHookBuy(token, amount2);
        _warpNextHookPeriod();
        _simulateHookBuy(token, amount3);

        (, uint96 remaining,) = hook.tokenInfo(address(token));
        assertLe(NUTBOX_ALLOCATION - uint256(remaining), NUTBOX_ALLOCATION);
    }

    function testFuzz_P6_injectionCondition(uint256 boughtAmount, bool isBuy) public onlyReady {
        boughtAmount = bound(boughtAmount, 1, 1_000_000_000 ether);

        _simulateHookBuy(token, boughtAmount);
        (, uint96 remainingAfterAccum,) = hook.tokenInfo(address(token));
        _warpNextHookPeriod();

        (, uint96 remainingBeforeSettle,) = hook.tokenInfo(address(token));
        uint256 capped = boughtAmount > HOOK_MAX_PERIOD_BUY ? HOOK_MAX_PERIOD_BUY : boughtAmount;
        uint256 expectedSettle = _expectedHookSettleInject(capped);

        if (isBuy) {
            _simulateHookBuy(token, 1 ether);
        } else {
            _simulateHookSell(token, 1 ether);
        }

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        if (isBuy && expectedSettle > 0 && remainingBeforeSettle > 0) {
            assertEq(uint256(remainingAfterAccum), uint256(remainingBeforeSettle));
            assertEq(
                uint256(remainingBeforeSettle) - uint256(remainingAfter),
                expectedSettle > uint256(remainingBeforeSettle) ? uint256(remainingBeforeSettle) : expectedSettle
            );
        } else {
            assertEq(uint256(remainingAfter), uint256(remainingBeforeSettle));
        }
    }

    function testFuzz_P6_sellNeverInjects(uint256) public onlyReady {
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateHookSell(token, 1_000_000 ether);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
    }

    function testFuzz_P6_belowMinPeriodSettleDoesNotInject(uint256 periodVolume) public onlyReady {
        uint256 maxVolume = _minPeriodVolumeForSettle();
        if (maxVolume <= 1) return;
        periodVolume = bound(periodVolume, 1, maxVolume - 1);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateHookBuy(token, periodVolume);
        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
    }

    function testFuzz_P7_balanceOnlyDecreasesViaInject(uint256 boughtAmount) public onlyReady {
        boughtAmount = bound(boughtAmount, _minPeriodVolumeForSettle(), 1_000_000_000 ether);

        _simulateHookBuy(token, boughtAmount);
        uint256 hookBalBefore = IERC20(address(token)).balanceOf(address(hook));
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));

        _warpNextHookPeriod();
        _simulateHookBuy(token, 1 ether);

        uint256 hookBalAfter = IERC20(address(token)).balanceOf(address(hook));
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(hookBalBefore - hookBalAfter, uint256(remainingBefore) - uint256(remainingAfter));
    }

    function testFuzz_P7_sellDoesNotAffectHookBalance(uint256) public onlyReady {
        uint256 hookBalBefore = IERC20(address(token)).balanceOf(address(hook));
        _simulateHookSell(token, 1_000_000 ether);
        assertEq(IERC20(address(token)).balanceOf(address(hook)), hookBalBefore);
    }
}
