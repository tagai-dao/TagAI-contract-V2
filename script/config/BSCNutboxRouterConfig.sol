// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";

/// @notice Canonical BSC mainnet spot-price sources used by the shared Nutbox router.
/// @dev Every configured pool is a live PancakeSwap V3 pool. Stock and gold assets use
///      their primary USDT pool, while ETH and BTCB use their deeper direct WBNB pools.
library BSCNutboxRouterConfig {
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address internal constant USDT_WBNB_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    uint24 internal constant USDT_WBNB_FEE = 100;

    struct AssetConfig {
        string symbol;
        address token;
        uint8 decimals;
        address quoteToken;
        uint24 fee;
        address pool;
    }

    function initialConfig() internal pure returns (bytes memory) {
        return abi.encode(initialPricePools(), initialRoutes());
    }

    function initialPricePools() internal pure returns (INutboxRouter.InitialPricePool[] memory pools) {
        AssetConfig[] memory assets = assetConfigs();
        pools = new INutboxRouter.InitialPricePool[](assets.length + 1);
        AssetConfig memory hub = hubPoolConfig();
        pools[0] = _initialV3Pool(hub.token, hub.quoteToken, hub.pool);
        for (uint256 i; i < assets.length; ++i) {
            pools[i + 1] = _initialV3Pool(assets[i].token, assets[i].quoteToken, assets[i].pool);
        }
    }

    function initialRoutes() internal pure returns (INutboxRouter.InitialRoute[] memory routes) {
        AssetConfig[] memory assets = assetConfigs();
        routes = new INutboxRouter.InitialRoute[](assets.length * 2 + 1);
        bytes32 hubPoolId = _pricePoolId(USDT, WBNB);
        routes[0] = _initialRoute(USDT, WBNB, hubPoolId, bytes32(0));

        for (uint256 i; i < assets.length; ++i) {
            AssetConfig memory asset = assets[i];
            bytes32 assetPoolId = _pricePoolId(asset.token, asset.quoteToken);
            uint256 routeIndex = i * 2 + 1;

            if (asset.quoteToken == USDT) {
                routes[routeIndex] = _initialRoute(asset.token, USDT, assetPoolId, bytes32(0));
                routes[routeIndex + 1] = _initialRoute(asset.token, WBNB, assetPoolId, hubPoolId);
            } else {
                routes[routeIndex] = _initialRoute(asset.token, WBNB, assetPoolId, bytes32(0));
                routes[routeIndex + 1] = _initialRoute(asset.token, USDT, assetPoolId, hubPoolId);
            }
        }
    }

    function pancakeV3Factory() internal pure returns (address) {
        return PANCAKE_V3_FACTORY;
    }

    function pancakeV2Factory() internal pure returns (address) {
        return PANCAKE_V2_FACTORY;
    }

    function pancakeV2Router() internal pure returns (address) {
        return PANCAKE_V2_ROUTER;
    }

    function pancakeV3Router() internal pure returns (address) {
        return PANCAKE_V3_ROUTER;
    }

    function settlementToken() internal pure returns (address) {
        return USDT;
    }

    function wrappedNative() internal pure returns (address) {
        return WBNB;
    }

    function hubPoolConfig() internal pure returns (AssetConfig memory config) {
        config = AssetConfig({
            symbol: "USDT", token: USDT, decimals: 18, quoteToken: WBNB, fee: USDT_WBNB_FEE, pool: USDT_WBNB_POOL
        });
    }

    function assetConfigs() internal pure returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](14);
        assets[0] = AssetConfig({
            symbol: "ETH",
            token: 0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
            decimals: 18,
            quoteToken: WBNB,
            fee: 500,
            pool: 0xD0e226f674bBf064f54aB47F42473fF80DB98CBA
        });
        assets[1] = AssetConfig({
            symbol: "BTCB",
            token: 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
            decimals: 18,
            quoteToken: WBNB,
            fee: 500,
            pool: 0x6bbc40579ad1BBD243895cA0ACB086BB6300d636
        });
        assets[2] = AssetConfig({
            symbol: "QQQB",
            token: 0x205812CdBed920aFf76C6580abD681a46D11efc7,
            decimals: 18,
            quoteToken: USDT,
            fee: 100,
            pool: 0xe531fcb1F5a195de7608B9F4f9518544C2cdB693
        });
        assets[3] = AssetConfig({
            symbol: "SPCXB",
            token: 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0x977DaFFC095b33872E2741c19568925015C35b4d
        });
        assets[4] = AssetConfig({
            symbol: "AAPLB",
            token: 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365
        });
        assets[5] = AssetConfig({
            symbol: "SKHYB",
            token: 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0xD7d30F434b12F7Ed9b0Ae11fF1C754745a10aD52
        });
        assets[6] = AssetConfig({
            symbol: "SPYB",
            token: 0x7138b48df7D98D7e3cc221BfE7192D0a178182D8,
            decimals: 18,
            quoteToken: USDT,
            fee: 100,
            pool: 0x7aA6d92Fc369A8C1EDc631A3aAc44eFB0808ddbF
        });
        assets[7] = AssetConfig({
            symbol: "XAUt",
            token: 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf,
            decimals: 6,
            quoteToken: USDT,
            fee: 500,
            pool: 0x83A0A8A723262651Ae9C54BBbA929F167443bC59
        });
        assets[8] = AssetConfig({
            symbol: "NVDAB",
            token: 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C
        });
        assets[9] = AssetConfig({
            symbol: "TSLAB",
            token: 0x5b1910eAaD6450E50f816082Aa078C41F10C292f,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0xB0f5E5400E8F0F7C242F2b7740C004f020579c41
        });
        assets[10] = AssetConfig({
            symbol: "MSFTB",
            token: 0x80106cb3EAD06659A5ad19DF39D9b4733863B9b0,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0x5018b018cEB7645c927c5Cf246786F89ebCbe7Ea
        });
        assets[11] = AssetConfig({
            symbol: "HOODB",
            token: 0xA394dCEa3fd3847fD793afBFd163E2e3858B7c65,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0xFEeF70FF6F58f0A900e28A77e5A8945aFB343923
        });
        assets[12] = AssetConfig({
            symbol: "BABAB",
            token: 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0xfD95CB1391999006Eb91797a7c62acFe88b20292
        });
        assets[13] = AssetConfig({
            symbol: "GMEB",
            token: 0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C,
            decimals: 18,
            quoteToken: USDT,
            fee: 2_500,
            pool: 0x908d49048EB3a7bEdfd238972403842805EAF2bE
        });
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
            sourceData: abi.encode(PANCAKE_V3_FACTORY, pool)
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
        address normalizedA = tokenA == address(0) ? WBNB : tokenA;
        address normalizedB = tokenB == address(0) ? WBNB : tokenB;
        (address token0, address token1) =
            uint160(normalizedA) < uint160(normalizedB) ? (normalizedA, normalizedB) : (normalizedB, normalizedA);
        poolId = keccak256(abi.encode(token0, token1));
    }
}
