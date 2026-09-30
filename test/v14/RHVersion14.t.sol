// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RHPumpV14 as Pump, IPumpBasketHook} from "../../src/v14/RHPumpV14.sol";
import {RHTokenV14 as Token} from "../../src/v14/RHTokenV14.sol";
import {IPump} from "../../src/v14/IPump.sol";
import {RHSwapHookV14 as TagAISwapHook} from "../../src/v14/RHSwapHookV14.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {ERC20StakingFactory} from "../../src/nutbox/dapps/erc20-staking/ERC20StakingFactory.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {TagAILiquidityRouter} from "../../src/router/TagAILiquidityRouter.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {HookMiner} from "../../src/utils/HookMiner.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {
    RouterTestToken,
    RouterV3FactoryMock,
    RouterV3PoolMock,
    RouterPancakeV3RouterMock
} from "../unit/NutboxRouter.t.sol";

// Test venue enforcing the Uniswap V2 30 bps constant-product invariant and LP accounting.
// Actual V4 PoolManager, Token, Pump, Hook, NutboxRouter and Nutbox contracts are used below.
contract RH14Pair is ERC20 {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address a, address b) ERC20("LP", "LP") {
        factory = msg.sender;
        token0 = a;
        token1 = b;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function _sync() private {
        r0 = uint112(IERC20(token0).balanceOf(address(this)));
        r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function mint(address to) external returns (uint256 lp) {
        uint256 a = IERC20(token0).balanceOf(address(this)) - r0;
        uint256 b = IERC20(token1).balanceOf(address(this)) - r1;
        lp = totalSupply() == 0 ? Math.sqrt(a * b) : Math.min(a * totalSupply() / r0, b * totalSupply() / r1);
        require(lp > 0, "LP");
        _mint(to, lp);
        _sync();
    }

    function burn(address to) external returns (uint256 a, uint256 b) {
        uint256 lp = balanceOf(address(this));
        a = uint256(r0) * lp / totalSupply();
        b = uint256(r1) * lp / totalSupply();
        _burn(address(this), lp);
        IERC20(token0).transfer(to, a);
        IERC20(token1).transfer(to, b);
        _sync();
    }

    function swap(uint256 a, uint256 b, address to, bytes calldata) external {
        require(a < r0 && b < r1 && a + b > 0, "LIQUIDITY");
        if (a > 0) IERC20(token0).transfer(to, a);
        if (b > 0) IERC20(token1).transfer(to, b);
        uint256 x = IERC20(token0).balanceOf(address(this));
        uint256 y = IERC20(token1).balanceOf(address(this));
        uint256 i = x > r0 - a ? x - (r0 - a) : 0;
        uint256 j = y > r1 - b ? y - (r1 - b) : 0;
        require((x * 1000 - i * 3) * (y * 1000 - j * 3) >= uint256(r0) * r1 * 1000000, "K");
        _sync();
    }
}

contract RH14Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address p) {
        require(getPair[a][b] == address(0));
        p = address(new RH14Pair(a, b));
        getPair[a][b] = p;
        getPair[b][a] = p;
    }
}

contract RH14BasketDouble {
    uint32 public constant tokenVersion = 3;
    address public settlementToken;
    address public v2Factory;
    address public bridgeRouter;

    constructor(address s, address f, address r) {
        settlementToken = s;
        v2Factory = f;
        bridgeRouter = r;
    }

    function createBasketFor(address creator, bytes32, IPumpBasketHook.CreateParams calldata p)
        external
        returns (address)
    {
        require(p.creator == creator && p.constituentRoutes[0].venue == IPumpBasketHook.Venue.V2);
        require(Token(payable(p.constituentRoutes[0].poolQuoteToken)).listed());
        return address(new RouterTestToken("Index", "IDX"));
    }

    function buyExactSettlement(address basket, uint256 amount, uint256 minimum, bytes calldata, address recipient)
        external
        returns (uint256)
    {
        IERC20(settlementToken).transferFrom(msg.sender, address(this), amount);
        require(amount >= minimum);
        RouterTestToken(payable(basket)).mint(recipient, amount);
        return amount;
    }
}

