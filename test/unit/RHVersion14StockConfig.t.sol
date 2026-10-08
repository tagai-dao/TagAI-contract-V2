// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {RHVersion14StockConfig as Stocks} from "../../script/config/RHVersion14StockConfig.sol";
import {RHNutboxRouterConfig as Infra} from "../../script/config/RHNutboxRouterConfig.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {RHPumpV14} from "../../src/v14/RHPumpV14.sol";

contract RHVersion14StockConfigTest is Test {
    function test_generatedConfigMatchesVerifiedManifest() public view {
        string memory json = vm.readFile("deployments/4663/rh14-stocks/manifest.json");
        address[] memory assets = Stocks.constituentAssets();
        address[] memory verified = vm.parseJsonAddressArray(json, ".assets");
        uint256[] memory tvls = vm.parseJsonUintArray(json, ".tvlUsdCents");
        assertEq(assets, verified);
        assertEq(assets.length, vm.parseJsonUint(json, ".selectedCount"));
        assertEq(assets.length, tvls.length);
        assertEq(Stocks.VALIDATED_BLOCK, vm.parseJsonUint(json, ".blockNumber"));
        INutboxRouter.InitialPricePool[] memory pools = Stocks.initialPricePools();
        assertEq(pools.length, assets.length + 1);
        for (uint256 i; i < assets.length; ++i) {
            assertGt(tvls[i], 5_000_000, "TVL must be strictly greater than USD 50,000");
            assertTrue(assets[i] != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(assets[i] != assets[j], "duplicate asset");
            }
            INutboxRouter.InitialPricePool memory p = pools[i + 1];
            assertTrue(p.token0 < p.token1);
            assertTrue(p.token0 == assets[i] || p.token1 == assets[i]);
            string memory prefix = string.concat(".selected[", vm.toString(i), "].pool");
            assertEq(p.token0, vm.parseJsonAddress(json, string.concat(prefix, ".token0.address")));
            assertEq(p.token1, vm.parseJsonAddress(json, string.concat(prefix, ".token1.address")));
            if (p.sourceType == INutboxRouter.SourceType.V3_POOL) {
                (address factory, address pool) = abi.decode(p.sourceData, (address, address));
                assertEq(factory, Infra.v3Factory());
                assertEq(pool, vm.parseJsonAddress(json, string.concat(prefix, ".poolId")));
            } else {
                assertEq(uint256(p.sourceType), uint256(INutboxRouter.SourceType.UNISWAP_V4));
                INutboxRouter.UniswapV4Source memory source = abi.decode(p.sourceData, (INutboxRouter.UniswapV4Source));
                assertEq(source.poolManager, Infra.poolManager());
                assertEq(source.currency0, p.token0);
                assertEq(source.currency1, p.token1);
                assertEq(source.hooks, address(0));
                assertLt(source.fee, 50000);
                assertGt(source.tickSpacing, 0);
                assertEq(
                    keccak256(
                        abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks)
                    ),
                    vm.parseJsonBytes32(json, string.concat(prefix, ".poolId"))
                );
            }
        }
    }

    function test_everyAllowedAssetHasConnectedUsdgAndWethRoutes() public pure {
        address[] memory assets = Stocks.constituentAssets();
        INutboxRouter.InitialPricePool[] memory pools = Stocks.initialPricePools();
        INutboxRouter.InitialRoute[] memory routes = Stocks.initialRoutes();
        assertEq(routes.length, assets.length * 2 + 1);
        assertEq(routes[0].tokenIn, Infra.usdg());
        assertEq(routes[0].tokenOut, Infra.wrappedNative());
        for (uint256 i; i < routes.length; ++i) {
            address cursor = routes[i].tokenIn;
            assertGt(routes[i].poolIds.length, 0);
            assertLe(routes[i].poolIds.length, 2);
            for (uint256 j; j < routes[i].poolIds.length; ++j) {
                bool found;
                for (uint256 k; k < pools.length; ++k) {
                    if (keccak256(abi.encode(pools[k].token0, pools[k].token1)) == routes[i].poolIds[j]) {
                        assertTrue(cursor == pools[k].token0 || cursor == pools[k].token1, "disconnected route");
                        cursor = cursor == pools[k].token0 ? pools[k].token1 : pools[k].token0;
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "missing pool");
            }
            assertEq(cursor, routes[i].tokenOut);
        }
        for (uint256 i; i < assets.length; ++i) {
            INutboxRouter.InitialRoute memory a = routes[2 * i + 1];
            INutboxRouter.InitialRoute memory b = routes[2 * i + 2];
            assertEq(a.tokenIn, assets[i]);
            assertEq(b.tokenIn, assets[i]);
            assertTrue(
                (a.tokenOut == Infra.usdg() && b.tokenOut == Infra.wrappedNative())
                    || (b.tokenOut == Infra.usdg() && a.tokenOut == Infra.wrappedNative())
            );
        }
    }

    function test_deploymentInitcodeFitsWithSeparateStockInitialization() public pure {
        address[] memory one = new address[](1);
        uint256 routerArgs =
            abi.encode(Infra.wrappedNative(), Infra.v3Router(), one, one, one, one, new address[](0), bytes("")).length;
        assertLe(type(NutboxRouter).creationCode.length + routerArgs, 49152);
        assertLe(
            type(RHPumpV14).creationCode.length
                + abi.encode(address(1), address(2), Stocks.constituentAssets(), address(0)).length,
            49152
        );
    }

    function test_recoveryPlanPinsTheOriginalStockMatrix() public view {
        string memory plan = vm.readFile("deployments/4663/rh14-recovery/plan.json");
        assertEq(
            keccak256(abi.encode(Stocks.initialPricePools(), Stocks.initialRoutes())),
            vm.parseJsonBytes32(plan, ".configHash")
        );
        assertEq(vm.parseJsonUint(plan, ".configuredPools"), Stocks.initialPricePools().length);
        assertEq(vm.parseJsonUint(plan, ".configuredRoutes"), Stocks.initialRoutes().length - 5);
    }
}
