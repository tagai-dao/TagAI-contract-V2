// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title FeeProperty
 * @notice Property tests for fee distribution (P9) and anti-snipe formula (P10).
 */
contract FeePropertyTest is V4PumpTestBase {
    Token public token;

    uint256 constant DIVISOR = 10000;
    uint256 constant ANTI_SNIPE_WINDOW = 15;
    uint256 constant ANTI_SNIPE_FEE_MAX = 8000;
    uint256 constant ANTI_SNIPE_DENOM = 225;

    function setUp() public override {
        super.setUp();
        if (!envReady) return;
        token = _createToken("FEE");
    }

    function testFuzz_P9_feeDistributionCorrectness(uint256 swapAmount) public onlyReady {
        swapAmount = bound(swapAmount, 1e8, 1_000_000 ether);

        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 totalFeeRatio = feeRatio[0] + feeRatio[1];
        uint256 totalFee = (swapAmount * totalFeeRatio) / DIVISOR;
        uint256 platformFee = (swapAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;

        assertEq(platformFee + deployerFee, totalFee);
        assertEq(platformFee, (swapAmount * 30) / DIVISOR);
        assertApproxEqAbs(deployerFee, (swapAmount * 30) / DIVISOR, 1);
    }

    function testFuzz_P9_feeNeverExceedsSwapAmount(uint256 swapAmount, uint256 platformBPS, uint256 deployerBPS)
        public
        onlyReady
    {
        platformBPS = bound(platformBPS, 0, 1000);
        deployerBPS = bound(deployerBPS, 0, 1000);
        swapAmount = bound(swapAmount, 1, 1_000_000 ether);
        assertLe((swapAmount * (platformBPS + deployerBPS)) / DIVISOR, swapAmount);
    }

    function testFuzz_P10_antiSnipeFormula_withinWindow(uint256 elapsed, uint256) public onlyReady {
        elapsed = bound(elapsed, 1, ANTI_SNIPE_WINDOW - 1);

        vm.prank(buyer, buyer);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.warp(token.createdAt() + elapsed);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 remaining = ANTI_SNIPE_WINDOW - elapsed;
        uint256 expectedSellsman =
            feeRatio[1] + ((ANTI_SNIPE_FEE_MAX - feeRatio[1]) * remaining * remaining) / ANTI_SNIPE_DENOM;

        assertEq(platformFee, feeRatio[0]);
        assertEq(sellsmanFee, expectedSellsman);
    }

    function testFuzz_P10_antiSnipeFormula_normalAfterWindow(uint256 elapsed) public onlyReady {
        elapsed = bound(elapsed, ANTI_SNIPE_WINDOW, 1000);

        vm.prank(buyer, buyer);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.warp(token.createdAt() + elapsed);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        uint256[2] memory feeRatio = pump.getFeeRatio();
        assertEq(platformFee, feeRatio[0]);
        assertEq(sellsmanFee, feeRatio[1]);
    }

    function test_P10_antiSnipeFormula_atZeroElapsed() public onlyReady {
        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        uint256[2] memory feeRatio = pump.getFeeRatio();
        assertEq(platformFee, feeRatio[0]);
        assertEq(sellsmanFee, ANTI_SNIPE_FEE_MAX);
    }
}
