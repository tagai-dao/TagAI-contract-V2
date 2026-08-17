// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {BSCNutboxRouterConfig} from "../../script/config/BSCNutboxRouterConfig.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

interface IForkPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IForkPancakeV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IForkPancakeV3Pool {
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

/// @notice BSC mainnet-fork coverage for all platform-configured Nutbox price routes.
contract BSCForkNutboxRouter is Test {
    using CLPoolParametersHelper for bytes32;

    address internal constant XAUT = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;
    address internal constant XAUT_USDT_2500_POOL = 0xC655e1A100A084d9ac91C269b0A7cB0E62263fcF;
    address internal constant PANCAKE_V4_CL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    NutboxRouter internal router;
    bool internal forkReady;

    function setUp() public {
        if (block.chainid != 56) {
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        }
        if (block.chainid != 56) return;

        forkReady = true;
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = BSCNutboxRouterConfig.pancakeV3Factory();
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = BSCNutboxRouterConfig.pancakeV2Factory();
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = BSCNutboxRouterConfig.pancakeV2Router();
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = PANCAKE_V4_CL_MANAGER;
        router = new NutboxRouter(
            BSCNutboxRouterConfig.wrappedNative(),
            BSCNutboxRouterConfig.pancakeV3Router(),
            v2Routers,
            v2Factories,
            v3Factories,
            new address[](0),
            pancakeV4Managers
        );
        BSCNutboxRouterConfig.configure(router);
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function test_fork_everyConfiguredPoolIsCanonicalInitializedAndLiquid() external onlyBscFork {
        _assertLivePool(BSCNutboxRouterConfig.hubPoolConfig());

        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            BSCNutboxRouterConfig.AssetConfig memory asset = assets[i];
            assertEq(IERC20Metadata(asset.token).symbol(), asset.symbol, "unexpected asset symbol");
            assertEq(IERC20Metadata(asset.token).decimals(), asset.decimals, "unexpected asset decimals");
            _assertLivePool(asset);
        }
    }

    function test_fork_quotesEveryRequestedAssetForwardAndReverse() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();

        assertEq(router.quote(address(0), wbnb, 1 ether), 1 ether, "BNB/WBNB normalization");
        assertEq(router.quote(wbnb, address(0), 1 ether), 1 ether, "WBNB/BNB normalization");
        assertEq(router.quoteNative(address(0), 1 ether), 1 ether, "native quote normalization");
        assertEq(router.quoteNative(wbnb, 1 ether), 1 ether, "wrapped native quote normalization");

        uint256 nativePerUsdt = router.quoteNative(usdt, 1 ether);
        assertGt(nativePerUsdt, 0, "USDT native quote is zero");
        assertGt(router.quote(wbnb, usdt, 1 ether), 0, "native USDT quote is zero");
        assertEq(router.routePoolCount(usdt, wbnb), 1, "USDT route hops");
        router.validateRoute(usdt, wbnb);
        router.validateRoute(wbnb, usdt);

        bytes32 hubPoolId = _pricePoolId(BSCNutboxRouterConfig.hubPoolConfig().pool);
        assertEq(router.routePoolAt(usdt, wbnb, 0), hubPoolId, "USDT forward pool");
        assertEq(router.routePoolAt(wbnb, usdt, 0), hubPoolId, "USDT reverse pool");

        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            _assertBidirectionalQuotes(assets[i], hubPoolId);
        }
    }

    function test_fork_twoHopQuoteMatchesItsTwoLivePoolComposition() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();

        for (uint256 i; i < assets.length; ++i) {
            BSCNutboxRouterConfig.AssetConfig memory asset = assets[i];
            uint256 unit = 10 ** uint256(asset.decimals);
            if (asset.quoteToken == usdt) {
                uint256 usdtOut = router.quote(asset.token, usdt, unit);
                assertEq(
                    router.quoteNative(asset.token, unit),
                    router.quote(usdt, wbnb, usdtOut),
                    "asset/USDT/BNB composition"
                );
            } else {
                uint256 nativeOut = router.quoteNative(asset.token, unit);
                assertEq(
                    router.quote(asset.token, usdt, unit),
                    router.quote(wbnb, usdt, nativeOut),
                    "asset/BNB/USDT composition"
                );
            }
        }
    }

    function test_fork_executesCurrentTwoHopRouteThroughOfficialPancakeV3Router() external onlyBscFork {
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        address trader = makeAddr("nutboxRouterTrader");
        uint256 xautIn = 1e6;
        deal(XAUT, trader, xautIn);

        uint256 quotedNativeOut = router.quoteNative(XAUT, xautIn);
        uint256 minimumNativeOut = quotedNativeOut * 95 / 100;
        uint256 nativeBefore = trader.balance;
        vm.startPrank(trader);
        IERC20Metadata(XAUT).approve(address(router), xautIn);
        uint256 nativeOut =
            router.swapExactInput(XAUT, address(0), xautIn, minimumNativeOut, trader, block.timestamp + 60);
        vm.stopPrank();

        assertGt(nativeOut, minimumNativeOut, "two-hop XAUt/native output too low");
        assertEq(trader.balance - nativeBefore, nativeOut, "native output not delivered");
        assertEq(IERC20Metadata(XAUT).balanceOf(address(router)), 0, "router retained XAUt");
        assertEq(IERC20Metadata(wbnb).balanceOf(address(router)), 0, "router retained WBNB");
        assertEq(address(router).balance, 0, "router retained BNB");
        assertEq(router.routePoolCount(XAUT, wbnb), 2, "expected a two-hop execution route");

        uint256 nativeIn = nativeOut / 2;
        uint256 quotedXautOut = router.quote(address(0), XAUT, nativeIn);
        uint256 minimumXautOut = quotedXautOut * 95 / 100;
        uint256 xautBefore = IERC20Metadata(XAUT).balanceOf(trader);
        vm.prank(trader);
        uint256 xautOut = router.swapExactInput{value: nativeIn}(
            address(0), XAUT, nativeIn, minimumXautOut, trader, block.timestamp + 60
        );

        assertGt(xautOut, minimumXautOut, "reverse native/XAUt output too low");
        assertEq(IERC20Metadata(XAUT).balanceOf(trader) - xautBefore, xautOut, "XAUt output not delivered");
        assertEq(IERC20Metadata(XAUT).decimals(), 6, "non-18-decimal execution asset changed");
        assertEq(address(router).balance, 0, "router retained reverse-swap BNB");
    }

    function test_fork_executesBidirectionalPancakeV2RouteThroughOfficialRouter() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        address pair = IForkPancakeV2Factory(BSCNutboxRouterConfig.pancakeV2Factory()).getPair(usdt, wbnb);
        assertGt(pair.code.length, 0, "Pancake V2 pair missing");

        bytes32 poolId = router.replacePricePool(
            INutboxRouter.SourceType.V2_PAIR, abi.encode(BSCNutboxRouterConfig.pancakeV2Factory(), pair)
        );
        assertEq(poolId, router.pricePoolId(usdt, wbnb), "V2 replacement changed pair ID");

        address trader = makeAddr("nutboxV2Trader");
        uint256 usdtIn = 10 ether;
        deal(usdt, trader, usdtIn);
        uint256 minimumNativeOut = router.quote(usdt, address(0), usdtIn) * 95 / 100;
        uint256 nativeBefore = trader.balance;
        vm.startPrank(trader);
        IERC20Metadata(usdt).approve(address(router), usdtIn);
        uint256 nativeOut =
            router.swapExactInput(usdt, address(0), usdtIn, minimumNativeOut, trader, block.timestamp + 60);
        vm.stopPrank();

        assertGt(nativeOut, minimumNativeOut, "V2 USDT/native output too low");
        assertEq(trader.balance - nativeBefore, nativeOut, "V2 native output not delivered");

        uint256 nativeIn = nativeOut / 2;
        uint256 minimumUsdtOut = router.quote(address(0), usdt, nativeIn) * 95 / 100;
        uint256 usdtBefore = IERC20Metadata(usdt).balanceOf(trader);
        vm.prank(trader);
        uint256 usdtOut = router.swapExactInput{value: nativeIn}(
            address(0), usdt, nativeIn, minimumUsdtOut, trader, block.timestamp + 60
        );
        assertGt(usdtOut, minimumUsdtOut, "V2 native/USDT output too low");
        assertEq(IERC20Metadata(usdt).balanceOf(trader) - usdtBefore, usdtOut, "V2 USDT output not delivered");
        _assertRouterEmpty(usdt, wbnb);
    }

    function test_fork_executesBidirectionalPancakeV4NativeRouteThroughVaultCallback() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        INutboxRouter.PancakeV4CLSource memory source = INutboxRouter.PancakeV4CLSource({
            currency0: address(0),
            currency1: usdt,
            hooks: address(0),
            poolManager: PANCAKE_V4_CL_MANAGER,
            fee: 67,
            parameters: bytes32(0).setTickSpacing(1)
        });
        bytes32 poolId = router.replacePricePool(INutboxRouter.SourceType.PANCAKE_V4_CL, abi.encode(source));
        assertEq(poolId, router.pricePoolId(usdt, wbnb), "V4 replacement changed pair ID");

        address trader = makeAddr("nutboxV4Trader");
        uint256 usdtIn = 10 ether;
        deal(usdt, trader, usdtIn);
        uint256 minimumNativeOut = router.quote(usdt, address(0), usdtIn) * 95 / 100;
        uint256 nativeBefore = trader.balance;
        vm.startPrank(trader);
        IERC20Metadata(usdt).approve(address(router), usdtIn);
        uint256 nativeOut =
            router.swapExactInput(usdt, address(0), usdtIn, minimumNativeOut, trader, block.timestamp + 60);
        vm.stopPrank();

        assertGt(nativeOut, minimumNativeOut, "V4 USDT/native output too low");
        assertEq(trader.balance - nativeBefore, nativeOut, "V4 native output not delivered");

        uint256 nativeIn = nativeOut / 2;
        uint256 minimumUsdtOut = router.quote(address(0), usdt, nativeIn) * 95 / 100;
        uint256 usdtBefore = IERC20Metadata(usdt).balanceOf(trader);
        vm.prank(trader);
        uint256 usdtOut = router.swapExactInput{value: nativeIn}(
            address(0), usdt, nativeIn, minimumUsdtOut, trader, block.timestamp + 60
        );
        assertGt(usdtOut, minimumUsdtOut, "V4 native/USDT output too low");
        assertEq(IERC20Metadata(usdt).balanceOf(trader) - usdtBefore, usdtOut, "V4 USDT output not delivered");
        _assertRouterEmpty(usdt, wbnb);
    }

    function test_fork_ownerReplacesXautPoolWithoutChangingEitherRoute() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        bytes32 stablePoolId = _pricePoolId(_configuredPool(XAUT));
        uint256 oldNativeQuote = router.quoteNative(XAUT, 1e6);

        bytes32 replacementPoolId = router.replacePricePool(
            INutboxRouter.SourceType.V3_POOL, abi.encode(BSCNutboxRouterConfig.pancakeV3Factory(), XAUT_USDT_2500_POOL)
        );
        assertEq(replacementPoolId, stablePoolId, "replacement changed XAUt/USDT pair ID");
        assertEq(router.routePoolAt(XAUT, usdt, 0), stablePoolId, "direct route changed");
        assertEq(router.routePoolAt(XAUT, wbnb, 0), stablePoolId, "two-hop route changed");

        assertGt(router.quote(XAUT, usdt, 1e6), 0, "replacement direct quote");
        assertGt(router.quote(usdt, XAUT, 1 ether), 0, "replacement reverse direct quote");
        assertGt(router.quoteNative(XAUT, 1e6), 0, "replacement native quote");
        assertGt(router.quote(wbnb, XAUT, 1 ether), 0, "replacement reverse native quote");
        assertNotEq(router.quoteNative(XAUT, 1e6), oldNativeQuote, "pool replacement had no effect");

        (
            bool enabled,
            uint32 references,
            address storedToken0,
            address storedToken1,
            INutboxRouter.SourceType storedSourceType,
            bytes memory sourceData
        ) = router.pricePool(stablePoolId);
        assertTrue(enabled, "stable pair slot unexpectedly removed");
        assertEq(references, 2, "route references changed during pool replacement");
        assertTrue(
            (storedToken0 == XAUT && storedToken1 == usdt) || (storedToken0 == usdt && storedToken1 == XAUT),
            "replacement pair endpoints changed"
        );
        assertEq(uint8(storedSourceType), uint8(INutboxRouter.SourceType.V3_POOL));
        assertEq(
            sourceData,
            abi.encode(BSCNutboxRouterConfig.pancakeV3Factory(), XAUT_USDT_2500_POOL),
            "replacement source not stored"
        );
        vm.expectRevert(NutboxRouter.PricePoolInUse.selector);
        router.removePricePool(stablePoolId);
    }

    function _assertBidirectionalQuotes(BSCNutboxRouterConfig.AssetConfig memory asset, bytes32 hubPoolId)
        internal
        view
    {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        uint256 unit = 10 ** uint256(asset.decimals);

        uint256 nativeOut = router.quoteNative(asset.token, unit);
        uint256 usdtOut = router.quote(asset.token, usdt, unit);
        assertGt(nativeOut, 0, "asset native quote is zero");
        assertGt(router.quote(wbnb, asset.token, 1 ether), 0, "native asset quote is zero");
        assertGt(usdtOut, 0.01 ether, "asset USDT quote is implausibly low");
        assertLt(usdtOut, 1_000_000 ether, "asset USDT quote is implausibly high");
        assertGt(router.quote(usdt, asset.token, 1 ether), 0, "USDT asset quote is zero");
        assertApproxEqRel(router.quote(wbnb, asset.token, nativeOut), unit, 0.01 ether, "native round trip");
        assertApproxEqRel(router.quote(usdt, asset.token, usdtOut), unit, 0.01 ether, "USDT round trip");
        router.validateRoute(asset.token, wbnb);
        router.validateRoute(wbnb, asset.token);
        router.validateRoute(asset.token, usdt);
        router.validateRoute(usdt, asset.token);

        bytes32 assetPoolId = _pricePoolId(asset.pool);
        if (asset.quoteToken == usdt) {
            assertEq(router.routePoolCount(asset.token, usdt), 1, "asset USDT route hops");
            assertEq(router.routePoolCount(asset.token, wbnb), 2, "asset native route hops");
            assertEq(router.routePoolAt(asset.token, wbnb, 0), assetPoolId, "asset native first pool");
            assertEq(router.routePoolAt(asset.token, wbnb, 1), hubPoolId, "asset native second pool");
            assertEq(router.routePoolAt(wbnb, asset.token, 0), hubPoolId, "native asset first pool");
            assertEq(router.routePoolAt(wbnb, asset.token, 1), assetPoolId, "native asset second pool");
        } else {
            assertEq(router.routePoolCount(asset.token, wbnb), 1, "asset native route hops");
            assertEq(router.routePoolCount(asset.token, usdt), 2, "asset USDT route hops");
            assertEq(router.routePoolAt(asset.token, usdt, 0), assetPoolId, "asset USDT first pool");
            assertEq(router.routePoolAt(asset.token, usdt, 1), hubPoolId, "asset USDT second pool");
            assertEq(router.routePoolAt(usdt, asset.token, 0), hubPoolId, "USDT asset first pool");
            assertEq(router.routePoolAt(usdt, asset.token, 1), assetPoolId, "USDT asset second pool");
        }
    }

    function _assertLivePool(BSCNutboxRouterConfig.AssetConfig memory config) internal view {
        address factory = BSCNutboxRouterConfig.pancakeV3Factory();
        IForkPancakeV3Pool pool = IForkPancakeV3Pool(config.pool);

        assertGt(config.pool.code.length, 0, "pool code missing");
        assertEq(pool.factory(), factory, "unexpected pool factory");
        assertEq(pool.fee(), config.fee, "unexpected pool fee");
        assertEq(
            IForkPancakeV3Factory(factory).getPool(config.token, config.quoteToken, config.fee),
            config.pool,
            "not canonical Pancake V3 pool"
        );
        assertTrue(
            (pool.token0() == config.token && pool.token1() == config.quoteToken)
                || (pool.token0() == config.quoteToken && pool.token1() == config.token),
            "unexpected pool tokens"
        );
        (uint160 sqrtPriceX96,,,,,, bool unlocked) = pool.slot0();
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertGt(pool.liquidity(), 0, "pool has no active liquidity");
        assertTrue(unlocked, "pool is locked");
    }

    function _configuredPool(address token) internal pure returns (address pool) {
        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i].token == token) return assets[i].pool;
        }
        revert("configured asset not found");
    }

    function _pricePoolId(address pool) internal view returns (bytes32) {
        IForkPancakeV3Pool v3Pool = IForkPancakeV3Pool(pool);
        return router.pricePoolId(v3Pool.token0(), v3Pool.token1());
    }

    function _assertRouterEmpty(address token, address wbnb) internal view {
        assertEq(IERC20Metadata(token).balanceOf(address(router)), 0, "router retained token");
        assertEq(IERC20Metadata(wbnb).balanceOf(address(router)), 0, "router retained WBNB");
        assertEq(address(router).balance, 0, "router retained BNB");
    }
}
