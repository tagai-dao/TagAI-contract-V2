// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";

contract TradeAsset is ERC20 {
    constructor() ERC20("Asset", "A") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TradeToken is TradeAsset {
    bool public listed = true;
    address public pancakeV2Factory;
    address public router;
    address[] public assets;
    address[] public pairs;
    mapping(address => bool) public taxed;

    constructor(address factory_, address router_) {
        pancakeV2Factory = factory_;
        router = router_;
    }

    function configure(bool listed_, address router_) external {
        listed = listed_;
        router = router_;
    }

    function add(address asset, address pair) external {
        assets.push(asset);
        pairs.push(pair);
        taxed[pair] = true;
    }

    function replacePair(uint256 i, address pair) external {
        pairs[i] = pair;
    }

    function componentCount() external view returns (uint256) {
        return assets.length;
    }

    function componentAt(uint256 i) external view returns (address, uint16, address) {
        return (assets[i], 2500, pairs[i]);
    }

    function listingInfrastructure() external view returns (address, address, address, address) {
        return (router, address(0), address(0), address(0));
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 tax = taxed[from] || taxed[to] ? amount / 1000 : 0;
        super._transfer(from, to, amount - tax);
        if (tax != 0) super._transfer(from, address(0xdead), tax);
    }
}

contract TradePump {
    mapping(address => bool) public createdTokens;

    function register(address token) external {
        createdTokens[token] = true;
    }
}

contract TradeFactory {
    mapping(address => mapping(address => address)) public getPair;

    function set(address a, address b, address pair) external {
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

// Enforces the real Pancake V2 fee-adjusted constant-product invariant.
contract TradePair {
    address public factory;
    address public token0;
    address public token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address f, address a, address b) {
        factory = f;
        token0 = a;
        token1 = b;
    }

    function sync() public {
        r0 = uint112(IERC20(token0).balanceOf(address(this)));
        r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata) external {
        require(out0 < r0 && out1 < r1 && out0 + out1 > 0, "LIQUIDITY");
        if (out0 != 0) IERC20(token0).transfer(to, out0);
        if (out1 != 0) IERC20(token1).transfer(to, out1);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - out0 ? b0 - (r0 - out0) : 0;
        uint256 in1 = b1 > r1 - out1 ? b1 - (r1 - out1) : 0;
        require((b0 * 10000 - in0 * 25) * (b1 * 10000 - in1 * 25) >= uint256(r0) * r1 * 10000 ** 2, "K");
        sync();
    }
}

contract TradeVenue {
    mapping(address => uint256) public unitsPerBnb;
    uint256 public revision;
    uint256 public spendBps = 10000;
    uint256 public outputBps = 10000;
    bool public enabled = true;
    uint256 public poolCount = 1;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryBlocked;

    function register(address token, uint256 units) external {
        unitsPerBnb[token] = units;
    }

    function configure(uint256 spend, uint256 output) external {
        spendBps = spend;
        outputBps = output;
    }

    function changeRoute() external {
        revision++;
    }

    function disable() external {
        enabled = false;
    }

    function setCount(uint256 count) external {
        poolCount = count;
    }

    function attack(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function hasRoute(address a, address b) external view returns (bool) {
        return (a == address(0) ? unitsPerBnb[b] : unitsPerBnb[a]) != 0;
    }

    function routePoolCount(address, address) external view returns (uint256) {
        return poolCount;
    }

    function routePoolAt(address a, address b, uint256 i) external pure returns (bytes32) {
        return keccak256(abi.encode(a, b, i));
    }

    function pricePool(bytes32)
        external
        view
        returns (bool, uint32, address, address, INutboxRouter.SourceType, bytes memory)
    {
        return (enabled, 1, address(0), address(1), INutboxRouter.SourceType.PANCAKE_V4_CL, abi.encode(revision));
    }

    function swapExactInput(address a, address b, uint256 amount, uint256, address to, uint256)
        external
        payable
        returns (uint256)
    {
        if (reentryTarget != address(0)) {
            (bool ok, bytes memory reason) = reentryTarget.call(reentryData);
            reentryBlocked = !ok
                && keccak256(reason)
                    == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
            require(reentryBlocked, "NOT_GUARDED");
        }
        uint256 spent = amount * spendBps / 10000;
        if (a == address(0)) {
            require(msg.value == amount, "VALUE");
            TradeAsset(b).mint(to, spent * unitsPerBnb[b] * outputBps / 10000);
            if (spent < amount) {
                (bool ok,) = msg.sender.call{value: amount - spent}("");
                require(ok);
            }
        } else {
            require(msg.value == 0);
            IERC20(a).transferFrom(msg.sender, address(this), spent);
            (bool ok,) = to.call{value: spent / unitsPerBnb[a] * outputBps / 10000}("");
            require(ok);
        }
        return type(uint256).max; // Deliberately untrusted accounting; minimum is not enforced here.
    }
}

contract RejectNative {
    receive() external payable {
        revert("REJECT");
    }
}

contract TagAITradeRouterTest is Test {
    TradePump pump;
    TradeFactory factory;
    TradeVenue venue;
    TradeToken token;
    TradeAsset[4] assets;
    TradePair[4] pairs;
    TagAITradeRouter router;
    address user = address(0x1234);
    address recipient = address(0x5678);

    function setUp() public {
        pump = new TradePump();
        factory = new TradeFactory();
        venue = new TradeVenue();
        token = new TradeToken(address(factory), address(venue));
        pump.register(address(token));
        venue.register(address(token), 100);
        for (uint256 i; i < 4; ++i) {
            assets[i] = new TradeAsset();
            // Both orientations must work.
            pairs[i] = new TradePair(
                address(factory),
                i % 2 == 0 ? address(token) : address(assets[i]),
                i % 2 == 0 ? address(assets[i]) : address(token)
            );
            factory.set(address(token), address(assets[i]), address(pairs[i]));
            token.add(address(assets[i]), address(pairs[i]));
            venue.register(address(assets[i]), 2);
            token.mint(address(pairs[i]), 100_000 ether);
            assets[i].mint(address(pairs[i]), 1000 ether);
            pairs[i].sync();
        }
        router = new TagAITradeRouter(address(pump), address(venue), address(factory));
        token.mint(user, 100_000 ether);
        vm.deal(user, 100 ether);
        vm.deal(address(venue), 1000 ether);
        vm.prank(user);
        token.approve(address(router), type(uint256).max);
    }

    function _leg(uint8 index, uint256 amount, bool buy) internal view returns (TagAITradeRouter.Leg memory) {
        address a = index == 0 ? address(token) : address(assets[index - 1]);
        return TagAITradeRouter.Leg(
            index, amount, index == 0 ? 0 : 1, 1, router.routeHash(buy ? address(0) : a, buy ? a : address(0))
        );
    }

    function _one(uint8 index, uint256 amount, bool buy) internal view returns (TagAITradeRouter.Leg[] memory legs) {
        legs = new TagAITradeRouter.Leg[](1);
        legs[0] = _leg(index, amount, buy);
    }

    function _buy(TagAITradeRouter.Leg[] memory legs, uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.prank(user);
        return router.buy{value: amount}(address(token), legs, minOut, block.timestamp, recipient);
    }

    function _sell(TagAITradeRouter.Leg[] memory legs, uint256 amount, uint256 minOut) internal returns (uint256) {
        vm.prank(user);
        return router.sell(address(token), amount, legs, minOut, block.timestamp, recipient);
    }

    function _empty() internal view {
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(address(router), address(venue)), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(assets[i].balanceOf(address(router)), 0);
            assertEq(assets[i].allowance(address(router), address(venue)), 0);
        }
    }

    function test_buyMainActualRecipientBalance() public {
        uint256 out = _buy(_one(0, 1 ether, true), 1 ether, 100 ether);
        assertEq(out, 100 ether);
        assertEq(token.balanceOf(recipient), out);
        _empty();
    }

    function test_eventsDistinguishInputRefundAndActualSpend() public {
        venue.configure(5000, 10000);
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        vm.recordLogs();
        _buy(legs, 1 ether, 1);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool tradeFound;
        bool legFound;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(router)) continue;
            if (
                entries[i].topics[0]
                    == keccak256("TradeExecuted(address,address,address,bool,uint256,uint256,uint256,bytes32)")
            ) {
                (bool isBuy, uint256 input, uint256 output, uint256 refund, bytes32 plan) =
                    abi.decode(entries[i].data, (bool, uint256, uint256, uint256, bytes32));
                assertTrue(isBuy);
                assertEq(input, 1 ether);
                assertEq(output, 50 ether);
                assertEq(refund, 0.5 ether);
                assertEq(plan, keccak256(abi.encode(legs)));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(user))));
                assertEq(entries[i].topics[3], bytes32(uint256(uint160(recipient))));
                tradeFound = true;
            } else if (entries[i].topics[0] == keccak256("LegExecuted(address,uint8,bool,uint256,uint256)")) {
                (bool isBuy, uint256 spent, uint256 output) = abi.decode(entries[i].data, (bool, uint256, uint256));
                assertTrue(isBuy);
                assertEq(spent, 0.5 ether);
                assertEq(output, 50 ether);
                legFound = true;
            }
        }
        assertTrue(tradeFound && legFound);
    }

    function test_sellMainActualBnb() public {
        uint256 out = _sell(_one(0, 100 ether, false), 100 ether, 1 ether);
        assertEq(out, 1 ether);
        assertEq(recipient.balance, out);
        _empty();
    }

    function test_buyComponentsBothDirectionsIncludesTax() public {
        for (uint8 i = 1; i <= 4; ++i) {
            uint256 beforeDead = token.balanceOf(address(0xdead));
            uint256 gross = uint256(2 ether) * 9975 * 100_000 ether / (1000 ether * 10000 + 2 ether * 9975);
            uint256 out = _buy(_one(i, 1 ether, true), 1 ether, 1);
            assertEq(out, gross - gross / 1000);
            assertEq(token.balanceOf(address(0xdead)) - beforeDead, gross / 1000);
        }
        _empty();
    }

    function test_sellComponentsBothDirectionsIncludesTax() public {
        for (uint8 i = 1; i <= 4; ++i) {
            uint256 beforeDead = token.balanceOf(address(0xdead));
            uint256 net = 100 ether - 100 ether / 1000;
            uint256 assetOut = net * 9975 * 1000 ether / (100_000 ether * 10000 + net * 9975);
            assertEq(_sell(_one(i, 100 ether, false), 100 ether, 1), assetOut / 2);
            assertEq(token.balanceOf(address(0xdead)) - beforeDead, 100 ether / 1000);
        }
        _empty();
    }

    function test_fiveLegBuyAndSellInRequestedOrder() public {
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](5);
        for (uint8 i; i < 5; ++i) {
            legs[i] = _leg(4 - i, 0.2 ether, true);
        }
        uint256 out = _buy(legs, 1 ether, 1);
        assertGt(out, 100 ether);
        for (uint8 i; i < 5; ++i) {
            legs[i] = _leg(i, 20 ether, false);
        }
        assertGt(_sell(legs, 100 ether, 1), 0);
        _empty();
    }

    function test_planAndDeadlineValidation() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 2 ether, 1);
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 1 ether, 0);
        legs[0].minAmountOut = 0;
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 1 ether, 1);
        legs[0] = _leg(1, 1 ether, true);
        legs[0].minIntermediateOut = 0;
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 1 ether, 1);
        legs[0] = _leg(0, 1 ether, true);
        legs[0].routeIndex = 5;
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 1 ether, 1);
        legs[0] = _leg(0, 1 ether, true);
        vm.prank(user);
        vm.expectRevert(TagAITradeRouter.DeadlineExpired.selector);
        router.buy{value: 1 ether}(address(token), legs, 1, block.timestamp - 1, recipient);
    }

    function test_noRepeatedPoolOrEmptyPlan() public {
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](2);
        legs[0] = _leg(1, 1 ether, true);
        legs[1] = legs[0];
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(legs, 2 ether, 1);
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        _buy(new TagAITradeRouter.Leg[](0), 1 ether, 1);
    }

    function test_onlyRegisteredListedTokenWithMatchingInfrastructure() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        token.configure(false, address(venue));
        vm.expectRevert(TagAITradeRouter.InvalidToken.selector);
        _buy(legs, 1 ether, 1);
        token.configure(true, address(1));
        vm.expectRevert(TagAITradeRouter.InvalidToken.selector);
        _buy(legs, 1 ether, 1);
        vm.expectRevert(TagAITradeRouter.InvalidToken.selector);
        vm.prank(user);
        router.buy{value: 1 ether}(address(assets[0]), legs, 1, block.timestamp, recipient);
    }

    function test_rejectsUnregisteredPair() public {
        TagAITradeRouter.Leg[] memory legs = _one(1, 1 ether, true);
        factory.set(address(token), address(assets[0]), address(pairs[1]));
        vm.expectRevert(TagAITradeRouter.InvalidPair.selector);
        _buy(legs, 1 ether, 1);
    }

    function test_routeSourceReplacementInvalidatesQuote() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        venue.changeRoute();
        vm.expectRevert(TagAITradeRouter.RouteChanged.selector);
        _buy(legs, 1 ether, 1);
        venue.disable();
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        router.routeHash(address(0), address(token));
    }

    function test_capsRouteLength() public {
        venue.setCount(9);
        vm.expectRevert(TagAITradeRouter.InvalidPlan.selector);
        router.routeHash(address(0), address(token));
    }

    function test_actualMinimumDespiteDishonestRouterReturn() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        legs[0].minAmountOut = 100 ether;
        venue.configure(10000, 5000);
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        _buy(legs, 1 ether, 1);
        legs = _one(1, 1 ether, true);
        legs[0].minIntermediateOut = 2 ether;
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        _buy(legs, 1 ether, 1);
    }

    function test_sellLegMinimumAndIntermediateMinimum() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 100 ether, false);
        legs[0].minAmountOut = 2 ether;
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        _sell(legs, 100 ether, 1);
        legs = _one(1, 100 ether, false);
        legs[0].minIntermediateOut = 1000 ether;
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        _sell(legs, 100 ether, 1);
    }

    function test_finalMinimumRollsBackAllLegsAndTax() public {
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](2);
        legs[0] = _leg(0, 1 ether, true);
        legs[1] = _leg(1, 1 ether, true);
        uint256 deadBefore = token.balanceOf(address(0xdead));
        uint256 bnbBefore = user.balance;
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        _buy(legs, 2 ether, 1000 ether);
        assertEq(user.balance, bnbBefore);
        assertEq(token.balanceOf(address(0xdead)), deadBefore);
        assertEq(token.balanceOf(address(pairs[0])), 100_000 ether);
        _empty();
    }

    function test_finalRecipientTransferTaxIsIncluded() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        vm.prank(user);
        vm.expectRevert(TagAITradeRouter.Slippage.selector);
        router.buy{value: 1 ether}(address(token), legs, 100 ether, block.timestamp, address(pairs[0]));
    }

    function test_refundsOnlyCurrentCallBalances() public {
        vm.deal(address(router), 3 ether);
        token.mint(address(router), 7 ether);
        assets[0].mint(address(router), 9 ether);
        venue.configure(5000, 10000);
        uint256 bnbBefore = user.balance;
        _buy(_one(0, 1 ether, true), 1 ether, 1);
        assertEq(bnbBefore - user.balance, 0.5 ether);
        uint256 tokenBefore = token.balanceOf(user);
        _sell(_one(0, 100 ether, false), 100 ether, 1);
        assertEq(tokenBefore - token.balanceOf(user), 50 ether);
        _sell(_one(1, 100 ether, false), 100 ether, 1); // unused intermediate A is returned to payer.
        assertGt(assets[0].balanceOf(user), 0);
        assertEq(address(router).balance, 3 ether);
        assertEq(token.balanceOf(address(router)), 7 ether);
        assertEq(assets[0].balanceOf(address(router)), 9 ether);
        assertEq(token.allowance(address(router), address(venue)), 0);
    }

    function test_pairDonationIsNotCountedAsOurInput() public {
        assets[0].mint(address(pairs[0]), 100 ether);
        uint256 gross = uint256(2 ether) * 9975 * 100_000 ether / (1000 ether * 10000 + 2 ether * 9975);
        assertEq(_buy(_one(1, 1 ether, true), 1 ether, 1), gross - gross / 1000);
    }

    function test_nativeRejectionRollsBackSell() public {
        TagAITradeRouter.Leg[] memory legs = _one(1, 100 ether, false);
        uint256 beforeT = token.balanceOf(user);
        address target = address(new RejectNative());
        vm.prank(user);
        vm.expectRevert(TagAITradeRouter.NativeTransferFailed.selector);
        router.sell(address(token), 100 ether, legs, 1, block.timestamp, target);
        assertEq(token.balanceOf(user), beforeT);
        _empty();
    }

    function test_reentrancyBlocked() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        venue.attack(address(router), abi.encodeCall(router.buy, (address(token), legs, 1, block.timestamp, recipient)));
        _buy(legs, 1 ether, 1);
        assertTrue(venue.reentryBlocked());
        _empty();
    }

    function test_invalidRecipientAndDirectBnb() public {
        TagAITradeRouter.Leg[] memory legs = _one(0, 1 ether, true);
        vm.prank(user);
        vm.expectRevert(TagAITradeRouter.InvalidRecipient.selector);
        router.buy{value: 1 ether}(address(token), legs, 1, block.timestamp, address(router));
        vm.prank(user);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testFuzz_buySellConservesBalances(uint96 input, uint16 split) public {
        uint256 amount = bound(uint256(input), 0.001 ether, 5 ether);
        uint256 a = amount * bound(uint256(split), 1, 9999) / 10000;
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](2);
        legs[0] = _leg(0, a, true);
        legs[1] = _leg(2, amount - a, true);
        uint256 beforeT = token.balanceOf(recipient);
        uint256 out = _buy(legs, amount, 1);
        assertEq(token.balanceOf(recipient) - beforeT, out);
        _empty();
        vm.prank(recipient);
        token.approve(address(router), out);
        legs[0] = _leg(0, out / 2, false);
        legs[1] = _leg(2, out - out / 2, false);
        vm.prank(recipient);
        uint256 bnbOut = router.sell(address(token), out, legs, 1, block.timestamp, user);
        assertGt(bnbOut, 0);
        assertEq(token.balanceOf(recipient), beforeT);
        _empty();
    }
}
