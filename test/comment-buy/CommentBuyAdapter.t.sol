// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommentBuyAdapter} from "../../src/autopay/CommentBuyAdapter.sol";

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
        adapter = new CommentBuyAdapter(router, router);
        token = new AdapterTestToken();
        vm.warp(100);
        vm.deal(address(this), 1 ether);
    }
    function testDirectDeliveryAndMinimum() public {
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 100, block.timestamp + 60, "");
        assertEq(token.balanceOf(recipient), 100);
        assertEq(token.balanceOf(address(adapter)), 0);
        vm.expectRevert("MINIMUM_NOT_DELIVERED");
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 101, block.timestamp + 60, "");
        assertEq(token.balanceOf(recipient), 100);
    }
    function testPartialFillRefundRevertsInsteadOfLosingPrincipal() public {
        token.setPartial();
        vm.expectRevert("REFUND_FAILED");
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 1, block.timestamp + 60, "");
        assertEq(token.balanceOf(recipient), 0);
        assertEq(address(token).balance, 0);
    }
    function testListedTokenNeverFallsBackToBondingCurve() public {
        token.setListed();
        vm.expectRevert();
        adapter.buy{value: 0.01 ether}(address(token), recipient, address(0), 1, block.timestamp + 60, "");
        assertEq(token.balanceOf(recipient), 0);
    }
    function testNetPrincipalGrossUpDisclosesFeeAndRounding() public view {
        (uint256 gross, uint256 platform, uint256 subject, uint256 buyback) = adapter.quoteInput(address(token), 0.01 ether);
        assertGe(gross - platform - subject - buyback, 0.01 ether);
        assertLe(gross - platform - subject - buyback - 0.01 ether, 3);
        assertEq(platform, gross * 30 / 10000);
        assertEq(subject, gross * 30 / 10000);
    }
    function testFuzzFeeGrossUp(uint128 principal) public view {
        if (principal == 0) return;
        (uint256 gross, uint256 platform, uint256 subject, uint256 buyback) = adapter.quoteInput(address(token), principal);
        assertGe(gross - platform - subject - buyback, principal);
        assertLe(gross - platform - subject - buyback - principal, 3);
    }
}
