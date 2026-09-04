// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @notice Uniswap LiquidityAmounts 中基础 POL 所需的最小纯函数子集。
library BaseLiquidityMath {
    using SafeCast for uint256;

    function forAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA).toUint128();
    }

    function forAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA).toUint128();
    }

    function forAmounts(uint160 sqrtPrice, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtPrice <= sqrtA) return forAmount0(sqrtA, sqrtB, amount0);
        if (sqrtPrice >= sqrtB) return forAmount1(sqrtA, sqrtB, amount1);

        uint128 liquidity0 = forAmount0(sqrtPrice, sqrtB, amount0);
        uint128 liquidity1 = forAmount1(sqrtA, sqrtPrice, amount1);
        return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }
}
