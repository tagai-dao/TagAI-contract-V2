// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {RHNutboxRouterConfig} from "../../script/config/RHNutboxRouterConfig.sol";

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}

/// @notice Pre-deployment RH mainnet gate for every immutable NutboxRouter pool and route.
/// @dev Run with FOUNDRY_PROFILE=rh_fork. A stale/empty pool or ABI-incompatible router fails deployment.
contract RHNutboxRouterConfigForkTest is Test {
    uint256 private constant RH_CHAIN_ID = 4_663;

    NutboxRouter private router;

    function setUp() public {
        if (block.chainid != RH_CHAIN_ID) {
            vm.skip(true, "requires RH mainnet fork");
            return;
        }

        address[] memory v2Routers = new address[](1);
        v2Routers[0] = RHNutboxRouterConfig.v2Router();
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = RHNutboxRouterConfig.v2Factory();
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = RHNutboxRouterConfig.v3Factory();
        address[] memory v4Managers = new address[](1);
        v4Managers[0] = RHNutboxRouterConfig.poolManager();

        router = new NutboxRouter(
            RHNutboxRouterConfig.wrappedNative(),
            RHNutboxRouterConfig.v3Router(),
            v2Routers,
            v2Factories,
            v3Factories,
            v4Managers,
            new address[](0),
            RHNutboxRouterConfig.initialConfig()
        );
    }

    function testFork_allRuntimeDependenciesHaveCodeAndExpectedAllowlist() public view {
        if (block.chainid != RH_CHAIN_ID) return;
        assertGt(RHNutboxRouterConfig.wrappedNative().code.length, 0, "WETH missing");
        assertGt(RHNutboxRouterConfig.usdg().code.length, 0, "USDG missing");
        assertGt(RHNutboxRouterConfig.poolManager().code.length, 0, "V4 manager missing");
        assertGt(RHNutboxRouterConfig.v2Factory().code.length, 0, "V2 factory missing");
        assertGt(RHNutboxRouterConfig.v2Router().code.length, 0, "V2 router missing");
        assertGt(RHNutboxRouterConfig.v3Factory().code.length, 0, "V3 factory missing");
        assertGt(RHNutboxRouterConfig.v3Router().code.length, 0, "V3 router missing");

        assertEq(router.wrappedNative(), RHNutboxRouterConfig.wrappedNative());
        assertEq(router.v2RouterForFactory(RHNutboxRouterConfig.v2Factory()), RHNutboxRouterConfig.v2Router());
        assertTrue(router.allowedV2Factory(RHNutboxRouterConfig.v2Factory()));
        assertTrue(router.allowedV3Factory(RHNutboxRouterConfig.v3Factory()));
        assertTrue(router.allowedUniswapV4Manager(RHNutboxRouterConfig.poolManager()));
        assertFalse(router.allowedPancakeV4CLManager(RHNutboxRouterConfig.poolManager()));
    }

    function testFork_everyOfficialDirectAndBridgedRouteQuotesBothDirections() public view {
        if (block.chainid != RH_CHAIN_ID) return;
        INutboxRouter.InitialRoute[] memory routes = RHNutboxRouterConfig.initialRoutes();
        for (uint256 i; i < routes.length; ++i) {
            address tokenIn = routes[i].tokenIn;
            address tokenOut = routes[i].tokenOut;
            router.validateRoute(tokenIn, tokenOut);

            uint256 forwardIn = 10 ** IERC20MetadataLike(tokenIn).decimals();
            uint256 reverseIn = 10 ** IERC20MetadataLike(tokenOut).decimals();
            assertGt(router.quote(tokenIn, tokenOut, forwardIn), 0, "forward quote unavailable");
            assertGt(router.quote(tokenOut, tokenIn, reverseIn), 0, "reverse quote unavailable");
        }
    }
}
