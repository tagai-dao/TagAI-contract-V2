// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @dev Off-chain helper: run `forge test --match-contract ListingParamsCalc -vv`
/// to print calibrated RH listing constants for Token.sol.
contract ListingParamsCalc is Test {
    int24 internal constant TICK_SPACING = 60;
    /// @dev RH 内盘：650M 卖满需筹集 5 ETH（Pump 曲线 `a` 标定目标）。
    uint256 internal constant BONDING_CURVE_ETH = 5 ether;
    /// @dev RH listing：200M token + 4.8 ETH 双边进池（硬约束，非 token-first）。
    uint256 internal constant MAX_POOL_ETH = 48 ether / 10;
    uint256 internal constant LISTING_TOKEN = 200_000_000 ether;
    /// @dev 800M 外部卖压后池内 ETH ≈ 0（200M 已在 LP 内，不再额外计入卖压）。
    uint256 internal constant SELL_AMOUNT_EXTERNAL = 800_000_000 ether;
    /// @dev 双边进池允许的小误差（ETH 或 token 侧）。
    uint256 internal constant LISTING_COMP_TOLERANCE = 0.01 ether;
    /// @dev 800M 外部卖压后池内可接受的 ETH 残留（≈0.016 ETH，业务上可忽略）。
    uint256 internal constant POOL_ETH_END_TOLERANCE = 0.02 ether;

    /// @dev RH 硬性条件（允许进池小误差）：
    ///   1) 650M 内盘 → 5 ETH
    ///   2) listing 双边 ~200M + ~4.8 ETH
    ///   3) 池外 800M 全部卖进池后，池内 ETH ≈ 0
    ///   4) tickLower = min
    function test_solveRH_listingConstants() public pure {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);

        (int24 bestInit, int24 bestUpper, uint128 bestL,) = _searchRHListing(tickLower, 1200, 50000);
        require(bestL > 0, "coarse: no solution");

        (bestInit, bestUpper, bestL,) = _searchRHListingFine(
            tickLower,
            bestInit - 1200,
            bestInit + 1200,
            bestUpper - 3000,
            bestUpper + 3000
        );

        require(bestL > 0, "fine: no solution");

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(bestInit);
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(bestUpper);
        (uint256 a0f, uint256 a1f) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, bestL);
        uint256 compErr = _maxErr(a0f, MAX_POOL_ETH, a1f, LISTING_TOKEN);
        (uint256 ethOutF, uint256 sellRemainF, uint160 finalSqrtF) =
            _simulateSellEndState(sqrtP, sqrtPb, bestL, SELL_AMOUNT_EXTERNAL);
        uint256 poolEthF = _ethInPoolAt(finalSqrtF, sqrtPb, bestL);
        uint256 poolTokenF = _tokenInPoolAt(sqrtPa, finalSqrtF, bestL);

        console2.log("=== RH listing constants (Token.sol) ===");
        console2.log("INITIAL_SQRT_PRICE_X96:", uint256(sqrtP));
        console2.log("tickInit:", bestInit);
        console2.log("LISTING_TICK_LOWER:", tickLower);
        console2.log("LISTING_TICK_UPPER:", bestUpper);
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(bestL));
        console2.log("LISTING_ETH_BUDGET wei:", MAX_POOL_ETH);
        console2.log("LP a0 wei:", a0f);
        console2.log("LP a1 wei:", a1f);
        console2.log("listing compErr wei:", compErr);
        console2.log("800M ethOut wei:", ethOutF);
        console2.log("800M sell remain wei:", sellRemainF);
        console2.log("final tick:", TickMath.getTickAtSqrtPrice(finalSqrtF));
        console2.log("pool ETH end wei:", poolEthF);
        console2.log("pool token end wei:", poolTokenF);

        assertLe(compErr, LISTING_COMP_TOLERANCE, "200M+4.8ETH bilateral within tolerance");
        assertEq(sellRemainF, 0, "800M external must fully sell");
        assertLe(poolEthF, POOL_ETH_END_TOLERANCE, "pool ETH end ~ 0");
        assertApproxEqAbs(ethOutF, a0f, POOL_ETH_END_TOLERANCE, "800M drains pool ETH");
    }

    /// @dev 验证 Pump 曲线 `a`：650M 卖满 ≈ 5 ETH（`b` 不变，离线调 `a`）。
    function test_verifyRHCurveEth() public pure {
        uint256 a = 1_624_898_729; // 650M → 5 ETH @ b=2.5175516438e26
        uint256 b = 2.5175516438e26;
        uint256 ab = FixedPointMathLib.mulWad(a, b);
        uint256 e = uint256(FixedPointMathLib.expWad(int256((650_000_000 ether * 1e18) / b)));
        uint256 ethAtCap = FixedPointMathLib.mulWad(e - 1e18, ab);
        console2.log("650M curve ETH wei:", ethAtCap);
        console2.log("650M curve ETH:", ethAtCap / 1e18);
        assertApproxEqAbs(ethAtCap, BONDING_CURVE_ETH, 0.05 ether, "curve must raise ~5 ETH");
    }

    /// @dev 双边 LP：必须同时存入 200M + 4.8 ETH（误差 ≤ 1 token / 1 wei 级 compErr）。
    function _tryRHListingCandidate(
        uint160 sqrtP,
        uint160 sqrtPa,
        uint160 sqrtPb
    ) private pure returns (uint128 L, uint256 a0, uint256 a1, bool ok) {
        L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, MAX_POOL_ETH, LISTING_TOKEN);
        if (L == 0) return (0, 0, 0, false);

        (a0, a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
        if (_maxErr(a0, MAX_POOL_ETH, a1, LISTING_TOKEN) > LISTING_COMP_TOLERANCE) return (L, a0, a1, false);

        ok = true;
    }

    function _searchRHListing(int24 tickLower, int24 upperStep, int24 upperSpan)
        private
        pure
        returns (int24 bestInit, int24 bestUpper, uint128 bestL, uint256 bestScore)
    {
        int24 searchLo = 150000;
        int24 searchHi = 220000;
        return _searchRHListingRange(tickLower, searchLo, searchHi, int24(0), upperSpan, upperStep);
    }

    function _scoreRHCandidate(uint256 poolEth, uint256 sellRemain, uint256 compErr) private pure returns (uint256) {
        uint256 sellPenalty = sellRemain > 0 ? sellRemain * 1e15 : 0;
        return sellPenalty + poolEth * 1e6 + compErr;
    }

    function _searchRHListingFine(
        int24 tickLower,
        int24 initLo,
        int24 initHi,
        int24 upperLo,
        int24 upperHi
    ) private pure returns (int24 bestInit, int24 bestUpper, uint128 bestL, uint256 bestScore) {
        bestScore = type(uint256).max;

        for (int24 ti = initLo; ti <= initHi; ti += TICK_SPACING) {
            if (ti <= tickLower + TICK_SPACING) continue;

            int24 tuMin = ti + TICK_SPACING;
            int24 tuStart = upperLo > tuMin ? upperLo : tuMin;

            for (int24 tu = tuStart; tu <= upperHi; tu += TICK_SPACING) {
                uint160 sqrtP = TickMath.getSqrtPriceAtTick(ti);
                uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
                uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tu);

                (uint128 L, uint256 a0, uint256 a1, bool ok) = _tryRHListingCandidate(sqrtP, sqrtPa, sqrtPb);
                if (!ok) continue;

                uint256 compErr = _maxErr(a0, MAX_POOL_ETH, a1, LISTING_TOKEN);

                (, uint256 sellRemain, uint160 finalSqrt) =
                    _simulateSellEndState(sqrtP, sqrtPb, L, SELL_AMOUNT_EXTERNAL);

                uint256 poolEth = _ethInPoolAt(finalSqrt, sqrtPb, L);

                uint256 score = _scoreRHCandidate(poolEth, sellRemain, compErr);

                if (score < bestScore) {
                    bestScore = score;
                    bestInit = ti;
                    bestUpper = tu;
                    bestL = L;
                }
            }
        }
    }

    function _searchRHListingRange(
        int24 tickLower,
        int24 initLo,
        int24 initHi,
        int24 upperOffsetLo,
        int24 upperOffsetHi,
        int24 upperStep
    ) private pure returns (int24 bestInit, int24 bestUpper, uint128 bestL, uint256 bestScore) {
        bestScore = type(uint256).max;

        for (int24 ti = initLo; ti <= initHi; ti += TICK_SPACING) {
            if (ti <= tickLower + TICK_SPACING) continue;

            int24 tuStart = ti + TICK_SPACING + upperOffsetLo;
            int24 tuEnd = ti + TICK_SPACING + upperOffsetHi;

            for (int24 tu = tuStart; tu <= tuEnd; tu += upperStep) {
                uint160 sqrtP = TickMath.getSqrtPriceAtTick(ti);
                uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
                uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tu);

                (uint128 L, uint256 a0, uint256 a1, bool ok) = _tryRHListingCandidate(sqrtP, sqrtPa, sqrtPb);
                if (!ok) continue;

                uint256 compErr = _maxErr(a0, MAX_POOL_ETH, a1, LISTING_TOKEN);

                (, uint256 sellRemain, uint160 finalSqrt) =
                    _simulateSellEndState(sqrtP, sqrtPb, L, SELL_AMOUNT_EXTERNAL);

                uint256 poolEth = _ethInPoolAt(finalSqrt, sqrtPb, L);

                uint256 score = _scoreRHCandidate(poolEth, sellRemain, compErr);

                if (score < bestScore) {
                    bestScore = score;
                    bestInit = ti;
                    bestUpper = tu;
                    bestL = L;
                }
            }
        }
    }

    /// @dev Token sell (token1 in, token0 out): price moves up toward sqrtPb.
    function _simulateSellEndState(uint160 sqrtP, uint160 sqrtPb, uint128 L, uint256 tokenIn)
        internal
        pure
        returns (uint256 ethOut, uint256 remaining, uint160 finalSqrt)
    {
        uint160 cur = sqrtP;
        remaining = tokenIn;

        while (remaining > 0 && cur < sqrtPb - 1) {
            uint160 target = sqrtPb - 1;
            (uint160 sqrtNext, uint256 amountIn, uint256 amountOut,) =
                SwapMath.computeSwapStep(cur, target, L, -int256(remaining), 0);

            if (amountIn == 0 && amountOut == 0) break;
            ethOut += amountOut;
            if (amountIn >= remaining) {
                remaining = 0;
                cur = sqrtNext;
                break;
            }
            remaining -= amountIn;
            cur = sqrtNext;
        }

        finalSqrt = cur;
    }

    /// @dev ETH (token0) remaining in LP at sqrtP within [sqrtPa, sqrtPb].
    function _ethInPoolAt(uint160 sqrtP, uint160 sqrtPb, uint128 L) internal pure returns (uint256) {
        if (sqrtP >= sqrtPb) return 0;
        return SqrtPriceMath.getAmount0Delta(sqrtP, sqrtPb, L, false);
    }

    /// @dev Token (token1) remaining in LP at sqrtP within [sqrtPa, sqrtPb].
    function _tokenInPoolAt(uint160 sqrtPa, uint160 sqrtP, uint128 L) internal pure returns (uint256) {
        if (sqrtP <= sqrtPa) return 0;
        return SqrtPriceMath.getAmount1Delta(sqrtPa, sqrtP, L, false);
    }

    function _liquidityForAmounts(
        uint160 sqrtP,
        uint160 sqrtA,
        uint160 sqrtB,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 L) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        if (sqrtP <= sqrtA) {
            L = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 L0 = _liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 L1 = _liquidityForAmount1(sqrtA, sqrtP, amount1);
            L = L0 < L1 ? L0 : L1;
        } else {
            L = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtA), uint256(sqrtB), FixedPoint96.Q96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA));
    }

    function _amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 L)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, L, true);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, L, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, L, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, L, false);
        }
    }

    function _maxErr(uint256 a0, uint256 t0, uint256 a1, uint256 t1) internal pure returns (uint256) {
        uint256 e0 = a0 > t0 ? a0 - t0 : t0 - a0;
        uint256 e1 = a1 > t1 ? a1 - t1 : t1 - a1;
        return e0 > e1 ? e0 : e1;
    }
}
