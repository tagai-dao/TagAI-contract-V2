// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager as IUniswapV4PoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary as UniswapV4StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId as UniswapV4PoolId} from "v4-core/types/PoolId.sol";

import {ICLPoolManager as IPancakeV4CLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolId as PancakeV4PoolId} from "infinity-core/src/types/PoolId.sol";

import "./IIndexBrokerNFTPriceOracle.sol";

interface IV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IV3Pool {
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
 * @title IndexBrokerNFTPriceOracle
 * @notice Shared spot-price adapter for all Index Broker NFT AMMs on one chain.
 * @dev DEX factories and pool managers are fixed at deployment. This contract deliberately
 *      uses the current pool spot price and does not attempt to resist price manipulation.
 */
contract IndexBrokerNFTPriceOracle is IIndexBrokerNFTPriceOracle {
    address public immutable override wrappedNative;

    mapping(address => bool) public allowedV2Factory;
    mapping(address => bool) public allowedV3Factory;
    mapping(address => bool) public allowedUniswapV4Manager;
    mapping(address => bool) public allowedPancakeV4CLManager;

    error InvalidAddress();
    error InvalidSource();
    error UnsupportedSource();
    error InvalidPair();
    error PoolNotInitialized();
    error PriceUnavailable();

    constructor(
        address wrappedNative_,
        address[] memory v2Factories_,
        address[] memory v3Factories_,
        address[] memory uniswapV4Managers_,
        address[] memory pancakeV4CLManagers_
    ) {
        if (wrappedNative_.code.length == 0) revert InvalidAddress();
        wrappedNative = wrappedNative_;
        _allow(v2Factories_, allowedV2Factory);
        _allow(v3Factories_, allowedV3Factory);
        _allow(uniswapV4Managers_, allowedUniswapV4Manager);
        _allow(pancakeV4CLManagers_, allowedPancakeV4CLManager);
    }

    function validateSource(address communityToken, SourceType sourceType, bytes calldata sourceData)
        external
        view
        override
    {
        _quoteNative(communityToken, 0, sourceType, sourceData);
    }

    function quoteNative(
        address communityToken,
        uint256 communityTokenAmount,
        SourceType sourceType,
        bytes calldata sourceData
    ) external view override returns (uint256 nativeAmount) {
        if (communityTokenAmount == 0) return 0;
        nativeAmount = _quoteNative(communityToken, communityTokenAmount, sourceType, sourceData);
        if (nativeAmount == 0) revert PriceUnavailable();
    }

    function _quoteNative(
        address communityToken,
        uint256 communityTokenAmount,
        SourceType sourceType,
        bytes calldata sourceData
    ) internal view returns (uint256) {
        if (communityToken.code.length == 0 || communityToken == wrappedNative) {
            revert InvalidPair();
        }

        if (sourceType == SourceType.V2_PAIR) {
            return _quoteV2(communityToken, communityTokenAmount, sourceData);
        }
        if (sourceType == SourceType.V3_POOL) {
            return _quoteV3(communityToken, communityTokenAmount, sourceData);
        }
        if (sourceType == SourceType.UNISWAP_V4) {
            return _quoteUniswapV4(communityToken, communityTokenAmount, sourceData);
        }
        if (sourceType == SourceType.PANCAKE_V4_CL) {
            return _quotePancakeV4CL(communityToken, communityTokenAmount, sourceData);
        }
        revert UnsupportedSource();
    }

    function _quoteV2(address communityToken, uint256 amount, bytes calldata sourceData)
        internal
        view
        returns (uint256)
    {
        (address factory, address pair) = abi.decode(sourceData, (address, address));
        if (!allowedV2Factory[factory] || pair.code.length == 0) revert InvalidSource();
        if (IV2Factory(factory).getPair(communityToken, wrappedNative) != pair || IV2Pair(pair).factory() != factory) {
            revert InvalidSource();
        }

        address token0 = IV2Pair(pair).token0();
        address token1 = IV2Pair(pair).token1();
        bool tokenIs0 = _validatePair(communityToken, token0, token1, false);
        (uint112 reserve0, uint112 reserve1,) = IV2Pair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert PoolNotInitialized();
        if (amount == 0) return 0;

        return tokenIs0
            ? Math.mulDiv(amount, uint256(reserve1), uint256(reserve0))
            : Math.mulDiv(amount, uint256(reserve0), uint256(reserve1));
    }

    function _quoteV3(address communityToken, uint256 amount, bytes calldata sourceData)
        internal
        view
        returns (uint256)
    {
        (address factory, address pool) = abi.decode(sourceData, (address, address));
        if (!allowedV3Factory[factory] || pool.code.length == 0) revert InvalidSource();

        IV3Pool v3Pool = IV3Pool(pool);
        uint24 poolFee = v3Pool.fee();
        if (v3Pool.factory() != factory || IV3Factory(factory).getPool(communityToken, wrappedNative, poolFee) != pool) revert InvalidSource();

        bool tokenIs0 = _validatePair(communityToken, v3Pool.token0(), v3Pool.token1(), false);
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        if (sqrtPriceX96 == 0 || v3Pool.liquidity() == 0) revert PoolNotInitialized();
        if (amount == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amount, tokenIs0);
    }

    function _quoteUniswapV4(address communityToken, uint256 amount, bytes calldata sourceData)
        internal
        view
        returns (uint256)
    {
        UniswapV4Source memory source = abi.decode(sourceData, (UniswapV4Source));
        if (!allowedUniswapV4Manager[source.poolManager]) revert InvalidSource();
        bool tokenIs0 = _validatePair(communityToken, source.currency0, source.currency1, true);
        if (uint160(source.currency0) >= uint160(source.currency1)) revert InvalidPair();

        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        IUniswapV4PoolManager manager = IUniswapV4PoolManager(source.poolManager);
        (uint160 sqrtPriceX96,,,) = UniswapV4StateLibrary.getSlot0(manager, UniswapV4PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0 || UniswapV4StateLibrary.getLiquidity(manager, UniswapV4PoolId.wrap(poolId)) == 0) {
            revert PoolNotInitialized();
        }
        if (amount == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amount, tokenIs0);
    }

    function _quotePancakeV4CL(address communityToken, uint256 amount, bytes calldata sourceData)
        internal
        view
        returns (uint256)
    {
        PancakeV4CLSource memory source = abi.decode(sourceData, (PancakeV4CLSource));
        if (!allowedPancakeV4CLManager[source.poolManager]) revert InvalidSource();
        bool tokenIs0 = _validatePair(communityToken, source.currency0, source.currency1, true);
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
        if (amount == 0) return 0;
        return _quoteAtSqrtPrice(sqrtPriceX96, amount, tokenIs0);
    }

    function _validatePair(address communityToken, address currency0, address currency1, bool allowNative)
        internal
        view
        returns (bool tokenIs0)
    {
        address quoteAsset;
        if (currency0 == communityToken) {
            tokenIs0 = true;
            quoteAsset = currency1;
        } else if (currency1 == communityToken) {
            quoteAsset = currency0;
        } else {
            revert InvalidPair();
        }

        if (quoteAsset != wrappedNative && (!allowNative || quoteAsset != address(0))) revert InvalidPair();
    }

    function _quoteAtSqrtPrice(uint160 sqrtPriceX96, uint256 baseAmount, bool baseTokenIsToken0)
        internal
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

    function _allow(address[] memory sources, mapping(address => bool) storage allowed) internal {
        for (uint256 i; i < sources.length; ++i) {
            address source = sources[i];
            if (source.code.length == 0) revert InvalidAddress();
            allowed[source] = true;
        }
    }
}
