// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrepareBSCStockRoutes, IStockRoutePump} from "../../script/PrepareBSCStockRoutes.s.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

contract BSCStockRouteExpansionTest is Test {
    function test_fork_expansionBatchAndAllFourAssetsTradeBothDirections() public {
        require(block.chainid == 56, "Run with --fork-url and --chain-id 56");
        PrepareBSCStockRoutes plan = new PrepareBSCStockRoutes();
        NutboxRouter router = NutboxRouter(payable(plan.ROUTER()));
        (address owner, PrepareBSCStockRoutes.Call[] memory calls) = plan.prepare();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok, bytes memory reason) = calls[i].to.call(calls[i].data);
            if (!ok) assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        (, PrepareBSCStockRoutes.Call[] memory remaining) = plan.prepare();
        assertEq(remaining.length, 0, "Batch must be restartable after execution");
        Config.AssetConfig[] memory assets = Config.stockExpansionAssets();
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(IStockRoutePump(plan.PUMP()).approvedConstituent(assets[i].token));
            _roundTrip(router, assets[i].token, makeAddr(assets[i].symbol));
        }
    }

    function _roundTrip(NutboxRouter router, address token, address trader) private {
        address usdt = Config.settlementToken();
        address wbnb = Config.wrappedNative();
        uint256 stockDust = IERC20(token).balanceOf(address(router));
        uint256 usdtDust = IERC20(usdt).balanceOf(address(router));
        uint256 wbnbDust = IERC20(wbnb).balanceOf(address(router));
        uint256 nativeDust = address(router).balance;
        deal(usdt, trader, 1_000 ether);
        deal(trader, 1 ether);
        vm.startPrank(trader);
        IERC20(usdt).approve(address(router), type(uint256).max);
        IERC20(token).approve(address(router), type(uint256).max);
        uint256 beforeStock = IERC20(token).balanceOf(trader);
        uint256 stock = router.swapExactInput(
            usdt, token, 1_000 ether, router.quote(usdt, token, 1_000 ether) * 95 / 100, trader, block.timestamp
        );
        assertGt(stock, 0);
        assertEq(IERC20(token).balanceOf(trader) - beforeStock, stock);
        uint256 usdtOut = router.swapExactInput(
            token, usdt, stock, router.quote(token, usdt, stock) * 95 / 100, trader, block.timestamp
        );
        assertGt(usdtOut, 950 ether);
        assertEq(IERC20(usdt).balanceOf(trader), usdtOut);
        stock = router.swapExactInput{value: 1 ether}(
            address(0), token, 1 ether, router.quote(address(0), token, 1 ether) * 95 / 100, trader, block.timestamp
        );
        assertEq(IERC20(token).balanceOf(trader) - beforeStock, stock);
        uint256 nativeOut = router.swapExactInput(
            token, address(0), stock, router.quote(token, address(0), stock) * 95 / 100, trader, block.timestamp
        );
        assertGt(nativeOut, 0.95 ether);
        assertEq(trader.balance, nativeOut);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(address(router)), stockDust);
        assertEq(IERC20(usdt).balanceOf(address(router)), usdtDust);
        assertEq(IERC20(wbnb).balanceOf(address(router)), wbnbDust);
        assertEq(address(router).balance, nativeDust);
    }
}
