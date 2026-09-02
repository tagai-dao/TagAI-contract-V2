// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {RHNutboxRouterConfig} from "../../script/config/RHNutboxRouterConfig.sol";

/// @notice Deployment gate for the immutable RH v11 NutboxRouter bootstrap matrix.
/// @dev These tests intentionally assert every configured pool and every direct/bridged route.
contract RHNutboxRouterConfigTest is Test {
    function test_allConfiguredPoolTypesAndDependenciesArePinned() public pure {
        assertEq(RHNutboxRouterConfig.wrappedNative(), 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
        assertEq(RHNutboxRouterConfig.usdg(), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
        assertEq(RHNutboxRouterConfig.poolManager(), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(RHNutboxRouterConfig.v2Factory(), 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f);
        assertEq(RHNutboxRouterConfig.v2Router(), 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba);
        assertEq(RHNutboxRouterConfig.v3Factory(), 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
        assertEq(RHNutboxRouterConfig.v3Router(), 0xCaf681a66D020601342297493863E78C959E5cb2);

        INutboxRouter.InitialPricePool[] memory pools = RHNutboxRouterConfig.initialPricePools();
        assertEq(pools.length, 10, "1 hub + 7 V3 stocks + 2 V4 stocks");

        for (uint256 i; i < pools.length; ++i) {
            assertTrue(pools[i].token0 < pools[i].token1, "pool currencies must be canonical");
            assertTrue(pools[i].token0 != address(0) && pools[i].token1 != address(0), "no native pool source");
            if (i < 8) {
                assertEq(uint8(pools[i].sourceType), uint8(INutboxRouter.SourceType.V3_POOL));
                (address factory, address pool) = abi.decode(pools[i].sourceData, (address, address));
                assertEq(factory, RHNutboxRouterConfig.v3Factory());
                assertTrue(pool != address(0), "V3 pool missing");
            } else {
                assertEq(uint8(pools[i].sourceType), uint8(INutboxRouter.SourceType.UNISWAP_V4));
                INutboxRouter.UniswapV4Source memory source =
                    abi.decode(pools[i].sourceData, (INutboxRouter.UniswapV4Source));
                assertEq(source.poolManager, RHNutboxRouterConfig.poolManager());
                assertEq(source.currency0, pools[i].token0);
                assertEq(source.currency1, pools[i].token1);
                assertEq(source.fee, 3_000);
                assertEq(source.tickSpacing, 60);
                assertEq(source.hooks, address(0));
            }
        }
    }

    function test_everyOfficialAssetHasDirectUsdgAndTwoHopWethRoutes() public pure {
        address usdg = RHNutboxRouterConfig.usdg();
        address weth = RHNutboxRouterConfig.wrappedNative();
        INutboxRouter.InitialPricePool[] memory pools = RHNutboxRouterConfig.initialPricePools();
        INutboxRouter.InitialRoute[] memory routes = RHNutboxRouterConfig.initialRoutes();

        assertEq(routes.length, 19, "hub + 9 direct + 9 bridged");
        bytes32 hubId = _poolId(usdg, weth);
        assertEq(routes[0].tokenIn, usdg);
        assertEq(routes[0].tokenOut, weth);
        assertEq(routes[0].poolIds.length, 1);
        assertEq(routes[0].poolIds[0], hubId);
        assertTrue(_poolExists(pools, hubId), "hub pool missing");

        for (uint256 i; i < 9; ++i) {
            INutboxRouter.InitialRoute memory direct = routes[i * 2 + 1];
            INutboxRouter.InitialRoute memory bridged = routes[i * 2 + 2];
            bytes32 assetPoolId = _poolId(direct.tokenIn, usdg);

            assertTrue(direct.tokenIn != usdg && direct.tokenIn != weth, "invalid constituent");
            assertEq(direct.tokenOut, usdg);
            assertEq(direct.poolIds.length, 1);
            assertEq(direct.poolIds[0], assetPoolId);
            assertTrue(_poolExists(pools, assetPoolId), "direct pool missing");

            assertEq(bridged.tokenIn, direct.tokenIn);
            assertEq(bridged.tokenOut, weth);
            assertEq(bridged.poolIds.length, 2);
            assertEq(bridged.poolIds[0], assetPoolId);
            assertEq(bridged.poolIds[1], hubId);
        }
    }

    function test_initialConfigExactlyEncodesTheAuditedPoolAndRouteMatrix() public pure {
        (INutboxRouter.InitialPricePool[] memory pools, INutboxRouter.InitialRoute[] memory routes) = abi.decode(
            RHNutboxRouterConfig.initialConfig(), (INutboxRouter.InitialPricePool[], INutboxRouter.InitialRoute[])
        );

        assertEq(keccak256(abi.encode(pools)), keccak256(abi.encode(RHNutboxRouterConfig.initialPricePools())));
        assertEq(keccak256(abi.encode(routes)), keccak256(abi.encode(RHNutboxRouterConfig.initialRoutes())));
    }

    function _poolExists(INutboxRouter.InitialPricePool[] memory pools, bytes32 wanted) private pure returns (bool) {
        for (uint256 i; i < pools.length; ++i) {
            if (_poolId(pools[i].token0, pools[i].token1) == wanted) return true;
        }
        return false;
    }

    function _poolId(address tokenA, address tokenB) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1));
    }
}
