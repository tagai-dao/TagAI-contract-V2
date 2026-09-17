// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommentBuyAdapter} from "../../src/helper/CommentBuyAdapter.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";

contract AdapterTestToken is ERC20 {
    bool public listed;
    bool public partialFill;
    uint256 public createdAt = 0;
    function getBuyFeeRatios() external pure returns (uint256, uint256) { return (30, 30); }
    constructor() ERC20("T", "T") {}
    function setPartial() external { partialFill = true; }
    function setListed() external { listed = true; }
    function buyToken(uint256, address, uint16) external payable returns (uint256) {
        if (partialFill) {
            (bool ok,) = payable(msg.sender).call{value: 1}("");
            require(ok, "REFUND_FAILED");
        }
        _mint(msg.sender, 100);
        return 100;
    }
}
contract UnsupportedTestRouter {
    function getIPShare() external view returns (address) { return address(this); }
    function pump() external view returns (address) { return address(this); }
    function createdTokens(address) external pure returns (bool) { return true; }
    fallback() external { revert("UNSUPPORTED_ROUTE"); }
}
contract CommentBuyAdapterTest is Test {
    CommentBuyAdapter adapter;
    AdapterTestToken token;
    address recipient = address(123);
    function setUp() public {
        address router = address(new UnsupportedTestRouter());
        adapter = new CommentBuyAdapter(router, router, router);
        token = new AdapterTestToken();
        vm.warp(100);
        vm.deal(address(this), 1 ether);
    }
    function testAnyoneCanBuyWithOwnFunds() public {
        vm.deal(recipient, 1 ether);
        vm.deal(address(adapter), 0.5 ether);
        vm.prank(recipient);
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 1, block.timestamp + 60, 0, "");
        assertEq(token.balanceOf(recipient), 100);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(address(adapter).balance, 0.5 ether);
        assertEq(address(token).balance, 0.01 ether);
    }
    function testDirectDeliveryAndMinimum() public {
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 100, block.timestamp + 60, 0, "");
        assertEq(token.balanceOf(recipient), 100);
        assertEq(token.balanceOf(address(adapter)), 0);
        vm.expectRevert("MINIMUM_NOT_DELIVERED");
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 101, block.timestamp + 60, 0, "");
        assertEq(token.balanceOf(recipient), 100);
    }
    function testPartialFillRefundRevertsInsteadOfLosingPrincipal() public {
        token.setPartial();
        vm.expectRevert("REFUND_FAILED");
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 1, block.timestamp + 60, 0, "");
        assertEq(token.balanceOf(recipient), 0);
        assertEq(address(token).balance, 0);
    }
    function testInnerKindStillBuysWhenTokenReportsListed() public {
        token.setListed();
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 100, block.timestamp + 60, 0, "");
        assertEq(token.balanceOf(recipient), 100);
    }
    function testV13MainRejectsSplitRoutes() public {
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](2);
        legs[0] = TagAITradeRouter.Leg(0, 0.005 ether, 0, 1, bytes32(uint256(1)));
        legs[1] = TagAITradeRouter.Leg(1, 0.005 ether, 1, 1, bytes32(uint256(2)));
        vm.expectRevert("MAIN_POOL_ONLY");
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 1, block.timestamp + 60, 1, abi.encode(legs));
    }
    function testNetPrincipalGrossUpDisclosesFeeAndRounding() public view {
        (uint256 gross, uint256 platform, uint256 subject, uint256 buyback) = adapter.quoteInput(address(token), 0.01 ether, 0);
        assertGe(gross - platform - subject - buyback, 0.01 ether);
        assertLe(gross - platform - subject - buyback - 0.01 ether, 3);
        assertEq(platform, gross * 30 / 10000);
        assertEq(subject, gross * 30 / 10000);
    }
    function testFuzzFeeGrossUp(uint128 principal) public view {
        if (principal == 0) return;
        (uint256 gross, uint256 platform, uint256 subject, uint256 buyback) = adapter.quoteInput(address(token), principal, 0);
        assertGe(gross - platform - subject - buyback, principal);
        assertLe(gross - platform - subject - buyback - principal, 3);
    }
}
