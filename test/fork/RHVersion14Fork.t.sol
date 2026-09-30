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

import {ColdCallGas} from "../helpers/ColdCallGas.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";

interface IRH14Create {
    function finalizeTokenListing(address, uint256[] calldata, uint256) external;
    function createToken(string calldata, bytes32, IPump.IndexConfig calldata, IPump.OptionalPoolConfig[] calldata)
        external
        payable
        returns (address);
}

interface IRH14Fees {
    function adminSetCreateCommunityFee(uint256) external;
    function adminSetCommunitySettingsFee(uint256) external;
}

contract RHVersion14ForkTest is DeployRHPump14Script, ColdCallGas {
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
        Token token =
            Token(payable(stack.pump.createToken{value: 0.1 ether}("RH14FORK", bytes32(uint256(14)), c, opts)));
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
        uint256 received = IForkBasketRouter(stack.basketRouter)
            .sellExactBasket(token.indexToken(), reward / 2, 1, abi.encode(td), creator);
        vm.stopPrank();
        assertGt(received, 0);
        assertEq(address(stack.tradeRouter).balance, 0);
        assertEq(token.balanceOf(address(stack.tradeRouter)), 0);
    }

    function test_allNineBootstrapStocksRoundTrip() public {
        address[] memory assets = RHNutboxRouterConfig.constituentAssets();
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(stack.pump.approvedConstituent(assets[i]));
            stack.router.validateRoute(address(0), assets[i]);
            stack.router.validateRoute(RHNutboxRouterConfig.usdg(), assets[i]);
            uint256 quote = stack.router.quote(address(0), assets[i], 0.01 ether);
            assertGt(quote, 0);
            uint256 output = stack.router.swapExactInput{value: 0.01 ether}(
                address(0), assets[i], 0.01 ether, quote * 90 / 100, address(this), block.timestamp
            );
            assertEq(IERC20(assets[i]).balanceOf(address(this)), output);
            IERC20(assets[i]).approve(address(stack.router), output);
            uint256 received =
                stack.router.swapExactInput(assets[i], address(0), output, 1, address(this), block.timestamp);
            assertGt(received, 0);
            assertEq(IERC20(assets[i]).balanceOf(address(this)), 0);
            assertEq(IERC20(assets[i]).balanceOf(address(stack.router)), 0);
            emit log_named_address("stock roundtrip passed", assets[i]);
        }
        assertEq(address(stack.router).balance, 0);
    }

    function test_sixPoolsColdCreationMixedV3V4AndLiquidity() public {
        IPump.IndexConfig memory c;
        c.name = "1234567890123456789012345678901234567890123456789012345678901234";
        c.symbol = "1234567890123456";
        c.basketFeeBps = 100;
        c.retainCommunityOwnership = true;
        address[] memory assets = RHNutboxRouterConfig.constituentAssets();
        c.constituentAssets = new address[](4);
        c.targetWeights = new uint16[](4);
        c.constituentAssets[0] = assets[0];
        c.constituentAssets[1] = assets[3];
        c.constituentAssets[2] = assets[7];
        c.constituentAssets[3] = assets[8];
        for (uint256 i; i < 4; ++i) {
            c.targetWeights[i] = 2500;
        }
        TradeCurationFactory second = new TradeCurationFactory(cfg.communityFactory, cfg.signer);
        address committeeOwner = IRH14Owner(cfg.committee).owner();
        vm.startPrank(committeeOwner);
        ICommittee(cfg.committee).adminAddContract(address(second));
        IRH14Fees(cfg.committee).adminSetCreateCommunityFee(0.001 ether);
        IRH14Fees(cfg.committee).adminSetCommunitySettingsFee(0.001 ether);
        vm.stopPrank();
        stack.pump.adminSetOptionalPoolFactory(address(stack.tradeFactory), c.name, 8000, true);
        stack.pump.adminSetOptionalPoolFactory(address(second), c.name, 8000, true);
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](2);
        opts[0] = IPump.OptionalPoolConfig(address(stack.tradeFactory), 4000, "");
        opts[1] = IPump.OptionalPoolConfig(address(second), 4000, "");
        uint256 fee = stack.pump.createFee() + IIPShare(cfg.ipshare).createFee() + 0.007 ether;
        bytes memory payload = abi.encodeCall(IRH14Create.createToken, ("MAXRH14", bytes32(uint256(66)), c, opts));
        uint256 intrinsic = 21000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
        }
        // Use the same conservative project budget as the BSC V14 release, including intrinsic gas.
        uint256 budget = 16_777_216;
        (bytes memory result, uint256 creationGas) = _coldCall(
            "RH six-pool cold create incl intrinsic",
            creator,
            address(stack.pump),
            fee + 1 ether,
            payload,
            budget - intrinsic - 2300
        );
        assertLt(creationGas, budget);
        Token t = Token(payable(abi.decode(result, (address))));
        assertGt(t.balanceOf(creator), 0);
        ICommunity community = ICommunity(t.nutboxCommunity());
        assertTrue(community.activedPools(5) != address(0));
        vm.expectRevert();
        community.activedPools(6);
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        t.buyToken{value: 6 ether}(0, address(0), 0);
        uint256 nativeBudget = t.componentListingNativeBudget();
        uint256[] memory mins = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            mins[i] = stack.router.quote(address(0), c.constituentAssets[i], nativeBudget / 4) * 90 / 100;
        }
        payload = abi.encodeCall(IRH14Create.finalizeTokenListing, (address(t), mins, block.timestamp));
        (, uint256 listingGas) = _coldCall(
            "RH four-stock cold listing incl intrinsic", address(this), address(stack.pump), 0, payload, 10_000_000
        );
        assertLt(listingGas, 10_000_000);
        assertTrue(t.listed());
        // Every component venue must support both directions through the production TradeRouter.
        for (uint8 i = 1; i <= 4; ++i) {
            TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
            address asset = c.constituentAssets[i - 1];
            legs[0] = TagAITradeRouter.Leg(i, 0.005 ether, 1, 1, stack.tradeRouter.routeHash(address(0), asset));
            uint256 got =
                stack.tradeRouter.buy{value: 0.005 ether}(address(t), legs, 1, block.timestamp, address(this), creator);
            t.approve(address(stack.tradeRouter), got);
            legs[0] = TagAITradeRouter.Leg(i, got, 1, 1, stack.tradeRouter.routeHash(asset, address(0)));
            stack.tradeRouter.sell(address(t), got, legs, 1, block.timestamp, address(this), creator);
        }
        // Actual V2 factory add/remove: protect net amounts after Token pair tax.
        address asset = c.constituentAssets[0];
        stack.router.swapExactInput{value: 0.01 ether}(address(0), asset, 0.01 ether, 1, creator, block.timestamp);
        vm.startPrank(creator);
        t.approve(address(stack.liquidityRouter), type(uint256).max);
        IERC20(asset).approve(address(stack.liquidityRouter), type(uint256).max);
        uint256 lp = stack.liquidityRouter
            .add(address(t), 0, 1_000_000 ether, IERC20(asset).balanceOf(creator), 1, block.timestamp);
        (,, address pair) = t.componentAt(0);
        IERC20(pair).approve(address(stack.liquidityRouter), lp);
        (uint256 tokenOut, uint256 assetOut) = stack.liquidityRouter.remove(address(t), 0, lp, 1, 1, block.timestamp);
        vm.stopPrank();
        assertGt(tokenOut, 0);
        assertGt(assetOut, 0);
        assertEq(t.balanceOf(address(stack.tradeRouter)), 0);
        assertEq(t.balanceOf(address(stack.liquidityRouter)), 0);
    }
    receive() external payable {}
}
