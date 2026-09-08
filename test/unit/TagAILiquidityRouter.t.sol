// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TagAILiquidityRouter} from "../../src/router/TagAILiquidityRouter.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {TradeToken, TradeAsset, TradeFactory, TradePump} from "./TagAITradeRouter.t.sol";

contract LPPair is ERC20 {
    address public factory;
    address public token0;
    address public token1;
    uint112 r0;
    uint112 r1;

    constructor(address f, address t, address a) ERC20("LP", "LP") {
        factory = f;
        token0 = t;
        token1 = a;
    }

    function seed() external {
        _mint(address(0xdead), 1000 ether);
        sync();
    }

    function sync() public {
        r0 = uint112(IERC20(token0).balanceOf(address(this)));
        r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function mint(address to) external returns (uint256 lp) {
        uint256 x = (IERC20(token0).balanceOf(address(this)) - r0) * totalSupply() / r0;
        uint256 y = (IERC20(token1).balanceOf(address(this)) - r1) * totalSupply() / r1;
        lp = x < y ? x : y;
        require(lp > 0);
        _mint(to, lp);
        sync();
    }

    function burn(address to) external returns (uint256 t, uint256 a) {
        uint256 lp = balanceOf(address(this));
        t = lp * IERC20(token0).balanceOf(address(this)) / totalSupply();
        a = lp * IERC20(token1).balanceOf(address(this)) / totalSupply();
        _burn(address(this), lp);
        IERC20(token0).transfer(to, t);
        IERC20(token1).transfer(to, a);
        sync();
    }
}

contract LPVenue {
    bool public underpay;

    function setUnderpay(bool value) external {
        underpay = value;
    }

    function swapExactInput(address input, address out, uint256 amount, uint256 minimum, address to, uint256)
        external
        payable
        returns (uint256 output)
    {
        if (input == address(0)) {
            require(msg.value == amount);
            output = amount * 100;
            require(output >= minimum);
            TradeAsset(out).mint(to, output);
        } else {
            require(msg.value == 0 && out == address(0));
            IERC20(input).transferFrom(msg.sender, address(this), amount);
            output = underpay ? 0 : amount / 100;
            (bool ok,) = to.call{value: output}("");
            require(ok);
        }
    }
    receive() external payable {}
}

contract LPTrade {
    address public pump;
    address public nutboxRouter;
    address public pancakeV2Factory;
    address public lastSubject;
    address public sellSubject;
    bool public underpay;

    function setUnderpay(bool value) external {
        underpay = value;
    }

    function routeHash(address input, address output) external pure returns (bytes32) {
        return keccak256(abi.encode(input, output));
    }

    constructor(address p, address n, address f) {
        pump = p;
        nutboxRouter = n;
        pancakeV2Factory = f;
    }

    function buy(address token, TagAITradeRouter.Leg[] calldata legs, uint256 min, uint256, address to, address subject)
        external
        payable
        returns (uint256)
    {
        require(legs.length == 1 && legs[0].routeIndex == 0 && legs[0].amountIn == msg.value);
        require(legs[0].routeHash == keccak256(abi.encode(address(0), token)));
        lastSubject = subject;
        uint256 out = msg.value * 1000;
        require(out >= min);
        TradeAsset(token).mint(to, out);
        return out;
    }

    function sell(
        address token,
        uint256 amount,
        TagAITradeRouter.Leg[] calldata legs,
        uint256,
        uint256,
        address to,
        address subject
    ) external returns (uint256 output) {
        require(legs.length == 1 && legs[0].routeIndex == 0 && legs[0].amountIn == amount);
        require(legs[0].routeHash == keccak256(abi.encode(token, address(0))));
        sellSubject = subject;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        output = underpay ? 0 : amount / 1000;
        (bool ok,) = to.call{value: output}("");
        require(ok);
    }
    receive() external payable {}
}

contract TagAILiquidityRouterTest is Test {
    TagAILiquidityRouter router;
    TradeToken token;
    TradeAsset asset;
    LPPair pair;
    TradeFactory factory;
    TradePump pump;
    LPTrade trade;
    LPVenue venue;

    function setUp() public {
        factory = new TradeFactory();
        pump = new TradePump();
        venue = new LPVenue();
        token = new TradeToken(address(factory), address(venue));
        asset = new TradeAsset();
        pair = new LPPair(address(factory), address(token), address(asset));
        token.add(address(asset), address(pair));
        factory.set(address(token), address(asset), address(pair));
        pump.register(address(token));
        token.mint(address(pair), 10000 ether);
        asset.mint(address(pair), 1000 ether);
        pair.seed();
        trade = new LPTrade(address(pump), address(venue), address(factory));
        router = new TagAILiquidityRouter(TagAITradeRouter(payable(address(trade))));
        token.mint(address(this), 10000 ether);
        asset.mint(address(this), 1000 ether);
        token.approve(address(router), type(uint256).max);
        asset.approve(address(router), type(uint256).max);
        pair.approve(address(router), type(uint256).max);
        vm.deal(address(this), 100 ether);
        vm.deal(address(venue), 100 ether);
        vm.deal(address(trade), 100 ether);
    }
    receive() external payable {}

    function testAddUsesNetTaxRatioAndRefundsUnusedAsset() public {
        uint256 a = asset.balanceOf(address(this));
        uint256 lp = router.add(address(token), 0, 1000 ether, 100 ether, 99 ether, block.timestamp);
        assertEq(lp, 99.9 ether);
        assertEq(a - asset.balanceOf(address(this)), 99.9 ether);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(asset.balanceOf(address(router)), 0);
    }

    function testActualLpLimitRevertsAtomically() public {
        uint256 t = token.balanceOf(address(this));
        vm.expectRevert(TagAILiquidityRouter.Slippage.selector);
        router.add(address(token), 0, 1000 ether, 100 ether, 100 ether, block.timestamp);
        assertEq(token.balanceOf(address(this)), t);
        assertEq(pair.balanceOf(address(this)), 0);
    }

    function testRemoveProtectsNetOutput() public {
        uint256 lp = router.add(address(token), 0, 1000 ether, 100 ether, 1, block.timestamp);
        uint256 beforeT = token.balanceOf(address(this));
        (uint256 t, uint256 a) = router.remove(address(token), 0, lp, 998 ether, 99 ether, block.timestamp);
        assertEq(t, 998.001 ether);
        assertEq(a, 99.9 ether);
        assertEq(token.balanceOf(address(this)) - beforeT, t);
    }

    function testRemoveRejectsGrossMinimumIgnoringTax() public {
        uint256 lp = router.add(address(token), 0, 1000 ether, 100 ether, 1, block.timestamp);
        vm.expectRevert(TagAILiquidityRouter.Slippage.selector);
        router.remove(address(token), 0, lp, 999 ether, 99 ether, block.timestamp);
        assertEq(pair.balanceOf(address(this)), lp);
    }

    function _zap(uint256 tokenBnb) internal view returns (TagAILiquidityRouter.Zap memory z) {
        z = TagAILiquidityRouter.Zap({
            token: address(token),
            component: 0,
            tokenBnb: tokenBnb,
            minToken: 1,
            minAsset: 1,
            minLP: 1,
            deadline: block.timestamp,
            subject: address(123),
            mainRouteHash: trade.routeHash(address(0), address(token)),
            assetRouteHash: trade.routeHash(address(0), address(asset)),
            minTokenRefundRateX128: (uint256(1) << 128) * 99 / 100000,
            minAssetRefundRateX128: (uint256(1) << 128) * 99 / 10000
        });
    }

    function testZapMainOnlyAndSellsAssetSurplusForBnb() public {
        uint256 beforeNative = address(this).balance;
        uint256 beforeA = asset.balanceOf(address(this));
        uint256 lp = router.addWithBNB{value: 1 ether}(_zap(0.5 ether));
        assertEq(lp, 49.95 ether);
        assertEq(trade.lastSubject(), address(123));
        assertEq(pair.balanceOf(address(this)), lp);
        assertEq(pair.balanceOf(address(router)), 0);
        assertEq(asset.balanceOf(address(this)), beforeA);
        assertEq(address(this).balance, beforeNative - 1 ether + 0.0005 ether);
        assertEq(asset.allowance(address(router), address(venue)), 0);
    }

    function testZapSellsTokenSurplusOnMainAndPreservesStrayBalances() public {
        token.mint(address(router), 123);
        asset.mint(address(router), 456);
        vm.deal(address(router), 789);
        uint256 beforeT = token.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        router.addWithBNB{value: 1 ether}(_zap(0.6 ether));
        assertEq(token.balanceOf(address(this)), beforeT);
        assertGt(address(this).balance, beforeNative - 1 ether);
        assertEq(trade.sellSubject(), address(123));
        assertEq(token.balanceOf(address(router)), 123);
        assertEq(asset.balanceOf(address(router)), 456);
        assertEq(address(router).balance, 789);
        assertEq(token.allowance(address(router), address(trade)), 0);
    }

    function testZapAssetRefundUnderpaymentRevertsMintAndBuys() public {
        venue.setUnderpay(true);
        uint256 beforeNative = address(this).balance;
        TagAILiquidityRouter.Zap memory z = _zap(0.5 ether);
        vm.expectRevert(TagAILiquidityRouter.Slippage.selector);
        router.addWithBNB{value: 1 ether}(z);
        assertEq(pair.balanceOf(address(this)), 0);
        assertEq(address(this).balance, beforeNative);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function testZapTokenRefundUnderpaymentRevertsMintAndBuys() public {
        trade.setUnderpay(true);
        TagAILiquidityRouter.Zap memory z = _zap(0.6 ether);
        vm.expectRevert(TagAILiquidityRouter.Slippage.selector);
        router.addWithBNB{value: 1 ether}(z);
        assertEq(pair.balanceOf(address(this)), 0);
    }

    function testZapRejectsChangedAssetRouteAndMissingRate() public {
        TagAILiquidityRouter.Zap memory z = _zap(0.5 ether);
        z.assetRouteHash = bytes32(uint256(1));
        vm.expectRevert(TagAILiquidityRouter.InvalidPool.selector);
        router.addWithBNB{value: 1 ether}(z);
        z = _zap(0.5 ether);
        z.minAssetRefundRateX128 = 0;
        vm.expectRevert(TagAILiquidityRouter.InvalidAmount.selector);
        router.addWithBNB{value: 1 ether}(z);
    }

    function testZapRefundsUnsellableDustInOriginalAsset() public {
        uint256 beforeA = asset.balanceOf(address(this));
        router.addWithBNB{value: 2000}(_zap(1000));
        assertEq(asset.balanceOf(address(this)) - beforeA, 100);
        assertEq(asset.balanceOf(address(router)), 0);
        assertGt(pair.balanceOf(address(this)), 0);
    }

    function testDoesNotSpendStrayBalances() public {
        token.mint(address(router), 123);
        asset.mint(address(router), 456);
        vm.deal(address(router), 789);
        router.add(address(token), 0, 1000 ether, 100 ether, 1, block.timestamp);
        assertEq(token.balanceOf(address(router)), 123);
        assertEq(asset.balanceOf(address(router)), 456);
        assertEq(address(router).balance, 789);
    }

    function testRejectsExpiredAndUnlistedPool() public {
        vm.warp(100);
        vm.expectRevert(TagAILiquidityRouter.Expired.selector);
        router.add(address(token), 0, 1, 1, 1, 99);
        token.configure(false, trade.nutboxRouter());
        vm.expectRevert(TagAILiquidityRouter.InvalidPool.selector);
        router.add(address(token), 0, 1, 1, 1, 100);
    }

    function testFuzzAssetLimitedAddition(uint128 raw) public {
        uint256 a = bound(uint256(raw), 1 ether, 50 ether);
        uint256 beforeA = asset.balanceOf(address(this));
        uint256 lp = router.add(address(token), 0, 1000 ether, a, 1, block.timestamp);
        assertLe(beforeA - asset.balanceOf(address(this)), a);
        assertGt(lp, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }
}
