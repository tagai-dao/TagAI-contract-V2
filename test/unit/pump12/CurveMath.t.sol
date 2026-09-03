// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CurveMath} from "../../../src/pump12/libraries/CurveMath.sol";

contract CurveMathHarness {
    function costWad(uint256 soldSupply, uint256 amount) external pure returns (uint256) {
        return CurveMath.costWad(soldSupply, amount);
    }
}

contract CurveMathTest is Test {
    uint256 internal constant SALE_CAP = 750_000_000e18;
    CurveMathHarness internal harness;

    function setUp() public {
        harness = new CurveMathHarness();
    }

    function test_fullCurveRaisesExactlyFifteenThousandUsdG() public pure {
        assertEq(CurveMath.costRawUSDG(0, SALE_CAP), 15_000e6);
    }

    function test_zeroAmountCostsZero() public pure {
        assertEq(CurveMath.costWad(0, 0), 0);
        assertEq(CurveMath.costRawUSDG(0, 0), 0);
    }

    function test_curveShapeMatchesScaledPump9() public pure {
        assertEq(CurveMath.B_RAW, 290_486_728_130_769_230_769_230_769);
        assertApproxEqRel(CurveMath.endPriceWad(), CurveMath.startPriceWad() * 13_221_886_835 / 1e9, 1e9);
    }

    function test_costIsAdditiveWithinIntegerRounding() public pure {
        uint256 firstAmount = 123_456_789e18;
        uint256 secondAmount = 234_567_890e18;
        uint256 whole = CurveMath.costWad(0, firstAmount + secondAmount);
        uint256 split = CurveMath.costWad(0, firstAmount) + CurveMath.costWad(firstAmount, secondAmount);

        assertApproxEqAbs(whole, split, 2);
    }

    function test_rawCostIsExactlyPathIndependent() public pure {
        uint256 firstAmount = 123_456_789e18;
        uint256 secondAmount = 234_567_890e18;
        uint256 whole = CurveMath.costRawUSDG(0, firstAmount + secondAmount);
        uint256 split = CurveMath.costRawUSDG(0, firstAmount) + CurveMath.costRawUSDG(firstAmount, secondAmount);

        assertEq(whole, split);
    }

    function test_buyThenSellUsesSameCurvePrincipal() public pure {
        uint256 amount = 321_000_000e18;
        assertEq(CurveMath.refundRawUSDG(amount, amount), CurveMath.costRawUSDG(0, amount));
    }

    function test_revertsWhenTradeCrossesSaleCap() public {
        vm.expectRevert(CurveMath.CurveCapExceeded.selector);
        harness.costWad(SALE_CAP, 1);
    }

    function testFuzz_costNeverDecreases(uint256 supply, uint256 amount) public pure {
        supply = bound(supply, 0, SALE_CAP - 1e18);
        amount = bound(amount, 1e18, SALE_CAP - supply);

        uint256 cost = CurveMath.costWad(supply, amount);
        assertGt(cost, 0);
    }

    function testFuzz_inverseUsesMaximumTokenQuantum(uint256 supply, uint256 rawBudget) public pure {
        supply = bound(supply, 0, SALE_CAP);
        rawBudget = bound(rawBudget, 0, 20_000e6);

        uint256 amount = CurveMath.amountForRawUSDG(supply, rawBudget);
        assertLe(CurveMath.costRawUSDG(supply, amount), rawBudget);

        if (rawBudget == 0) {
            assertEq(amount, 0);
            return;
        }

        if (amount < SALE_CAP - supply) {
            assertGt(CurveMath.costRawUSDG(supply, amount + CurveMath.TOKEN_QUANTUM), rawBudget);
        }
    }
}
