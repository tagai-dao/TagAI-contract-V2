// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {UsdG} from "./UsdG.sol";

/// @title CurveMath
/// @notice Pump9 同形指数曲线，Token 数量与 USDG 价格均使用 18 位 WAD。
library CurveMath {
    uint256 internal constant SALE_CAP = 750_000_000e18;
    uint256 internal constant TOKEN_QUANTUM = 1e12;

    // b_old(251,755,164.38) × 750 / 650，向下取最接近的 18 位整数。
    uint256 internal constant B_RAW = 290_486_728_130_769_230_769_230_769;
    // 使用 Solady 实际定点运算标定，使售满后向上换算恰好为 15,000e6 raw USDG。
    uint256 internal constant A_RAW = 4_224_999_928_192;

    error CurveCapExceeded();

    function costWad(uint256 soldSupply, uint256 amount) internal pure returns (uint256) {
        if (soldSupply > SALE_CAP || amount > SALE_CAP - soldSupply) revert CurveCapExceeded();
        if (amount == 0) return 0;

        uint256 ab = FixedPointMathLib.mulWad(A_RAW, B_RAW);
        uint256 endExponent =
            uint256(FixedPointMathLib.expWad(int256(FixedPointMathLib.divWad(soldSupply + amount, B_RAW))));
        uint256 startExponent = uint256(FixedPointMathLib.expWad(int256(FixedPointMathLib.divWad(soldSupply, B_RAW))));

        return FixedPointMathLib.mulWad(endExponent - startExponent, ab);
    }

    /// @notice 路径无关的累计曲线应收；只在累计值上做一次向上舍入。
    function cumulativeRawUSDG(uint256 soldSupply) internal pure returns (uint256) {
        if (soldSupply > SALE_CAP) revert CurveCapExceeded();
        return UsdG.toRaw6Up(costWad(0, soldSupply));
    }

    /// @notice 买入区间的 raw USDG 成本。累计值相减保证拆单不会制造额外 rounding 收入。
    function costRawUSDG(uint256 soldSupply, uint256 amount) internal pure returns (uint256) {
        if (soldSupply > SALE_CAP || amount > SALE_CAP - soldSupply) revert CurveCapExceeded();
        return cumulativeRawUSDG(soldSupply + amount) - cumulativeRawUSDG(soldSupply);
    }

    /// @notice 卖出 amount 后应从 Curve reserve 扣除的毛退款。
    function refundRawUSDG(uint256 soldSupply, uint256 amount) internal pure returns (uint256) {
        if (soldSupply > SALE_CAP || amount > soldSupply) revert CurveCapExceeded();
        return cumulativeRawUSDG(soldSupply) - cumulativeRawUSDG(soldSupply - amount);
    }

    /// @notice 在 raw USDG 预算内返回以 1e-6 Token 为粒度的最大买入数量。
    function amountForRawUSDG(uint256 soldSupply, uint256 rawBudget) internal pure returns (uint256 amount) {
        if (soldSupply > SALE_CAP) revert CurveCapExceeded();
        if (rawBudget == 0 || soldSupply == SALE_CAP) return 0;

        uint256 remaining = SALE_CAP - soldSupply;
        if (costRawUSDG(soldSupply, remaining) <= rawBudget) return remaining;

        uint256 ab = FixedPointMathLib.mulWad(A_RAW, B_RAW);
        uint256 targetCumulativeWad = UsdG.toWad(cumulativeRawUSDG(soldSupply) + rawBudget);
        uint256 targetExponent = UsdG.WAD + FixedPointMathLib.divWad(targetCumulativeWad, ab);
        uint256 targetSold = FixedPointMathLib.mulWad(B_RAW, uint256(FixedPointMathLib.lnWad(int256(targetExponent))));

        amount = targetSold > soldSupply ? targetSold - soldSupply : 0;
        if (amount > remaining) amount = remaining;
        amount = amount / TOKEN_QUANTUM * TOKEN_QUANTUM;

        // 解析反函数只会产生极小定点误差；有限修正把 raw6 边界钉在协议侧。
        for (uint256 i; i < 4 && amount > 0 && costRawUSDG(soldSupply, amount) > rawBudget; ++i) {
            amount -= TOKEN_QUANTUM;
        }
        for (uint256 i; i < 4 && amount + TOKEN_QUANTUM <= remaining; ++i) {
            if (costRawUSDG(soldSupply, amount + TOKEN_QUANTUM) > rawBudget) break;
            amount += TOKEN_QUANTUM;
        }
    }

    function startPriceWad() internal pure returns (uint256) {
        return A_RAW;
    }

    function endPriceWad() internal pure returns (uint256) {
        uint256 exponent = uint256(FixedPointMathLib.expWad(int256(FixedPointMathLib.divWad(SALE_CAP, B_RAW))));
        return FixedPointMathLib.mulWad(A_RAW, exponent);
    }
}
