// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";

contract BuybackTestAsset is ERC20 {
    constructor() ERC20("Asset", "A") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

contract BuybackTestPump {
    mapping(address => address) public indexTokenOf;

    function register(address token, address index) external {
        indexTokenOf[token] = index;
    }
}

contract BuybackTestToken {
    address public listingHook;
    address public indexToken;

    constructor(address hook, address index) {
        listingHook = hook;
        indexToken = index;
    }
}

contract BuybackTestVenue {
    BuybackTestAsset public settlementToken;
    uint256 public spendBps = 10000;
    uint256 public outputBps = 10000;
    bool public attemptReentry;
    bool public underdeliverSettlement;
    address public reentryTarget;
    bytes public reentryPayload;
    bytes public lastTradeData;

    constructor(BuybackTestAsset u) {
        settlementToken = u;
    }

    function setUnderdeliverSettlement() external {
        underdeliverSettlement = true;
    }

    function configure(uint256 spend, uint256 output) external {
        spendBps = spend;
        outputBps = output;
    }

    function reenter(address target, bytes calldata payload) external {
        attemptReentry = true;
        reentryTarget = target;
        reentryPayload = payload;
    }

    function swapExactInput(address, address, uint256 amount, uint256 minimum, address to, uint256)
        external
        payable
        returns (uint256)
    {
        require(msg.value == amount, "VALUE");
        require(amount * 100 >= minimum, "MIN_SETTLEMENT");
        settlementToken.mint(to, underdeliverSettlement ? 0 : amount * 100);
        return type(uint256).max; // Deliberately dishonest: adapter must use balance delta.
    }

    function buyExactSettlement(address index, uint256 amount, uint256, bytes calldata data, address to)
        external
        returns (uint256)
    {
        lastTradeData = data;
        if (attemptReentry) {
            (bool ok, bytes memory reason) = reentryTarget.call(reentryPayload);
            require(
                !ok
                    && keccak256(reason)
                        == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")),
                "REENTRY_NOT_BLOCKED"
            );
        }
        settlementToken.transferFrom(msg.sender, address(this), amount * spendBps / 10000);
        BuybackTestAsset(index).mint(to, amount * outputBps / 10000);
        return type(uint256).max; // Final output must also be balance-based.
    }
}

contract TagAIBuybackRouterTest is Test {
    BuybackTestPump pump;
    BuybackTestAsset u;
    BuybackTestAsset index;
    BuybackTestToken token;
    BuybackTestVenue venue;
    TagAIBuybackRouter adapter;
    address hook = address(0x1234);

    function setUp() public {
        u = new BuybackTestAsset();
        index = new BuybackTestAsset();
        pump = new BuybackTestPump();
        token = new BuybackTestToken(hook, address(index));
        pump.register(address(token), address(index));
        venue = new BuybackTestVenue(u);
        adapter = new TagAIBuybackRouter(address(pump), address(venue), address(venue), address(u));
        vm.deal(hook, 100 ether);
    }

    function _payload(uint256 minimum, uint256 deadline, bytes memory data, address recipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            TagAIBuybackRouter.buyIndexWithBnb, (address(token), address(index), minimum, deadline, data, recipient)
        );
    }

    function _buy(uint256 value) internal returns (uint256) {
        vm.prank(hook);
        return adapter.buyIndexWithBnb{value: value}(
            address(token), address(index), 1, block.timestamp, abi.encode(uint256(1), bytes("legs")), hook
        );
    }

    function testFuzz_donationsNotSpentOrCountedAndAllowanceCleared(uint96 raw) public {
        uint256 value = bound(uint256(raw), 1, 10 ether);
        u.mint(address(adapter), 5 ether);
        index.mint(hook, 7 ether);
        vm.deal(address(adapter), 3 ether);
        assertEq(_buy(value), value * 100);
        assertEq(index.balanceOf(hook), 7 ether + value * 100);
        assertEq(u.balanceOf(address(adapter)), 5 ether);
        assertEq(address(adapter).balance, 3 ether);
        assertEq(u.allowance(address(adapter), address(venue)), 0);
        assertEq(venue.lastTradeData(), bytes("legs"));
    }

    function test_unauthorizedCallerCannotTakeDonations() public {
        u.mint(address(adapter), 5 ether);
        vm.expectRevert(TagAIBuybackRouter.Unauthorized.selector);
        adapter.buyIndexWithBnb(address(token), address(index), 1, block.timestamp, "", hook);
        assertEq(u.balanceOf(address(adapter)), 5 ether);
    }

    function test_hookCannotRedirectOutput() public {
        vm.prank(hook);
        vm.expectRevert(TagAIBuybackRouter.Unauthorized.selector);
        adapter.buyIndexWithBnb(address(token), address(index), 1, block.timestamp, "", address(this));
    }

    function test_unregisteredTokenAndWrongIndexRejected() public {
        vm.prank(hook);
        vm.expectRevert(TagAIBuybackRouter.InvalidToken.selector);
        adapter.buyIndexWithBnb(address(token), address(u), 1, block.timestamp, "", hook);
        pump.register(address(token), address(0));
        vm.expectRevert(TagAIBuybackRouter.InvalidToken.selector);
        _buy(1 ether);
    }

    function test_expiredDeadline() public {
        vm.warp(100);
        vm.prank(hook);
        vm.expectRevert(TagAIBuybackRouter.DeadlineExpired.selector);
        adapter.buyIndexWithBnb{value: 1 ether}(address(token), address(index), 1, 99, "", hook);
    }

    function test_zeroValueOrMinimumRejected() public {
        vm.expectRevert(TagAIBuybackRouter.InvalidAmount.selector);
        _buy(0);
        vm.prank(hook);
        vm.expectRevert(TagAIBuybackRouter.InvalidAmount.selector);
        adapter.buyIndexWithBnb{value: 1}(
            address(token), address(index), 0, block.timestamp, abi.encode(uint256(1), bytes("")), hook
        );
        vm.prank(hook);
        vm.expectRevert(TagAIBuybackRouter.InvalidAmount.selector);
        adapter.buyIndexWithBnb{value: 1}(
            address(token), address(index), 1, block.timestamp, abi.encode(uint256(0), bytes("")), hook
        );
    }

    function test_malformedDataRejectedWithoutSpending() public {
        vm.prank(hook);
        vm.expectRevert();
        adapter.buyIndexWithBnb{value: 1 ether}(address(token), address(index), 1, block.timestamp, hex"0102", hook);
        assertEq(hook.balance, 100 ether);
    }

    function test_intermediateSlippageRollsBack() public {
        vm.prank(hook);
        vm.expectRevert("MIN_SETTLEMENT");
        adapter.buyIndexWithBnb{value: 1 ether}(
            address(token), address(index), 1, block.timestamp, abi.encode(uint256(101 ether), bytes("")), hook
        );
        assertEq(hook.balance, 100 ether);
        assertEq(u.totalSupply(), 0);
    }

    function test_intermediateActualBalanceRejectsDishonestVenue() public {
        venue.setUnderdeliverSettlement();
        vm.expectRevert(TagAIBuybackRouter.SettlementSlippage.selector);
        _buy(1 ether);
        assertEq(hook.balance, 100 ether);
        assertEq(index.totalSupply(), 0);
    }

    function test_finalActualBalanceProtectsAgainstFalseReturn() public {
        venue.configure(10000, 0);
        vm.expectRevert(TagAIBuybackRouter.IndexSlippage.selector);
        _buy(1 ether);
        assertEq(hook.balance, 100 ether);
        assertEq(u.totalSupply(), 0);
        assertEq(u.allowance(address(adapter), address(venue)), 0);
    }

    function test_partialSpendCannotLeaveAuthorizedFunds() public {
        venue.configure(9000, 10000);
        vm.expectRevert(TagAIBuybackRouter.UnexpectedSettlementBalance.selector);
        _buy(1 ether);
        assertEq(hook.balance, 100 ether);
        assertEq(index.totalSupply(), 0);
    }

    function test_nestedCallbackIsRejected() public {
        venue.reenter(address(adapter), _payload(1, block.timestamp, abi.encode(uint256(1), bytes("")), hook));
        assertEq(_buy(1 ether), 100 ether);
    }

    function test_constructorRejectsWrongSettlement() public {
        vm.expectRevert(TagAIBuybackRouter.InvalidConfiguration.selector);
        new TagAIBuybackRouter(address(pump), address(venue), address(venue), address(index));
    }
}
