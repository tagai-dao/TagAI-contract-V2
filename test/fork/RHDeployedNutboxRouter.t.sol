// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {TagAISwapWrapper} from "../../src/helper/TagAISwapWrapper.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {RHNutboxRouterConfig} from "../../script/config/RHNutboxRouterConfig.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Post-deployment gate for the live RH v11 NutboxRouter and Wrapper binding.
contract RHDeployedNutboxRouterForkTest is Test {
    uint256 private constant RH_CHAIN_ID = 4_663;
    address private constant DEFAULT_ROUTER = 0x200115D733106ecA3954EAA5d1fCbc6D0EfB78AE;
    address private constant WRAPPER = 0x91ddcaEeF99d674cddFffd1C1a204C5Be8291a92;
    address private constant SAFE = 0x871fb7006C5964B21695Ba20006021777A26146C;

    NutboxRouter private router;

    function setUp() public {
        if (block.chainid != RH_CHAIN_ID) {
            vm.skip(true, "requires RH mainnet fork");
            return;
        }
        address deployedRouter = vm.envOr("RH_DEPLOYED_NUTBOX_ROUTER", DEFAULT_ROUTER);
        assertGt(deployedRouter.code.length, 0, "deployed Router missing");
        router = NutboxRouter(payable(deployedRouter));
    }

    function testFork_liveDependenciesAndOwnershipHandoff() external view {
        if (block.chainid != RH_CHAIN_ID) return;

        assertEq(router.wrappedNative(), RHNutboxRouterConfig.wrappedNative());
        assertEq(router.pancakeV3Router(), RHNutboxRouterConfig.v3Router());
        assertEq(router.pancakeV3Factory(), RHNutboxRouterConfig.v3Factory());
        assertEq(router.v2RouterForFactory(RHNutboxRouterConfig.v2Factory()), RHNutboxRouterConfig.v2Router());
        assertTrue(router.allowedV2Factory(RHNutboxRouterConfig.v2Factory()));
        assertTrue(router.allowedV3Factory(RHNutboxRouterConfig.v3Factory()));
        assertTrue(router.allowedUniswapV4Manager(RHNutboxRouterConfig.poolManager()));
        assertFalse(router.allowedPancakeV4CLManager(RHNutboxRouterConfig.poolManager()));

        // Post-governance state: both Router and Wrapper are controlled by the Safe.
        assertEq(router.owner(), SAFE);
        assertEq(router.pendingOwner(), address(0));
        TagAISwapWrapper wrapper = TagAISwapWrapper(payable(WRAPPER));
        assertEq(address(wrapper.nutboxRouter()), address(router));
        assertEq(wrapper.owner(), SAFE);
    }

    function testFork_allTenLivePricePoolsMatchReleaseConfig() external view {
        if (block.chainid != RH_CHAIN_ID) return;
        INutboxRouter.InitialPricePool[] memory pools = RHNutboxRouterConfig.initialPricePools();
        assertEq(pools.length, 10);

        for (uint256 i; i < pools.length; ++i) {
            bytes32 poolId = router.pricePoolId(pools[i].token0, pools[i].token1);
            assertTrue(router.hasPricePool(poolId), "live price pool missing");
            (
                bool enabled,,
                address token0,
                address token1,
                INutboxRouter.SourceType sourceType,
                bytes memory sourceData
            ) = router.pricePool(poolId);
            assertTrue(enabled);
            assertEq(token0, pools[i].token0);
            assertEq(token1, pools[i].token1);
            assertEq(uint8(sourceType), uint8(pools[i].sourceType));
            assertEq(keccak256(sourceData), keccak256(pools[i].sourceData));
        }
    }

    function testFork_allNineteenLiveRoutesQuoteBothDirections() external view {
        if (block.chainid != RH_CHAIN_ID) return;
        INutboxRouter.InitialRoute[] memory routes = RHNutboxRouterConfig.initialRoutes();
        assertEq(routes.length, 19);

        for (uint256 i; i < routes.length; ++i) {
            address tokenIn = routes[i].tokenIn;
            address tokenOut = routes[i].tokenOut;
            uint256 poolCount = routes[i].poolIds.length;

            assertTrue(router.hasRoute(tokenIn, tokenOut), "forward live route missing");
            assertTrue(router.hasRoute(tokenOut, tokenIn), "reverse live route missing");
            assertEq(router.routePoolCount(tokenIn, tokenOut), poolCount);
            assertEq(router.routePoolCount(tokenOut, tokenIn), poolCount);
            for (uint256 j; j < poolCount; ++j) {
                assertEq(router.routePoolAt(tokenIn, tokenOut, j), routes[i].poolIds[j]);
                assertEq(router.routePoolAt(tokenOut, tokenIn, j), routes[i].poolIds[poolCount - 1 - j]);
            }

            router.validateRoute(tokenIn, tokenOut);
            router.validateRoute(tokenOut, tokenIn);
            uint256 forwardIn = 10 ** IERC20Decimals(tokenIn).decimals();
            uint256 reverseIn = 10 ** IERC20Decimals(tokenOut).decimals();
            assertGt(router.quote(tokenIn, tokenOut, forwardIn), 0, "forward live quote unavailable");
            assertGt(router.quote(tokenOut, tokenIn, reverseIn), 0, "reverse live quote unavailable");
        }
    }
}
