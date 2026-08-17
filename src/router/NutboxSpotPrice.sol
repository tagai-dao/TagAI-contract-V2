// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager as IUniswapV4PoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary as UniswapV4StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId as UniswapV4PoolId} from "v4-core/types/PoolId.sol";

import {ICLPoolManager as IPancakeV4CLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolId as PancakeV4PoolId} from "infinity-core/src/types/PoolId.sol";

import "./INutboxRouter.sol";

interface INutboxV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface INutboxV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface INutboxV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface INutboxV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}

/**
 * @dev Shared authenticated spot-price reader. The caller supplies the exact input and output
 *      assets; the source registry only decides which DEX factories/managers are trusted.
 */
library NutboxSpotPrice {
    error InvalidSource();
    error UnsupportedSource();
    error InvalidPair();
    error PoolNotInitialized();
    error PriceUnavailable();

    function quote(
        INutboxRouter registry,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        INutboxRouter.SourceType sourceType,
        bytes memory sourceData
    ) internal view returns (uint256 amountOut) {
        if (tokenIn == tokenOut || (tokenIn != address(0) && tokenIn.code.length == 0)) {
            revert InvalidPair();
        }
        if (tokenOut != address(0) && tokenOut.code.length == 0) revert InvalidPair();

        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            amountOut = _quoteV2(registry, tokenIn, tokenOut, amountIn, sourceData);
        } else if (sourceType == INutboxRouter.SourceType.V3_POOL) {
            amountOut = _quoteV3(registry, tokenIn, tokenOut, amountIn, sourceData);
        } else if (sourceType == INutboxRouter.SourceType.UNISWAP_V4) {
            amountOut = _quoteUniswapV4(registry, tokenIn, tokenOut, amountIn, sourceData);
        } else if (sourceType == INutboxRouter.SourceType.PANCAKE_V4_CL) {
            amountOut = _quotePancakeV4CL(registry, tokenIn, tokenOut, amountIn, sourceData);
        } else {
            revert UnsupportedSource();
        }

        if (amountIn != 0 && amountOut == 0) revert PriceUnavailable();
    }

    function sourceTokens(INutboxRouter.SourceType sourceType, bytes memory sourceData)
        internal
        view
        returns (address token0, address token1)
    {
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            (, address pair) = abi.decode(sourceData, (address, address));
            if (pair.code.length == 0) revert InvalidSource();
            token0 = INutboxV2Pair(pair).token0();
            token1 = INutboxV2Pair(pair).token1();
        } else if (sourceType == INutboxRouter.SourceType.V3_POOL) {
            (, address pool) = abi.decode(sourceData, (address, address));
            if (pool.code.length == 0) revert InvalidSource();
            token0 = INutboxV3Pool(pool).token0();
            token1 = INutboxV3Pool(pool).token1();
        } else if (sourceType == INutboxRouter.SourceType.UNISWAP_V4) {
            INutboxRouter.UniswapV4Source memory source = abi.decode(sourceData, (INutboxRouter.UniswapV4Source));
            token0 = source.currency0;
            token1 = source.currency1;
        } else if (sourceType == INutboxRouter.SourceType.PANCAKE_V4_CL) {
            INutboxRouter.PancakeV4CLSource memory source = abi.decode(sourceData, (INutboxRouter.PancakeV4CLSource));
            token0 = source.currency0;
            token1 = source.currency1;
        } else {
            revert UnsupportedSource();
        }
    }

    function otherToken(address tokenIn, INutboxRouter.SourceType sourceType, bytes memory sourceData)
        internal
        view
        returns (address tokenOut)
    {
        (address token0, address token1) = sourceTokens(sourceType, sourceData);
        if (token0 == tokenIn) return token1;
        if (token1 == tokenIn) return token0;
        revert InvalidPair();
    }

    function _quoteV2(
        INutboxRouter registry,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory sourceData
    ) private view returns (uint256) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidPair();
        (address factory, address pair) = abi.decode(sourceData, (address, address));
        if (!registry.allowedV2Factory(factory) || pair.code.length == 0) revert InvalidSource();
        if (INutboxV2Factory(factory).getPair(tokenIn, tokenOut) != pair || INutboxV2Pair(pair).factory() != factory) {
            revert InvalidSource();
        }

        address token0 = INutboxV2Pair(pair).token0();
        address token1 = INutboxV2Pair(pair).token1();
        bool inputIs0 = _validatePair(tokenIn, tokenOut, token0, token1);
        (uint112 reserve0, uint112 reserve1,) = INutboxV2Pair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert PoolNotInitialized();
        if (amountIn == 0) return 0;
        return inputIs0
            ? Math.mulDiv(amountIn, uint256(reserve1), uint256(reserve0))
            : Math.mulDiv(amountIn, uint256(reserve0), uint256(reserve1));
    }

    function _quoteV3(
        INutboxRouter registry,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory sourceData
    ) private view returns (uint256) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidPair();
        (address factory, address pool) = abi.decode(sourceData, (address, address));
        if (!registry.allowedV3Factory(factory) || pool.code.length == 0) revert InvalidSource();

        INutboxV3Pool v3Pool = INutboxV3Pool(pool);
        uint24 poolFee = v3Pool.fee();
        if (v3Pool.factory() != factory || INutboxV3Factory(factory).getPool(tokenIn, tokenOut, poolFee) != pool) {
            revert InvalidSource();
        }
        bool inputIs0 = _validatePair(tokenIn, tokenOut, v3Pool.token0(), v3Pool.token1());
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        if (sqrtPriceX96 == 0 || v3Pool.liquidity() == 0) revert PoolNotInitialized();
        if (amountIn == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amountIn, inputIs0);
    }

    function _quoteUniswapV4(
        INutboxRouter registry,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory sourceData
    ) private view returns (uint256) {
        INutboxRouter.UniswapV4Source memory source = abi.decode(sourceData, (INutboxRouter.UniswapV4Source));
        if (!registry.allowedUniswapV4Manager(source.poolManager)) revert InvalidSource();
        bool inputIs0 = _validatePair(tokenIn, tokenOut, source.currency0, source.currency1);
        if (uint160(source.currency0) >= uint160(source.currency1)) revert InvalidPair();

        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        IUniswapV4PoolManager manager = IUniswapV4PoolManager(source.poolManager);
        (uint160 sqrtPriceX96,,,) = UniswapV4StateLibrary.getSlot0(manager, UniswapV4PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0 || UniswapV4StateLibrary.getLiquidity(manager, UniswapV4PoolId.wrap(poolId)) == 0) {
            revert PoolNotInitialized();
        }
        if (amountIn == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amountIn, inputIs0);
    }

    function _quotePancakeV4CL(
        INutboxRouter registry,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory sourceData
    ) private view returns (uint256) {
        INutboxRouter.PancakeV4CLSource memory source = abi.decode(sourceData, (INutboxRouter.PancakeV4CLSource));
        if (!registry.allowedPancakeV4CLManager(source.poolManager)) revert InvalidSource();
        bool inputIs0 = _validatePair(tokenIn, tokenOut, source.currency0, source.currency1);
        if (uint160(source.currency0) >= uint160(source.currency1)) revert InvalidPair();

        bytes32 poolId = keccak256(
            abi.encode(
                source.currency0, source.currency1, source.hooks, source.poolManager, source.fee, source.parameters
            )
        );
        IPancakeV4CLPoolManager manager = IPancakeV4CLPoolManager(source.poolManager);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(PancakeV4PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0 || manager.getLiquidity(PancakeV4PoolId.wrap(poolId)) == 0) {
            revert PoolNotInitialized();
        }
        if (amountIn == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amountIn, inputIs0);
    }

    function _validatePair(address tokenIn, address tokenOut, address token0, address token1)
        private
        pure
        returns (bool inputIs0)
    {
        if (token0 == tokenIn && token1 == tokenOut) return true;
        if (token1 == tokenIn && token0 == tokenOut) return false;
        revert InvalidPair();
    }

    function _quoteAtSqrtPrice(uint160 sqrtPriceX96, uint256 baseAmount, bool baseTokenIsToken0)
        private
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            quoteAmount = baseTokenIsToken0
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            quoteAmount = baseTokenIsToken0
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
