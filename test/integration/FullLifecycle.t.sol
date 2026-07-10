// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title FullLifecycleTest
 * @notice End-to-end: createToken → fill curve → list → Hook Nutbox settlement (Uniswap v4).
 */
contract FullLifecycleTest is V4PumpTestBase {
    address internal buyer1;
    address internal buyer2;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public override {
        buyer1 = makeAddr("buyer1");
        buyer2 = makeAddr("buyer2");
        vm.deal(buyer1, 1000 ether);
        vm.deal(buyer2, 1000 ether);
        super.setUp();
    }

    function test_fullLifecycle_createAndList() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("TEST", bytes32(uint256(1)));
        Token t = Token(payable(tokenAddr));

        assertTrue(pump.createdTokens(tokenAddr));
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY);
        assertFalse(t.listed());
        assertTrue(t.nutboxCommunity() != address(0));

        _fillBondingCurveUntilListed(t, buyer1);
        assertTrue(t.listed());
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY);
    }

    function test_hookInjection_decreasesOnBuy() public onlyReady {
        Token t = _createAndListToken("HOOK1");
        (, uint96 initialRemaining,) = hook.tokenInfo(address(t));
        assertEq(uint256(initialRemaining), NUTBOX_ALLOCATION);

        _simulateHookBuy(t, 10_000 ether);
        (, uint96 remainingAfterAccum,) = hook.tokenInfo(address(t));
        assertEq(uint256(remainingAfterAccum), uint256(initialRemaining));

        _warpNextHookPeriod();
        _simulateHookBuy(t, 1 ether);

        (, uint96 remainingAfterBuy,) = hook.tokenInfo(address(t));
        (,, uint256 injectAmount) = hook.previewPeriodSettle(10_000 ether);
        if (injectAmount >= HOOK_MIN_INJECT_OUTPUT) {
            assertLt(uint256(remainingAfterBuy), uint256(initialRemaining));
            assertEq(uint256(initialRemaining) - uint256(remainingAfterBuy), injectAmount);
        }
    }

    function test_hookRemaining_unchangedOnSell() public onlyReady {
        Token t = _createAndListToken("HOOK2");
        (, uint96 initialRemaining,) = hook.tokenInfo(address(t));
        _simulateHookSell(t, 10_000 ether);
        (, uint96 remainingAfterSell,) = hook.tokenInfo(address(t));
        assertEq(uint256(remainingAfterSell), uint256(initialRemaining));
    }

    function test_totalSupply_invariant() public onlyReady {
        Token t = _createAndListToken("SUPPLY");
        assertEq(IERC20(address(t)).totalSupply(), TOTAL_SUPPLY);
    }

    function test_multipleBuySwaps_monotonicDecrease() public onlyReady {
        Token t = _createAndListToken("MONO");
        (, uint96 prevRemaining,) = hook.tokenInfo(address(t));

        for (uint256 i = 0; i < 5; i++) {
            _simulateHookBuy(t, 10_000 ether);
            (, uint96 currentRemaining,) = hook.tokenInfo(address(t));
            assertLe(currentRemaining, prevRemaining);
            prevRemaining = currentRemaining;
        }
    }

    function test_buyBelowMinimum_noInject() public onlyReady {
        Token t = _createAndListToken("SMALL");
        (, uint96 initialRemaining,) = hook.tokenInfo(address(t));
        _simulateHookBuy(t, 100 ether);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(t));
        assertEq(uint256(remainingAfter), uint256(initialRemaining));
    }
}
