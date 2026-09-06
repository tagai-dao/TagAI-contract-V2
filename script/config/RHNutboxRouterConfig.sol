// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";

/// @notice RH mainnet spot-price sources for NutboxRouter.
/// @dev Official CoinGecko Robinhood tokenized stocks; largest Uniswap V2/V3/V4 pool
///      quoted in USDG or WETH (see fetch_rh_pools.py). Hub is USDG/WETH 0.01% V3.
library RHNutboxRouterConfig {
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address internal constant RH_V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant RH_V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address internal constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    /// @dev Uniswap SwapRouter02 on RH (no deadline field). Verified by basket V3 fork tests.
    address internal constant RH_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;

    // Official tokenized stocks (CoinGecko platforms.robinhood).
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address internal constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;

    // Uniswap V3 pools (factory + pool address).
    address internal constant USDG_WETH_V3 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // 0.01%
    address internal constant NVDA_USDG_V3 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address internal constant SPCX_USDG_V3 = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029; // 0.05%
    address internal constant GME_USDG_V3 = 0x0A0675689C2Ad2a3aDe86539BCbD27B6c0764e9d; // 0.3%
    address internal constant TSLA_USDG_V3 = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3; // 0.3%
    address internal constant AMZN_USDG_V3 = 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef; // 0.3%
    address internal constant MSFT_USDG_V3 = 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510; // 0.3%
    address internal constant QQQ_USDG_V3 = 0xD60A5d14dB690B7Afad71F76B108071D7175597d; // 0.05%

    /// @dev Uniswap V4 0.3% / tickSpacing 60 / hookless. PoolId matches GeckoTerminal.
    uint24 internal constant V4_FEE_3000 = 3000;
    int24 internal constant V4_TICK_60 = 60;

    function wrappedNative() internal pure returns (address) {
        return RH_WETH;
    }

    function usdg() internal pure returns (address) {
        return RH_USDG;
    }

    function poolManager() internal pure returns (address) {
        return RH_POOL_MANAGER;
    }

    function v2Factory() internal pure returns (address) {
        return RH_V2_FACTORY;
    }

    function v2Router() internal pure returns (address) {
        return RH_V2_ROUTER;
    }

    function v3Factory() internal pure returns (address) {
        return RH_V3_FACTORY;
    }

    function v3Router() internal pure returns (address) {
        return RH_V3_ROUTER;
    }

    function initialConfig() internal pure returns (bytes memory) {
        return abi.encode(initialPricePools(), initialRoutes());
    }

    /// @dev 1 hub + 7 V3 stocks + 2 V4 stocks.
    function initialPricePools() internal pure returns (INutboxRouter.InitialPricePool[] memory pools) {
        pools = new INutboxRouter.InitialPricePool[](10);
        pools[0] = _initialV3Pool(RH_USDG, RH_WETH, USDG_WETH_V3);
        pools[1] = _initialV3Pool(NVDA, RH_USDG, NVDA_USDG_V3);
        pools[2] = _initialV3Pool(SPCX, RH_USDG, SPCX_USDG_V3);
        pools[3] = _initialV3Pool(GME, RH_USDG, GME_USDG_V3);
        pools[4] = _initialV3Pool(TSLA, RH_USDG, TSLA_USDG_V3);
        pools[5] = _initialV3Pool(AMZN, RH_USDG, AMZN_USDG_V3);
        pools[6] = _initialV3Pool(MSFT, RH_USDG, MSFT_USDG_V3);
        pools[7] = _initialV3Pool(QQQ, RH_USDG, QQQ_USDG_V3);
        pools[8] = _initialV4Pool(SPY, RH_USDG);
        pools[9] = _initialV4Pool(AAPL, RH_USDG);
    }

    /// @dev Hub + each asset→USDG (1 hop) + asset→WETH (asset pool + hub).
    function initialRoutes() internal pure returns (INutboxRouter.InitialRoute[] memory routes) {
        bytes32 hubId = _pricePoolId(RH_USDG, RH_WETH);
        address[9] memory assets = [NVDA, SPCX, GME, TSLA, AMZN, MSFT, QQQ, SPY, AAPL];
        routes = new INutboxRouter.InitialRoute[](assets.length * 2 + 1);
        routes[0] = _initialRoute(RH_USDG, RH_WETH, hubId, bytes32(0));
        for (uint256 i; i < assets.length; ++i) {
            bytes32 assetPoolId = _pricePoolId(assets[i], RH_USDG);
            uint256 idx = i * 2 + 1;
            routes[idx] = _initialRoute(assets[i], RH_USDG, assetPoolId, bytes32(0));
            routes[idx + 1] = _initialRoute(assets[i], RH_WETH, assetPoolId, hubId);
        }
    }

    function _initialV3Pool(address tokenA, address tokenB, address pool)
        private
        pure
        returns (INutboxRouter.InitialPricePool memory config)
    {
        (address token0, address token1) = uint160(tokenA) < uint160(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        config = INutboxRouter.InitialPricePool({
            token0: token0,
            token1: token1,
            sourceType: INutboxRouter.SourceType.V3_POOL,
            sourceData: abi.encode(RH_V3_FACTORY, pool)
        });
    }

    function _initialV4Pool(address tokenA, address tokenB)
        private
        pure
        returns (INutboxRouter.InitialPricePool memory config)
    {
        (address token0, address token1) = uint160(tokenA) < uint160(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: RH_POOL_MANAGER,
            currency0: token0,
            currency1: token1,
            fee: V4_FEE_3000,
            tickSpacing: V4_TICK_60,
            hooks: address(0)
        });
        config = INutboxRouter.InitialPricePool({
            token0: token0,
            token1: token1,
            sourceType: INutboxRouter.SourceType.UNISWAP_V4,
            sourceData: abi.encode(source)
        });
    }

    function _initialRoute(address tokenIn, address tokenOut, bytes32 firstPoolId, bytes32 secondPoolId)
        private
        pure
        returns (INutboxRouter.InitialRoute memory route)
    {
        uint256 length = secondPoolId == bytes32(0) ? 1 : 2;
        bytes32[] memory poolIds = new bytes32[](length);
        poolIds[0] = firstPoolId;
        if (length == 2) poolIds[1] = secondPoolId;
        route = INutboxRouter.InitialRoute({tokenIn: tokenIn, tokenOut: tokenOut, poolIds: poolIds});
    }

    function _pricePoolId(address tokenA, address tokenB) private pure returns (bytes32 poolId) {
        address normalizedA = tokenA == address(0) ? RH_WETH : tokenA;
        address normalizedB = tokenB == address(0) ? RH_WETH : tokenB;
        (address token0, address token1) =
            uint160(normalizedA) < uint160(normalizedB) ? (normalizedA, normalizedB) : (normalizedB, normalizedA);
        poolId = keccak256(abi.encode(token0, token1));
    }
}
