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
/// to print calibrated listing constants for Token.sol.
contract ListingParamsCalc is Test {
    int24 internal constant TICK_SPACING = 60;
    /// @dev BSC legacy bilateral-LP tests: ~19 ETH budget.
    uint256 internal constant LISTING_ETH = 19 ether;
    /// @dev RH 内盘：650M 卖满需筹集 5 ETH（Pump 曲线 `a` 标定目标）。
    uint256 internal constant BONDING_CURVE_ETH = 5 ether;
    /// @dev RH listing：200M token + 4.8 ETH 双边进池（硬约束，非 token-first）。
    uint256 internal constant MAX_POOL_ETH = 48 ether / 10;
    uint256 internal constant LISTING_TOKEN = 200_000_000 ether;
    uint256 internal constant SELL_AMOUNT = 1_000_000_000 ether; // 10亿卖压（用户指定）
    /// @dev 总供应 1B = 650M 内盘 + 200M LP + 150M Nutbox；800M 为池外可卖 token。
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @dev 800M 外部卖压后池内 ETH ≈ 0（200M 已在 LP 内，不再额外计入卖压）。
    uint256 internal constant SELL_AMOUNT_EXTERNAL = 800_000_000 ether;
    /// @dev 双边进池允许的小误差（ETH 或 token 侧）。
    uint256 internal constant LISTING_COMP_TOLERANCE = 0.01 ether;
    /// @dev 800M 外部卖压后池内可接受的 ETH 残留（≈0.016 ETH，业务上可忽略）。
    uint256 internal constant POOL_ETH_END_TOLERANCE = 0.02 ether;

    // BSC legacy hint for bilateral-LP tests only; RH primary path is token-first + tick search.
    // P (token1/token0) = LISTING_TOKEN / LISTING_ETH

    function test_computeListingParams() public pure {
        // P = token/BNB = LISTING_TOKEN / LISTING_ETH (both 18-decimal wei)
        uint256 pWad = FullMath.mulDiv(LISTING_TOKEN, 1e18, LISTING_ETH);
        uint160 sqrtP = _sqrtPriceX96FromPrice(pWad);

        int24 tickInit = TickMath.getTickAtSqrtPrice(sqrtP);
        tickInit = _alignTick(tickInit);
        sqrtP = TickMath.getSqrtPriceAtTick(tickInit);

        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        int24 bestLower = type(int24).max;
        uint256 bestBnbErr = type(uint256).max;
        uint128 bestL;

        int24 minLower = TickMath.minUsableTick(TICK_SPACING);

        for (int24 tl = minLower; tl < tickInit; tl += TICK_SPACING) {
            uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tl);
            uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);

            uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
            if (L == 0) continue;

            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
            uint256 compErr = _maxErr(a0, LISTING_ETH, a1, LISTING_TOKEN);

            uint256 bnbOut = _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT);

            uint256 bnbErr = bnbOut > LISTING_ETH ? bnbOut - LISTING_ETH : LISTING_ETH - bnbOut;

            // Primary: minimize |bnbOut - 19 BNB|; secondary: LP composition
            uint256 score = bnbErr + compErr / 1e12;

            if (score < bestBnbErr) {
                bestBnbErr = score;
                bestLower = tl;
                bestL = L;
            }
        }

        uint160 sqrtPaBest = TickMath.getSqrtPriceAtTick(bestLower);
        uint160 sqrtPbBest = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 a0f, uint256 a1f) = _amountsForLiquidity(sqrtP, sqrtPaBest, sqrtPbBest, bestL);
        uint256 bnbOutFinal = _simulateSellToken(sqrtP, sqrtPbBest, bestL, SELL_AMOUNT);

        // Print via assert so `-vv` shows values in trace; also use assembly log in real run
        assertTrue(bestLower < tickInit, "no tickLower found");
        assertTrue(bestL > 0, "zero liquidity");

        // Values visible in failure message when run with -vvv
        assertEq(bestLower, bestLower, "tickLower");
        assertEq(uint256(bestL), uint256(bestL), "liquidity");
        assertEq(a0f, a0f, "amount0");
        assertEq(a1f, a1f, "amount1");
        assertEq(bnbOutFinal, bnbOutFinal, "bnbOut");
        assertEq(uint256(sqrtP), uint256(sqrtP), "sqrtPriceX96");
        assertEq(int256(tickInit), int256(tickInit), "tickInit");
    }

    function test_printListingConstants() public view {
        uint256 pWad = FullMath.mulDiv(LISTING_TOKEN, 1e18, LISTING_ETH);
        uint160 sqrtP = _sqrtPriceX96FromPrice(pWad);
        int24 tickInit = _alignTick(TickMath.getTickAtSqrtPrice(sqrtP));
        sqrtP = TickMath.getSqrtPriceAtTick(tickInit);
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING); // floor: unlimited BNB buy headroom

        int24 bestUpper;
        uint128 bestL;
        uint256 bestScore = type(uint256).max;

        // Search tickUpper: 800M sell should drain ~19 BNB; tickLower fixed at min
        for (int24 tu = tickInit + TICK_SPACING; tu <= TickMath.maxUsableTick(TICK_SPACING); tu += TICK_SPACING) {
            uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tu);
            uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
            if (L == 0) continue;

            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
            uint256 compErr = _maxErr(a0, LISTING_ETH, a1, LISTING_TOKEN);
            uint256 bnbOut = _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT);
            uint256 bnbErr = bnbOut > LISTING_ETH ? bnbOut - LISTING_ETH : LISTING_ETH - bnbOut;

            uint256 score = bnbErr + compErr / 1e12;
            if (score < bestScore) {
                bestScore = score;
                bestUpper = tu;
                bestL = L;
            }
        }

        uint160 sqrtPaF = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPbF = TickMath.getSqrtPriceAtTick(bestUpper);
        (uint256 a0f, uint256 a1f) = _amountsForLiquidity(sqrtP, sqrtPaF, sqrtPbF, bestL);
        uint256 bnbOutF = _simulateSellToken(sqrtP, sqrtPbF, bestL, SELL_AMOUNT);

        console2.log("=== Listing constants (Token.sol) ===");
        console2.log("INITIAL_SQRT_PRICE_X96:", uint256(sqrtP));
        console2.log("tickInit:", tickInit);
        console2.log("LISTING_TICK_LOWER:", tickLower);
        console2.log("LISTING_TICK_UPPER:", bestUpper);
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(bestL));
        console2.log("LP amount0 (wei):", a0f);
        console2.log("LP amount1 (wei):", a1f);
        console2.log("Sell 800M -> BNB out (wei):", bnbOutF);
        console2.log("BNB err (wei):", bnbOutF > LISTING_ETH ? bnbOutF - LISTING_ETH : LISTING_ETH - bnbOutF);
    }

    /// @dev Scan tickLower space; run with `-vv` to see best drain-fit candidates.
    function test_scanTickLowers() public view {
        uint256 pWad = FullMath.mulDiv(LISTING_TOKEN, 1e18, LISTING_ETH);
        uint160 sqrtP = _sqrtPriceX96FromPrice(pWad);
        int24 tickInit = _alignTick(TickMath.getTickAtSqrtPrice(sqrtP));
        sqrtP = TickMath.getSqrtPriceAtTick(tickInit);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);
        int24 minLower = TickMath.minUsableTick(TICK_SPACING);

        uint256 bestBnbErr = type(uint256).max;
        int24 bestTl;
        uint128 bestL;
        uint256 bestComp = type(uint256).max;

        for (int24 tl = minLower; tl < tickInit; tl += TICK_SPACING) {
            uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tl);
            uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
            if (L == 0) continue;
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
            uint256 compErr = _maxErr(a0, LISTING_ETH, a1, LISTING_TOKEN);
            uint256 bnbOut = _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT);
            uint256 bnbErr = bnbOut > LISTING_ETH ? bnbOut - LISTING_ETH : LISTING_ETH - bnbOut;

            if (bnbErr < bestBnbErr || (bnbErr == bestBnbErr && compErr < bestComp)) {
                bestBnbErr = bnbErr;
                bestComp = compErr;
                bestTl = tl;
                bestL = L;
            }
        }

        console2.log("=== Best drain fit ===");
        console2.log("tickLower:", bestTl);
        console2.log("L:", uint256(bestL));
        console2.log("bnbErr wei:", bestBnbErr);
        console2.log("compErr wei:", bestComp);
    }

    function test_tokensNeededForFullDrain() public view {
        uint256 pWad = FullMath.mulDiv(LISTING_TOKEN, 1e18, LISTING_ETH);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(_alignTick(TickMath.getTickAtSqrtPrice(_sqrtPriceX96FromPrice(pWad))));
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
        (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
        console2.log("LP a0 0.01BNB:", a0 / 1e16);
        console2.log("LP a1 M:", a1 / 1e24);

        uint256 maxOut = _simulateSellToken(sqrtP, sqrtPb, L, type(uint128).max);
        console2.log("max sell bnbOut 0.01:", maxOut / 1e16);

        // Search tickUpper where 800M sell lands near tickUpper (full BNB drain)
        int24 tickInit = TickMath.getTickAtSqrtPrice(sqrtP);
        uint256 bestDiff = type(uint256).max;
        int24 bestTu;
        for (int24 tu = tickInit + 60; tu <= tickInit + 300000; tu += 60) {
            sqrtPb = TickMath.getSqrtPriceAtTick(tu);
            L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
            if (L == 0) continue;
            uint256 out = _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT);
            uint256 diff = out > LISTING_ETH ? out - LISTING_ETH : LISTING_ETH - out;
            if (diff < bestDiff) {
                bestDiff = diff;
                bestTu = tu;
            }
        }
        sqrtPb = TickMath.getSqrtPriceAtTick(bestTu);
        L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
        console2.log("best tu for 800M drain:", bestTu);
        console2.log("bnbOut 0.01:", _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT) / 1e16);
        (a0, a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
        console2.log("LP a0 0.01:", a0 / 1e16);
        console2.log("LP a1 M:", a1 / 1e24);
    }

    uint160 internal constant TOKEN_SQRT_PRICE_X96 = 229333670737072535143449936330532;
    int24 internal constant TOKEN_TICK_INIT = 159420;
    uint256 internal constant SELL_WHALE = 808_000_000 ether; // 800M + ~8M from 1 BNB DEX buy

    int24 internal constant TOKEN_TICK_LOWER = -887220;
    int24 internal constant TOKEN_TICK_UPPER = 191940;

    /// @dev 一次 token-first LP：200M token 全进池，BNB 由 CL 配对（~19.174 BNB）
    function test_computeTokenFirstListingConstants() public pure {
        uint160 sqrtP = TOKEN_SQRT_PRICE_X96;
        int24 tickLower = TOKEN_TICK_LOWER;
        int24 tickUpper = TOKEN_TICK_UPPER;
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 L = _liquidityForAmount1(sqrtPa, sqrtP, LISTING_TOKEN);
        (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
        uint256 tokenDust = LISTING_TOKEN > a1 ? LISTING_TOKEN - a1 : 0;

        (uint256 bnbOut, uint256 remain) = _simulateSellTokenWithRemaining(sqrtP, sqrtPb, L, SELL_WHALE);

        console2.log("=== Token-first listing constants (Token.sol) ===");
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(L));
        console2.log("LISTING_ETH_BUDGET wei:", a0);
        console2.log("LP a0 wei:", a0);
        console2.log("LP a1 wei:", a1);
        console2.log("token dust wei:", tokenDust);
        console2.log("808M bnbOut wei:", bnbOut);
        console2.log("808M remain wei:", remain);

        assertTrue(L > 0, "zero liquidity");
        assertLe(tokenDust, 1 ether, "200M token fully deposited");
    }

    /// @dev 离线标定 Token.sol 双常量：第 1 次双边 LP + 第 2 次 token 单边补 LP
    function test_computeTwoStepListingConstants() public pure {
        uint160 sqrtP = TOKEN_SQRT_PRICE_X96;
        int24 tickLower = TOKEN_TICK_LOWER;
        int24 tickUpper = TOKEN_TICK_UPPER;
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 L1 = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
        (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L1);
        uint256 tokenDust = LISTING_TOKEN > a1 ? LISTING_TOKEN - a1 : 0;

        uint128 L2 = _liquidityForAmount1(sqrtPa, sqrtP, tokenDust);
        uint128 Ltotal = L1 + L2;

        (uint256 a0t, uint256 a1t) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, Ltotal);
        uint256 compErr = _maxErr(a0t, LISTING_ETH, a1t, LISTING_TOKEN);

        (uint256 bnbOut, uint256 remain) = _simulateSellTokenWithRemaining(sqrtP, sqrtPb, Ltotal, SELL_WHALE);

        console2.log("=== Two-step listing constants (Token.sol) ===");
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(L1));
        console2.log("LISTING_TOPUP_LIQUIDITY:", uint256(L2));
        console2.log("L1 a0 wei:", a0);
        console2.log("L1 a1 wei:", a1);
        console2.log("token dust wei:", tokenDust);
        console2.log("total L:", uint256(Ltotal));
        console2.log("total LP a0 wei:", a0t);
        console2.log("total LP a1 wei:", a1t);
        console2.log("compErr wei:", compErr);
        console2.log("808M bnbOut wei:", bnbOut);
        console2.log("808M remain wei:", remain);

        assertTrue(L1 > 0 && L2 > 0, "zero liquidity");
        assertLe(compErr, 1 ether, "listing uses full budget");
    }

    /// @dev 联合搜索 tickInit + tickUpper：listing compErr <= 1 token，808M 零剩余
    function test_solveExactListingDeposit() public view {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);

        int24 bestInit;
        int24 bestUpper;
        uint128 bestL;
        uint256 bestComp = type(uint256).max;

        for (int24 ti = TOKEN_TICK_INIT - 3000; ti <= TOKEN_TICK_INIT + 3000; ti += TICK_SPACING) {
            uint160 sqrtP = TickMath.getSqrtPriceAtTick(ti);

            for (int24 tu = ti + TICK_SPACING; tu <= ti + 40000; tu += TICK_SPACING) {
                uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
                uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tu);
                uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
                if (L == 0) continue;

                (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
                uint256 compErr = _maxErr(a0, LISTING_ETH, a1, LISTING_TOKEN);
                if (compErr > 1 ether) continue;

                (uint256 bnbOut, uint256 remain) = _simulateSellTokenWithRemaining(sqrtP, sqrtPb, L, SELL_WHALE);
                if (remain > 0) continue;

                uint256 bnbErr = bnbOut > LISTING_ETH ? bnbOut - LISTING_ETH : LISTING_ETH - bnbOut;
                if (compErr < bestComp || (compErr == bestComp && bnbErr < _maxErr(bnbOut, LISTING_ETH, 0, 0))) {
                    bestComp = compErr;
                    bestInit = ti;
                    bestUpper = tu;
                    bestL = L;
                }
            }
        }

        require(bestL > 0, "no solution");

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(bestInit);
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(bestUpper);
        (uint256 a0f, uint256 a1f) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, bestL);
        (uint256 bnbOutF, uint256 remainF) = _simulateSellTokenWithRemaining(sqrtP, sqrtPb, bestL, SELL_WHALE);

        console2.log("=== Exact listing deposit (compErr <= 1 token, 808M full sell) ===");
        console2.log("INITIAL_SQRT_PRICE_X96:", uint256(sqrtP));
        console2.log("tickInit:", bestInit);
        console2.log("LISTING_TICK_UPPER:", bestUpper);
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(bestL));
        console2.log("LP a0 wei:", a0f);
        console2.log("LP a1 wei:", a1f);
        console2.log("compErr wei:", bestComp);
        console2.log("808M bnbOut wei:", bnbOutF);
        console2.log("808M remain wei:", remainF);
    }

    /// @dev 固定 tickInit=159420，搜索 tickUpper：listing dust <= 1 token 且 808M 可全部卖完
    function test_solveMinDustFullSell() public view {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        uint160 sqrtP = TOKEN_SQRT_PRICE_X96;
        int24 tickInit = TOKEN_TICK_INIT;

        int24 bestUpper;
        uint128 bestL;
        uint256 bestComp = type(uint256).max;
        uint256 bestRemain = type(uint256).max;
        uint256 bestBnbErr = type(uint256).max;

        for (int24 tu = tickInit + TICK_SPACING; tu <= tickInit + 50000; tu += TICK_SPACING) {
            uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tu);
            uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
            if (L == 0) continue;

            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
            uint256 compErr = _maxErr(a0, LISTING_ETH, a1, LISTING_TOKEN);

            (uint256 bnbOut, uint256 remain) = _simulateSellTokenWithRemaining(sqrtP, sqrtPb, L, SELL_WHALE);
            uint256 bnbErr = bnbOut > LISTING_ETH ? bnbOut - LISTING_ETH : LISTING_ETH - bnbOut;

            // 优先：808M 卖完 + listing compErr 最小 + BNB 接近 19
            if (remain == 0 && compErr <= bestComp) {
                if (compErr < bestComp || bnbErr < bestBnbErr) {
                    bestComp = compErr;
                    bestRemain = remain;
                    bestBnbErr = bnbErr;
                    bestUpper = tu;
                    bestL = L;
                }
            } else if (bestRemain > 0 && remain < bestRemain) {
                if (remain < bestRemain || (remain == bestRemain && compErr < bestComp)) {
                    bestComp = compErr;
                    bestRemain = remain;
                    bestBnbErr = bnbErr;
                    bestUpper = tu;
                    bestL = L;
                }
            }
        }

        uint160 sqrtPaF = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPbF = TickMath.getSqrtPriceAtTick(bestUpper);
        (uint256 a0f, uint256 a1f) = _amountsForLiquidity(sqrtP, sqrtPaF, sqrtPbF, bestL);
        (uint256 bnbOutF, uint256 remainF) = _simulateSellTokenWithRemaining(sqrtP, sqrtPbF, bestL, SELL_WHALE);
        uint256 tokensAtUpper = SqrtPriceMath.getAmount1Delta(sqrtPaF, sqrtPbF, bestL, false);

        console2.log("=== Optimal (fixed tickInit=159420) ===");
        console2.log("LISTING_TICK_UPPER:", bestUpper);
        console2.log("LISTING_LIQUIDITY_DELTA:", uint256(bestL));
        console2.log("LP a0 wei:", a0f);
        console2.log("LP a1 wei:", a1f);
        console2.log("compErr wei:", bestComp);
        console2.log("808M sell bnbOut wei:", bnbOutF);
        console2.log("808M sell remain wei:", remainF);
        console2.log("tokens at upper M:", tokensAtUpper / 1e24);
    }

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
        // 扩大 tickInit 搜索：更便宜的初始价 → 卖压路径上每 ETH 吸收更多 token
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

    /// @dev 800M 池外卖压全部卖完 → BNB=0，池内共 10 亿 token
    function test_solveV3_800M_allSupplyInPool() public view {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickInit = 159420;
        int24 tickUpper = 191640;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tickInit);
        uint160 sqrtPa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 L = _liquidityForAmounts(sqrtP, sqrtPa, sqrtPb, LISTING_ETH, LISTING_TOKEN);
        (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtP, sqrtPa, sqrtPb, L);
        uint256 bnbOut = _simulateSellToken(sqrtP, sqrtPb, L, SELL_AMOUNT_EXTERNAL);

        // 上界 tick 处 LP 头寸中的 token 总量
        uint256 tokensAtUpper = SqrtPriceMath.getAmount1Delta(sqrtPa, sqrtPb, L, false);

        console2.log("=== V3: 800M ext sell, 1B tokens in pool ===");
        console2.log("sqrtPriceX96:", uint256(sqrtP));
        console2.log("tickInit:", tickInit);
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);
        console2.log("L:", uint256(L));
        console2.log("LP a0 wei:", a0);
        console2.log("LP a1 wei:", a1);
        console2.log("800M sell bnbOut wei:", bnbOut);
        console2.log("tokens at upper tick wei:", tokensAtUpper);
        console2.log("tokens at upper M:", tokensAtUpper / 1e24);
    }

    function _simulateSellToken(uint160 sqrtP, uint160 sqrtPb, uint128 L, uint256 tokenIn) internal pure returns (uint256 bnbOut) {
        (bnbOut,,) = _simulateSellEndState(sqrtP, sqrtPb, L, tokenIn);
    }

    function _simulateSellTokenWithRemaining(uint160 sqrtP, uint160 sqrtPb, uint128 L, uint256 tokenIn)
        internal
        pure
        returns (uint256 bnbOut, uint256 remaining)
    {
        (bnbOut, remaining,) = _simulateSellEndState(sqrtP, sqrtPb, L, tokenIn);
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

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
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

    function _sqrtPriceX96FromPrice(uint256 priceWad) internal pure returns (uint160) {
        // sqrtPriceX96 = sqrt(priceWad / 1e18) * 2^96
        uint256 ratioX192 = FullMath.mulDiv(priceWad, uint256(1) << 192, 1e18);
        return uint160(_sqrt(ratioX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _alignTick(int24 tick) internal pure returns (int24) {
        int24 r = tick % TICK_SPACING;
        if (r == 0) return tick;
        if (tick < 0) return tick - r;
        return tick - r;
    }

    function _maxErr(uint256 a0, uint256 t0, uint256 a1, uint256 t1) internal pure returns (uint256) {
        uint256 e0 = a0 > t0 ? a0 - t0 : t0 - a0;
        uint256 e1 = a1 > t1 ? a1 - t1 : t1 - a1;
        return e0 > e1 ? e0 : e1;
    }
}