contract RHVersion14Test is Test {
    using StateLibrary for IPoolManager;
    Pump internal pump;
    Token internal token;
    IPoolManager internal manager;
    TagAISwapHook internal hook;
    NutboxRouter internal router;
    RH14Factory internal factory;
    RH14BasketDouble internal basket;
    RouterTestToken internal weth;
    RouterTestToken internal usdg;
    RouterTestToken internal a;
    RouterTestToken internal b;
    Committee internal committee;
    address internal cf;
    HourlyTickCalculator internal calculator;
    ERC20StakingFactory internal staking;
    TradeCurationFactory internal tradeFactory;
    TagAITradeRouter internal trade;
    TagAILiquidityRouter internal liquidity;
    IPShare internal ipshare;
    address internal creator = address(0x1234);
    uint160 internal constant FLAGS = 0x20cc;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(3600);
        vm.deal(creator, 100 ether);
        vm.deal(address(this), 100 ether);
        weth = new RouterTestToken("WETH", "WETH");
        usdg = new RouterTestToken("USDG", "USDG");
        a = new RouterTestToken("A", "A");
        b = new RouterTestToken("B", "B");
        vm.deal(address(weth), 1000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        RouterV3FactoryMock vf = new RouterV3FactoryMock();
        RouterPancakeV3RouterMock vr = new RouterPancakeV3RouterMock(address(vf), address(weth));
        address[] memory vfs = new address[](1);
        vfs[0] = address(vf);
        address[] memory pms = new address[](1);
        pms[0] = address(manager);
        router = new NutboxRouter(
            address(weth), address(vr), new address[](0), new address[](0), vfs, pms, new address[](0), ""
        );
        _assetRoute(vf, address(a));
        _assetRoute(vf, address(b));
        _assetRoute(vf, address(usdg));
        factory = new RH14Factory();
        basket = new RH14BasketDouble(address(usdg), address(factory), address(router));
        committee = new Committee(payable(address(0xfee)));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        cf = deployCode("CommunityFactory.sol:CommunityFactory", abi.encode(address(committee)));
        calculator = new HourlyTickCalculator(cf);
        staking = new ERC20StakingFactory(cf);
        tradeFactory = new TradeCurationFactory(cf, vm.addr(0xabc));
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(staking));
        committee.adminAddContract(address(tradeFactory));
        ipshare = new IPShare(address(0xfee));
        pump = _pump(address(factory), address(basket));
        hook = _hook(pump);
        pump.adminSetHookAddress(address(hook));
        TagAIBuybackRouter buyback =
            new TagAIBuybackRouter(address(pump), address(router), address(basket), address(usdg));
        pump.adminSetBuybackRouter(address(buyback));
        trade = new TagAITradeRouter(address(pump), address(router), address(factory));
        liquidity = new TagAILiquidityRouter(trade);
    }

    function _assetRoute(RouterV3FactoryMock vf, address asset) internal {
        (address t0, address t1) = asset < address(weth) ? (asset, address(weth)) : (address(weth), asset);
        RouterV3PoolMock p = new RouterV3PoolMock(address(vf), t0, t1, 3000);
        p.setState(uint160(1 << 96), 1e18);
        vf.setPool(asset, address(weth), 3000, address(p));
        bytes32 id = router.addPricePool(INutboxRouter.SourceType.V3_POOL, abi.encode(address(vf), address(p)));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        router.addRoute(asset, address(weth), ids);
    }

    function _pump(address f, address bh) internal returns (Pump p) {
        address[] memory assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(b);
        p = new Pump(address(ipshare), address(0xfee), assets, address(0));
        p.adminSetPoolManager(address(manager));
        p.adminSetNutbox(cf, address(calculator), address(staking), address(committee));
        p.adminSetIndexInfrastructure(address(router), bh, f, address(usdg));
        p.adminSetListingKeeper(address(this));
        p.adminSetOptionalPoolFactory(address(tradeFactory), "Trade", 8000, true);
        router.addOperator(address(p));
    }

    function _hook(Pump p) internal returns (TagAISwapHook h) {
        bytes memory args = abi.encode(manager, address(p));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(TagAISwapHook).creationCode, args);
        h = new TagAISwapHook{salt: salt}(manager, address(p));
        assertEq(address(h), predicted);
    }

    function _config() internal view returns (IPump.IndexConfig memory c) {
        c.name = "Index";
        c.symbol = "IDX";
        c.basketFeeBps = 100;
        c.retainCommunityOwnership = true;
        c.constituentAssets = new address[](2);
        c.constituentAssets[0] = address(a);
        c.constituentAssets[1] = address(b);
        c.targetWeights = new uint16[](2);
        c.targetWeights[0] = 5000;
        c.targetWeights[1] = 5000;
    }

    function _create(Pump p, uint16 ratio) internal returns (Token t) {
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](ratio == 0 ? 0 : 1);
        if (ratio > 0) opts[0] = IPump.OptionalPoolConfig(address(tradeFactory), ratio, "");
        uint256 fee = p.createFee() + (ipshare.ipshareCreated(creator) ? 0 : ipshare.createFee());
        vm.prank(creator, creator);
        t = Token(payable(p.createToken{value: fee}("RH14", bytes32(uint256(1)), _config(), opts)));
    }

    function _fill(Token t, Pump p) internal {
        vm.warp(block.timestamp + 16);
        uint256 cost = p.getBuyPriceAfterFee(0, 650_000_000 ether);
        vm.prank(creator, creator);
        t.buyToken{value: cost + 1 ether}(0, address(0), 0);
        assertTrue(t.listingPending());
        assertFalse(t.listed());
    }

    function _list(Pump p, Token t) internal {
        _fill(t, p);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        p.finalizeTokenListing(address(t), mins, block.timestamp);
    }

    function _legs(Token t, uint8 route, uint256 amount, bool buy)
        internal
        view
        returns (TagAITradeRouter.Leg[] memory legs)
    {
        legs = new TagAITradeRouter.Leg[](1);
        address target = route == 0 ? address(t) : address(a);
        legs[0] = TagAITradeRouter.Leg(
            route,
            amount,
            route == 0 ? 0 : 1,
            1,
            buy ? trade.routeHash(address(0), target) : trade.routeHash(target, address(0))
        );
    }

    function test_productionContractSizeLimits() public view {
        assertLe(address(pump).code.length, 24576);
        assertLe(pump.tokenImplementation().code.length, 24576);
        assertLe(address(hook).code.length, 24576);
        assertLe(address(router).code.length, 24576);
        assertLe(address(router.priceReader()).code.length, 24576);
        assertLe(address(trade).code.length, 24576);
        assertLe(address(liquidity).code.length, 24576);
        address[] memory assets = new address[](9);
        assertLe(
            type(Pump).creationCode.length + abi.encode(address(ipshare), creator, assets, address(0)).length, 49152
        );
    }

    function test_allocationRealV4AndCurveGap() public {
        token = _create(pump, 0);
        _list(pump, token);
        assertTrue(token.listed());
        assertEq(token.getPump(), address(pump));
        assertEq(token.V4_TOKEN_ALLOCATION(), 120_000_000 ether);
        assertEq(token.COMPONENT_TOKEN_ALLOCATION(), 80_000_000 ether);
        assertApproxEqAbs(address(manager).balance, 3 ether, 10000);
        assertApproxEqAbs(token.balanceOf(address(manager)), 120_000_000 ether, 10000);
        assertEq(token.balanceOf(address(hook)), 150_000_000 ether);
        assertEq(token.balanceOf(factory.getPair(address(token), address(a))), 40_000_000 ether);
        assertEq(token.balanceOf(factory.getPair(address(token), address(b))), 40_000_000 ether);
        assertApproxEqAbs(pump.getPrice(0, 650_000_000 ether), 5 ether, 0.001 ether);
        (uint160 sqrtPrice,,,) = manager.getSlot0(token.v4PoolId());
        assertApproxEqRel(uint256(sqrtPrice) * 1e18 / (1 << 96), 6324555320336758663997, 1e12);
        uint256 end = pump.getPrice(650_000_000 ether - 1 ether, 1 ether);
        assertApproxEqRel(25_000_000_000 * 1e18 / end, 1163644375833500000, 1e12);
        Community c = Community(payable(token.nutboxCommunity()));
        assertEq(c.owner(), creator);
        assertTrue(c.poolActived(c.activedPools(0)));
        assertTrue(c.poolActived(c.activedPools(1)));
    }

    function test_mainAndComponentTradingAndBuyback() public {
        token = _create(pump, 3000);
        _list(pump, token);
        trade.buy{value: 0.01 ether}(
            address(token), _legs(token, 0, 0.01 ether, true), 1, block.timestamp, address(this), creator
        );
        assertGt(token.balanceOf(address(this)), 0);
        assertGt(hook.buybackBnbReserve(address(token)), 0);
        uint256 amount = token.balanceOf(address(this)) / 2;
        token.approve(address(trade), amount);
        trade.sell(address(token), amount, _legs(token, 0, amount, false), 1, block.timestamp, address(this), creator);
        trade.buy{value: 0.01 ether}(
            address(token), _legs(token, 1, 0.01 ether, true), 1, block.timestamp, address(this), creator
        );
        amount = 1000 ether;
        token.approve(address(trade), amount);
        trade.sell(address(token), amount, _legs(token, 1, amount, false), 1, block.timestamp, address(this), creator);
        hook.executeBuyback(address(token), 1, block.timestamp, abi.encode(uint256(1), bytes("")));
        assertEq(hook.buybackBnbReserve(address(token)), 0);
        assertGt(token.pendingBuybackReward(creator), 0);
        uint256 reward = token.claimBuybackReward(creator);
        assertGt(reward, 0);
        assertEq(IERC20(token.indexToken()).balanceOf(creator), reward);
        assertEq(address(trade).balance, 0);
        assertEq(token.balanceOf(address(trade)), 0);
    }

    function test_multiPumpLiquidityAndSecondFactory() public {
        RH14Factory second = new RH14Factory();
        RH14BasketDouble bh = new RH14BasketDouble(address(usdg), address(second), address(router));
        Pump p = _pump(address(second), address(bh));
        TagAISwapHook h = _hook(p);
        p.adminSetHookAddress(address(h));
        Token t = _create(p, 0);
        _list(p, t);
        assertFalse(trade.supportsToken(address(t)));
        trade.setPump(address(p), true);
        trade.setFactory(address(second), 30, true);
        assertTrue(trade.supportsToken(address(t)));
        vm.startPrank(creator);
        t.approve(address(liquidity), 10000 ether);
        a.mint(creator, 1 ether);
        a.approve(address(liquidity), 1 ether);
        uint256 lp = liquidity.add(address(t), 0, 10000 ether, 1 ether, 1, block.timestamp);
        assertGt(lp, 0);
        RH14Pair pair = RH14Pair(second.getPair(address(t), address(a)));
        pair.approve(address(liquidity), lp);
        (uint256 tOut, uint256 aOut) = liquidity.remove(address(t), 0, lp, 1, 1, block.timestamp);
        assertGt(tOut, 0);
        assertGt(aOut, 0);
        vm.stopPrank();
        trade.setPump(address(p), false);
        assertFalse(trade.supportsToken(address(t)));
        vm.expectRevert(TagAILiquidityRouter.InvalidPool.selector);
        liquidity.add(address(t), 0, 1, 1, 1, block.timestamp);
    }

    function test_slippageRollsBackListingThenRetry() public {
        token = _create(pump, 8000);
        _fill(token, pump);
        uint256 bal = address(token).balance;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = type(uint128).max;
        vm.expectRevert();
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listingPending());
        assertFalse(token.listed());
        assertEq(address(token).balance, bal);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.indexToken(), address(0));
        mins[1] = 1;
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listed());
    }

    function test_onlyKeeperCanList() public {
        token = _create(pump, 0);
        _fill(token, pump);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.prank(creator);
        vm.expectRevert(IPump.OnlyListingKeeper.selector);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
    }

    function test_untrustedCallbackRejected() public {
        vm.expectRevert(TagAITradeRouter.InvalidCallback.selector);
        trade.unlockCallback("");
    }

    function test_optionalOverLimitRejected() public {
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](1);
        opts[0] = IPump.OptionalPoolConfig(address(tradeFactory), 8001, "");
        uint256 fee = pump.createFee() + ipshare.createFee();
        IPump.IndexConfig memory c = _config();
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidOptionalPoolConfig.selector);
        pump.createToken{value: fee}("bad", bytes32(0), c, opts);
    }

    function test_disabledPumpAndManagerCannotTrade() public {
        token = _create(pump, 0);
        _list(pump, token);
        TagAITradeRouter.Leg[] memory legs = _legs(token, 0, 0.01 ether, true);
        trade.setPump(address(pump), false);
        vm.expectRevert(TagAITradeRouter.InvalidToken.selector);
        trade.buy{value: 0.01 ether}(address(token), legs, 1, block.timestamp, address(this), creator);
        trade.setPump(address(pump), true);
        router.setUniswapV4Manager(address(manager), false);
        vm.expectRevert(TagAITradeRouter.InvalidMainPool.selector);
        trade.buy{value: 0.01 ether}(address(token), legs, 1, block.timestamp, address(this), creator);
    }

    function testFuzz_optionalRewardsSumExactly(uint16 rawWeight, uint16 rawRatio) public {
        uint16 weight = uint16(bound(rawWeight, 1, 9999));
        uint16 ratio = uint16(bound(rawRatio, 1, 8000));
        IPump.IndexConfig memory c = _config();
        c.targetWeights[0] = weight;
        c.targetWeights[1] = 10000 - weight;
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](1);
        opts[0] = IPump.OptionalPoolConfig(address(tradeFactory), ratio, "");
        uint256 fee = pump.createFee() + ipshare.createFee();
        vm.prank(creator, creator);
        Token t = Token(payable(pump.createToken{value: fee}("FUZZ", bytes32(uint256(33)), c, opts)));
        Community community = Community(payable(t.nutboxCommunity()));
        uint256 r0 = community.poolRatios(community.activedPools(0));
        uint256 r1 = community.poolRatios(community.activedPools(1));
        uint256 r2 = community.poolRatios(community.activedPools(2));
        assertEq(r0 + r1 + r2, 10000);
        assertEq(r2, ratio);
        assertEq(r0, uint256(weight) * (10000 - ratio) / 10000);
        assertLe(r1 * 10000, uint256(10000 - weight) * (10000 - ratio) + 9999);
    }

    function test_fourComponentsTwoOptionalPoolsAndNonzeroFees() public {
        RouterTestToken cAsset = new RouterTestToken("C", "C");
        RouterTestToken dAsset = new RouterTestToken("D", "D");
        _assetRoute(RouterV3FactoryMock(router.pancakeV3Factory()), address(cAsset));
        _assetRoute(RouterV3FactoryMock(router.pancakeV3Factory()), address(dAsset));
        pump.adminSetConstituentApproval(address(cAsset), true);
        pump.adminSetConstituentApproval(address(dAsset), true);
        TradeCurationFactory other = new TradeCurationFactory(cf, vm.addr(0xdef));
        committee.adminAddContract(address(other));
        pump.adminSetOptionalPoolFactory(address(other), "Other", 8000, true);
        committee.adminSetCreateCommunityFee(0.001 ether);
        committee.adminSetCommunitySettingsFee(0.001 ether);
        IPump.IndexConfig memory c = _config();
        c.constituentAssets = new address[](4);
        c.targetWeights = new uint16[](4);
        c.constituentAssets[0] = address(a);
        c.constituentAssets[1] = address(b);
        c.constituentAssets[2] = address(cAsset);
        c.constituentAssets[3] = address(dAsset);
        for (uint256 i; i < 4; ++i) {
            c.targetWeights[i] = 2500;
        }
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](2);
        opts[0] = IPump.OptionalPoolConfig(address(tradeFactory), 4000, "");
        opts[1] = IPump.OptionalPoolConfig(address(other), 4000, "");
        uint256 fee = pump.createFee() + ipshare.createFee() + 0.007 ether;
        vm.prank(creator, creator);
        Token t = Token(payable(pump.createToken{value: fee}("MAX", bytes32(uint256(77)), c, opts)));
        Community community = Community(payable(t.nutboxCommunity()));
        for (uint256 i; i < 6; ++i) {
            assertEq(community.poolRatios(community.activedPools(i)), i < 4 ? 500 : 4000);
        }
        _fill(t, pump);
        uint256[] memory mins = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            mins[i] = 1;
        }
        pump.finalizeTokenListing(address(t), mins, block.timestamp);
        assertTrue(t.listed());
        for (uint256 i; i < 4; ++i) {
            (,, address pair) = t.componentAt(i);
            assertEq(t.balanceOf(pair), 20_000_000 ether);
        }
    }

    function test_optionalFactoryFailureRollsBackAndSameSaltCanRetry() public {
        IPump.IndexConfig memory c = _config();
        IPump.OptionalPoolConfig[] memory opts = new IPump.OptionalPoolConfig[](1);
        opts[0] = IPump.OptionalPoolConfig(address(tradeFactory), 3000, hex"01");
        uint256 fee = pump.createFee() + ipshare.createFee();
        uint256 beforeBalance = creator.balance;
        vm.prank(creator, creator);
        vm.expectRevert("Unexpected meta");
        pump.createToken{value: fee}("RETRY", bytes32(uint256(88)), c, opts);
        assertEq(creator.balance, beforeBalance);
        assertEq(pump.totalTokens(), 0);
        assertFalse(ipshare.ipshareCreated(creator));
        opts[0].meta = "";
        vm.prank(creator, creator);
        address t = pump.createToken{value: fee}("RETRY", bytes32(uint256(88)), c, opts);
        assertTrue(pump.createdTokens(t));
        assertEq(pump.totalTokens(), 1);
    }
    receive() external payable {}
}
