// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {BSCNutboxRouterConfig} from "../../script/config/BSCNutboxRouterConfig.sol";

interface IDeployedRouterV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IDeployedRouterV3Pool {
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

/// @notice Post-deployment BSC fork checks for the shared production NutboxRouter.
/// @dev These tests never impersonate the owner or mutate the Router registry.
contract BSCForkDeployedNutboxRouter is Test {
    address internal constant DEPLOYED_ROUTER = 0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f;
    address internal constant DEPLOYER = 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611;
    address internal constant TARGET_OWNER = 0x871fb7006C5964B21695Ba20006021777A26146C;
    address internal constant PANCAKE_V4_CL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant PANCAKE_V4_VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant XAUT = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    NutboxRouter internal router;
    bool internal forkReady;

    function setUp() public {
        if (block.chainid != 56) {
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        }
        if (block.chainid != 56 || DEPLOYED_ROUTER.code.length == 0) return;

        forkReady = true;
        router = NutboxRouter(payable(DEPLOYED_ROUTER));
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function test_fork_deployedDependenciesAndOwnershipAreCorrect() external onlyBscFork {
        assertEq(router.wrappedNative(), BSCNutboxRouterConfig.wrappedNative(), "WBNB mismatch");
        assertEq(router.pancakeV3Router(), BSCNutboxRouterConfig.pancakeV3Router(), "V3 router mismatch");
        assertEq(router.pancakeV3Factory(), BSCNutboxRouterConfig.pancakeV3Factory(), "V3 factory mismatch");
        assertTrue(router.allowedV2Factory(BSCNutboxRouterConfig.pancakeV2Factory()), "V2 factory missing");
        assertEq(
            router.v2RouterForFactory(BSCNutboxRouterConfig.pancakeV2Factory()),
            BSCNutboxRouterConfig.pancakeV2Router(),
            "V2 router mismatch"
        );
        assertTrue(router.allowedV3Factory(BSCNutboxRouterConfig.pancakeV3Factory()), "V3 factory not allowed");
        assertTrue(router.allowedPancakeV4CLManager(PANCAKE_V4_CL_MANAGER), "V4 manager missing");
        assertTrue(router.allowedPancakeV4Vault(PANCAKE_V4_VAULT), "V4 Vault missing");

        bool ownershipPending = router.owner() == DEPLOYER && router.pendingOwner() == TARGET_OWNER;
        bool ownershipAccepted = router.owner() == TARGET_OWNER && router.pendingOwner() == address(0);
        assertTrue(ownershipPending || ownershipAccepted, "unexpected ownership state");
    }

    function test_fork_deployedPoolsRoutesAndQuotesMatchOfficialConfiguration() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        BSCNutboxRouterConfig.AssetConfig memory hub = BSCNutboxRouterConfig.hubPoolConfig();
        bytes32 hubPoolId = _assertStoredPool(hub, 15);

        assertEq(router.routePoolCount(usdt, wbnb), 1, "hub route length");
        assertEq(router.routePoolAt(usdt, wbnb, 0), hubPoolId, "hub route pool");
        assertEq(router.routePoolAt(wbnb, usdt, 0), hubPoolId, "reverse hub route pool");
        router.validateRoute(usdt, wbnb);
        router.validateRoute(wbnb, usdt);
        assertGt(router.quote(usdt, wbnb, 1 ether), 0, "USDT/WBNB quote");
        assertGt(router.quote(wbnb, usdt, 1 ether), 0, "WBNB/USDT quote");

        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        assertEq(assets.length, 14, "asset config count");
        for (uint256 i; i < assets.length; ++i) {
            _assertStoredAsset(assets[i], hubPoolId, usdt, wbnb);
        }
    }

    function test_fork_deployedRouterExecutesTwoHopV3SwapBothDirectionsWithoutResidue() external onlyBscFork {
        address usdt = BSCNutboxRouterConfig.settlementToken();
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        address trader = makeAddr("deployedNutboxRouterTrader");
        uint256 xautIn = 1e6;

        uint256 routerXautBefore = IERC20(XAUT).balanceOf(DEPLOYED_ROUTER);
        uint256 routerUsdtBefore = IERC20(usdt).balanceOf(DEPLOYED_ROUTER);
        uint256 routerWbnbBefore = IERC20(wbnb).balanceOf(DEPLOYED_ROUTER);
        uint256 routerNativeBefore = DEPLOYED_ROUTER.balance;

        deal(XAUT, trader, xautIn);
        uint256 quotedNativeOut = router.quoteNative(XAUT, xautIn);
        uint256 minimumNativeOut = quotedNativeOut * 95 / 100;
        uint256 nativeBefore = trader.balance;

        vm.startPrank(trader);
        IERC20(XAUT).approve(DEPLOYED_ROUTER, xautIn);
        uint256 nativeOut =
            router.swapExactInput(XAUT, address(0), xautIn, minimumNativeOut, trader, block.timestamp + 60);
        vm.stopPrank();

        assertGe(nativeOut, minimumNativeOut, "XAUt/BNB output below minimum");
        assertEq(trader.balance - nativeBefore, nativeOut, "BNB not delivered");
        assertEq(router.routePoolCount(XAUT, wbnb), 2, "XAUt/BNB route is not two-hop");

        uint256 nativeIn = nativeOut / 2;
        uint256 quotedXautOut = router.quote(address(0), XAUT, nativeIn);
        uint256 minimumXautOut = quotedXautOut * 95 / 100;
        uint256 xautBefore = IERC20(XAUT).balanceOf(trader);
        vm.prank(trader);
        uint256 xautOut = router.swapExactInput{value: nativeIn}(
            address(0), XAUT, nativeIn, minimumXautOut, trader, block.timestamp + 60
        );

        assertGe(xautOut, minimumXautOut, "BNB/XAUt output below minimum");
        assertEq(IERC20(XAUT).balanceOf(trader) - xautBefore, xautOut, "XAUt not delivered");
        assertEq(IERC20(XAUT).balanceOf(DEPLOYED_ROUTER), routerXautBefore, "Router retained XAUt");
        assertEq(IERC20(usdt).balanceOf(DEPLOYED_ROUTER), routerUsdtBefore, "Router retained USDT");
        assertEq(IERC20(wbnb).balanceOf(DEPLOYED_ROUTER), routerWbnbBefore, "Router retained WBNB");
        assertEq(DEPLOYED_ROUTER.balance, routerNativeBefore, "Router retained BNB");
    }

    function _assertStoredAsset(
        BSCNutboxRouterConfig.AssetConfig memory asset,
        bytes32 hubPoolId,
        address usdt,
        address wbnb
    ) internal view {
        bytes32 assetPoolId = _assertStoredPool(asset, 2);
        address crossToken = asset.quoteToken == usdt ? wbnb : usdt;

        assertEq(router.routePoolCount(asset.token, asset.quoteToken), 1, "direct route length");
        assertEq(router.routePoolAt(asset.token, asset.quoteToken, 0), assetPoolId, "direct route pool");
        assertEq(router.routePoolCount(asset.token, crossToken), 2, "cross route length");
        assertEq(router.routePoolAt(asset.token, crossToken, 0), assetPoolId, "cross asset pool");
        assertEq(router.routePoolAt(asset.token, crossToken, 1), hubPoolId, "cross hub pool");
        assertEq(router.routePoolAt(crossToken, asset.token, 0), hubPoolId, "reverse hub pool");
        assertEq(router.routePoolAt(crossToken, asset.token, 1), assetPoolId, "reverse asset pool");

        router.validateRoute(asset.token, asset.quoteToken);
        router.validateRoute(asset.quoteToken, asset.token);
        router.validateRoute(asset.token, crossToken);
        router.validateRoute(crossToken, asset.token);

        uint256 unit = 10 ** uint256(asset.decimals);
        uint256 quoteOut = router.quote(asset.token, asset.quoteToken, unit);
        uint256 crossOut = router.quote(asset.token, crossToken, unit);
        assertGt(quoteOut, 0, "direct quote is zero");
        assertGt(crossOut, 0, "cross quote is zero");
        assertGt(router.quote(asset.quoteToken, asset.token, 1 ether), 0, "reverse direct quote is zero");
        assertGt(router.quote(crossToken, asset.token, 1 ether), 0, "reverse cross quote is zero");
    }

    function _assertStoredPool(BSCNutboxRouterConfig.AssetConfig memory config, uint32 expectedReferences)
        internal
        view
        returns (bytes32 poolId)
    {
        poolId = router.pricePoolId(config.token, config.quoteToken);
        (
            bool enabled,
            uint32 routeReferences,
            address token0,
            address token1,
            INutboxRouter.SourceType sourceType,
            bytes memory sourceData
        ) = router.pricePool(poolId);
        (address expectedToken0, address expectedToken1) = uint160(config.token) < uint160(config.quoteToken)
            ? (config.token, config.quoteToken)
            : (config.quoteToken, config.token);

        assertTrue(enabled, "stored pool disabled");
        assertEq(routeReferences, expectedReferences, "route reference count");
        assertEq(token0, expectedToken0, "stored token0");
        assertEq(token1, expectedToken1, "stored token1");
        assertEq(uint8(sourceType), uint8(INutboxRouter.SourceType.V3_POOL), "stored source type");
        assertEq(sourceData, abi.encode(BSCNutboxRouterConfig.pancakeV3Factory(), config.pool), "stored source data");

        _assertLiveV3Pool(config);
    }

    function _assertLiveV3Pool(BSCNutboxRouterConfig.AssetConfig memory config) internal view {
        address factory = BSCNutboxRouterConfig.pancakeV3Factory();
        IDeployedRouterV3Pool pool = IDeployedRouterV3Pool(config.pool);

        assertGt(config.pool.code.length, 0, "V3 pool code missing");
        assertEq(pool.factory(), factory, "V3 pool factory");
        assertEq(pool.fee(), config.fee, "V3 pool fee");
        assertEq(
            IDeployedRouterV3Factory(factory).getPool(config.token, config.quoteToken, config.fee),
            config.pool,
            "non-canonical V3 pool"
        );
        assertTrue(
            (pool.token0() == config.token && pool.token1() == config.quoteToken)
                || (pool.token0() == config.quoteToken && pool.token1() == config.token),
            "V3 pool endpoints"
        );
        (uint160 sqrtPriceX96,,,,,, bool unlocked) = pool.slot0();
        assertGt(sqrtPriceX96, 0, "V3 pool uninitialized");
        assertGt(pool.liquidity(), 0, "V3 pool has no liquidity");
        assertTrue(unlocked, "V3 pool locked");
    }
}
