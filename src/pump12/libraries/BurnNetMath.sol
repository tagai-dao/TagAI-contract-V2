// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title BurnNetMath
/// @notice Seven-rung tick placement and L3 armor allocation for USDG-denominated Pump12 pools.
library BurnNetMath {
    uint8 internal constant TIER_COUNT = 7;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant WAD = 1e18;

    error InvalidTier(uint8 tier);

    function tierDropBps(uint8 tier) internal pure returns (uint16) {
        if (tier == 0) return 500;
        if (tier == 1) return 1_000;
        if (tier == 2) return 1_500;
        if (tier == 3) return 2_000;
        if (tier == 4) return 3_000;
        if (tier == 5) return 4_000;
        if (tier == 6) return 5_000;
        revert InvalidTier(tier);
    }

    /// @dev Independently rounded offsets for -5/-10/-15/-20/-30/-40/-50 percent.
    function tierOffset(uint8 tier) internal pure returns (int24) {
        if (tier == 0) return 540;
        if (tier == 1) return 1_080;
        if (tier == 2) return 1_680;
        if (tier == 3) return 2_280;
        if (tier == 4) return 3_600;
        if (tier == 5) return 5_160;
        if (tier == 6) return 6_960;
        revert InvalidTier(tier);
    }

    /// @notice Returns a one-tick-spacing maker range on the lower Token-price side of the anchor.
    function tierTicks(int24 anchorTick, uint8 tier, bool usdgIsCurrency0)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 offset = tierOffset(tier);
        if (usdgIsCurrency0) {
            tickLower = alignUp(anchorTick + offset, TICK_SPACING);
            tickUpper = tickLower + TICK_SPACING;
        } else {
            tickUpper = alignDown(anchorTick - offset, TICK_SPACING);
            tickLower = tickUpper - TICK_SPACING;
        }
    }

    function tierSalt(uint64 generation, uint8 tier) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("PUMP12_BURN_NET", generation, tier));
    }

    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
        return compressed * spacing;
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 down = alignDown(tick, spacing);
        return down == tick ? tick : down + spacing;
    }

    /// @notice κ3 WAD = 2 × L3 USDG / (anchor × circulating supply).
    function kappa3Wad(uint256 l3UsdGRaw, uint256 anchorWad, uint256 circulatingSupply)
        internal
        pure
        returns (uint256)
    {
        if (circulatingSupply == 0) return type(uint256).max;
        uint256 marketCapWad = FullMath.mulDiv(anchorWad, circulatingSupply, WAD);
        if (marketCapWad == 0) return type(uint256).max;
        return FullMath.mulDiv(l3UsdGRaw * 1e12, 2e18, marketCapWad);
    }

    /// @notice Empty net resolves to 8/12/80; subsequent injection follows κ3 and clamps L3 to 40%-80%.
    function allocate(uint256 amount, uint256 kappaWad, uint256 l3Standing, uint256 totalStanding)
        internal
        pure
        returns (uint256[7] memory amounts)
    {
        uint256 toL1;
        uint256 toL2;
        uint256 toL3;
        if (kappaWad < WAD) {
            toL3 = amount;
        } else {
            toL1 = amount * 4_000 / 10_000;
            toL2 = amount - toL1;
        }

        uint256 newTotal = totalStanding + amount;
        uint256 newL3 = l3Standing + toL3;
        uint256 maxL3 = newTotal * 8_000 / 10_000;
        if (newL3 > maxL3) {
            uint256 spill = newL3 - maxL3;
            if (spill > toL3) spill = toL3;
            toL3 -= spill;
            uint256 addL1 = spill * 4_000 / 10_000;
            toL1 += addL1;
            toL2 += spill - addL1;
        } else if (newL3 * 10_000 < newTotal * 4_000) {
            uint256 minL3 = (newTotal * 4_000 + 9_999) / 10_000;
            uint256 pull = minL3 - newL3;
            uint256 upperBudget = toL1 + toL2;
            if (pull > upperBudget) pull = upperBudget;
            uint256 fromL1 = upperBudget == 0 ? 0 : pull * toL1 / upperBudget;
            uint256 fromL2 = pull - fromL1;
            toL1 -= fromL1;
            toL2 -= fromL2;
            toL3 += pull;
        }

        amounts[0] = toL1 / 3;
        amounts[1] = toL1 / 3;
        amounts[2] = toL1 - amounts[0] - amounts[1];
        amounts[3] = toL2 / 3;
        amounts[4] = toL2 / 3;
        amounts[5] = toL2 - amounts[3] - amounts[4];
        amounts[6] = toL3;
    }

    function liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (amount0 == 0 || sqrtA == sqrtB) return 0;
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, uint256(1) << 96);
        uint256 liquidity = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
        return liquidity > type(uint128).max ? type(uint128).max : uint128(liquidity);
    }

    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (amount1 == 0 || sqrtA == sqrtB) return 0;
        uint256 liquidity = FullMath.mulDiv(amount1, uint256(1) << 96, sqrtB - sqrtA);
        return liquidity > type(uint128).max ? type(uint128).max : uint128(liquidity);
    }

    function amount0Ceil(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (liquidity == 0 || sqrtA == sqrtB) return 0;
        uint256 numerator = FullMath.mulDivRoundingUp(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB);
        return (numerator + sqrtA - 1) / sqrtA;
    }

    function amount1Ceil(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (liquidity == 0 || sqrtA == sqrtB) return 0;
        return FullMath.mulDivRoundingUp(liquidity, sqrtB - sqrtA, uint256(1) << 96);
    }
}
