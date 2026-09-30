// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeployRHPump14Script, IRH14Owner, IRH14Committee, IRH14BasketRegistry} from "../../script/DeployRHPump14.s.sol";
import {RHTokenV14 as Token} from "../../src/v14/RHTokenV14.sol";
import {IPump} from "../../src/v14/IPump.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {RHNutboxRouterConfig} from "../../script/config/RHNutboxRouterConfig.sol";

interface IForkBasketRouter {
    function sellExactBasket(address, uint256, uint256, bytes calldata, address) external returns (uint256);
}

contract RHVersion14ForkTest is DeployRHPump14Script, Test {
    Stack internal stack;
    Config internal cfg;
    address internal creator = address(0x123456);

    struct TradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minUsdgOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 hubSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }

    function setUp() public {
        if (!vm.envOr("RUN_RH14_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(
            vm.envOr("RH14_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")),
            vm.envOr("RH14_FORK_BLOCK", uint256(76263063))
        );
        vm.chainId(4663);
        cfg = loadConfig();
        cfg.keeper = address(this);
        stack = deployStack(cfg, address(this));
        vm.prank(IRH14Owner(cfg.committee).owner());
        IRH14Committee(cfg.committee).adminAddContract(address(stack.tradeFactory));
        address registryOwner = IRH14Owner(cfg.registry).owner();
        vm.startPrank(registryOwner);
        IRH14BasketRegistry(cfg.registry).setRegistrarApproval(stack.basketHook, true);
        IRH14BasketRegistry(cfg.registry).setCreatorForwarderApproval(address(stack.pump), true);
        IRH14BasketRegistry(cfg.registry).setCreatorForwarderApproval(stack.basketRouter, true);
        vm.stopPrank();
        vm.deal(creator, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function test_RH14ForkLifecycleWithRealStocksAndBasket() public {
        IPump.IndexConfig memory c;
        c.name = "RH14 Stocks";
        c.symbol = "RH14";
        c.basketFeeBps = 100;
        c.retainCommunityOwnership = true;
        address[] memory assets = RHNutboxRouterConfig.constituentAssets();
        c.constituentAssets = new address[](2);
        c.constituentAssets[0] = assets[0];
        c.constituentAssets[1] = assets[3];
        c.targetWeights = new uint16[](2);
        c.targetWeights[0] = 5000;
        c.targetWeights[1] = 5000;
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](1);
        opts[0] = IPump.OptionalPoolConfig(address(stack.tradeFactory), 3000, "");
        // Fixed fees are chain configuration; excess value follows the documented pre-buy path.
        vm.prank(creator, creator);
        Token token = Token(
            payable(stack.pump.createToken{value: 0.1 ether}("RH14FORK", bytes32(uint256(14)), c, opts))
        );
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        token.buyToken{value: 6 ether}(0, address(0), 0);
        assertTrue(token.listingPending());
        uint256 budget = token.componentListingNativeBudget();
        assertApproxEqAbs(budget, 2 ether, 0.001 ether);
        uint256[] memory mins = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            mins[i] = stack.router.quote(address(0), c.constituentAssets[i], budget / 2) * 90 / 100;
        }
        uint256 used = gasleft();
        stack.pump.finalizeTokenListing(address(token), mins, block.timestamp + 300);
        emit log_named_uint("listing execution gas", used - gasleft());
        assertTrue(token.listed());
        assertGt(token.indexToken().code.length, 0);
        for (uint256 i; i < 2; ++i) {
            (address asset,, address pair) = token.componentAt(i);
            assertEq(token.balanceOf(pair), 40_000_000 ether);
            assertGt(IERC20(asset).balanceOf(pair), 0);
        }
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = TagAITradeRouter.Leg(0, 0.01 ether, 0, 1, stack.tradeRouter.routeHash(address(0), address(token)));
        stack.tradeRouter.buy{value: 0.01 ether}(address(token), legs, 1, block.timestamp, address(this), creator);
        uint256 sellAmount = token.balanceOf(address(this)) / 2;
        token.approve(address(stack.tradeRouter), sellAmount);
        legs[0] = TagAITradeRouter.Leg(0, sellAmount, 0, 1, stack.tradeRouter.routeHash(address(token), address(0)));
        stack.tradeRouter.sell(address(token), sellAmount, legs, 1, block.timestamp, address(this), creator);
        TradeData memory td;
        td.minBasketOut = 1;
        td.legMins = new uint256[](2);
        td.legMins[0] = 1;
        td.legMins[1] = 1;
        uint256 reserve = stack.hook.buybackBnbReserve(address(token));
        assertGt(reserve, 0);
        uint256 minSettlement = stack.router.quote(address(0), RHNutboxRouterConfig.usdg(), reserve) * 90 / 100;
        stack.hook.executeBuyback(address(token), 1, block.timestamp + 300, abi.encode(minSettlement, abi.encode(td)));
        uint256 reward = token.claimBuybackReward(creator);
        assertGt(reward, 0);
        assertEq(IERC20(token.indexToken()).balanceOf(creator), reward);
        // Exercise the unchanged BasketSwapRouter's sell path, including taxed T/stock legs.
        td.minBasketOut = 0;
        td.minUsdgOut = 1;
        vm.startPrank(creator);
        IERC20(token.indexToken()).approve(stack.basketRouter, reward / 2);
        uint256 received =
            IForkBasketRouter(stack.basketRouter)
            .sellExactBasket(token.indexToken(), reward / 2, 1, abi.encode(td), creator);
        vm.stopPrank();
        assertGt(received, 0);
        assertEq(address(stack.tradeRouter).balance, 0);
        assertEq(token.balanceOf(address(stack.tradeRouter)), 0);
    }
    receive() external payable {}
}
