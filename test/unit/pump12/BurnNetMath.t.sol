// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BurnNetMath} from "../../../src/pump12/libraries/BurnNetMath.sol";

contract BurnNetMathHarness {
    function tierTicks(int24 anchorTick, uint8 tier, bool usdgIsCurrency0) external pure returns (int24, int24) {
        return BurnNetMath.tierTicks(anchorTick, tier, usdgIsCurrency0);
    }

    function kappa3Wad(uint256 l3UsdGRaw, uint256 anchorWad, uint256 supply) external pure returns (uint256) {
        return BurnNetMath.kappa3Wad(l3UsdGRaw, anchorWad, supply);
    }

    function allocate(uint256 amount, uint256 kappa, uint256 l3, uint256 total)
        external
        pure
        returns (uint256[7] memory)
    {
        return BurnNetMath.allocate(amount, kappa, l3, total);
    }
}

contract BurnNetMathTest is Test {
    BurnNetMathHarness internal math = new BurnNetMathHarness();

    function test_emptyNetAllocatesEightTwelveEighty() public view {
        uint256[7] memory parts = math.allocate(100_000_000, 0, 0, 0);
        assertEq(parts[0] + parts[1] + parts[2], 8_000_000);
        assertEq(parts[3] + parts[4] + parts[5], 12_000_000);
        assertEq(parts[6], 80_000_000);
        assertEq(_sum(parts), 100_000_000);
    }

    function test_armoredNetInjectsFortySixtyAndMaintainsL3Floor() public view {
        uint256[7] memory parts = math.allocate(100_000_000, 1e18, 80_000_000, 100_000_000);
        assertEq(parts[0] + parts[1] + parts[2], 40_000_000);
        assertEq(parts[3] + parts[4] + parts[5], 60_000_000);
        assertEq(parts[6], 0);

        parts = math.allocate(1_000_000_000, 1e18, 40_000_000, 100_000_000);
        assertEq(40_000_000 + parts[6], uint256(1_100_000_000 * 4_000 + 9_999) / 10_000);
        assertEq(_sum(parts), 1_000_000_000);
    }

    function test_kappaUsesUsdGAndTokenDecimals() public view {
        uint256 kappa = math.kappa3Wad(30_000e6, 60_000_000_000_000, 1_000_000_000e18);
        assertEq(kappa, 1e18);
    }

    function test_tiersPointTowardLowerTokenPriceForBothCurrencyOrders() public view {
        (int24 lower0, int24 upper0) = math.tierTicks(100_000, 0, true);
        (int24 lower6, int24 upper6) = math.tierTicks(100_000, 6, true);
        assertGt(lower0, 100_000);
        assertGt(lower6, lower0);
        assertEq(upper0 - lower0, 60);

        (lower0, upper0) = math.tierTicks(100_000, 0, false);
        (lower6, upper6) = math.tierTicks(100_000, 6, false);
        assertLt(upper0, 100_000);
        assertLt(upper6, upper0);
        assertEq(upper6 - lower6, 60);
    }

    function _sum(uint256[7] memory values) private pure returns (uint256 sum) {
        for (uint256 i; i < values.length; ++i) {
            sum += values[i];
        }
    }
}
