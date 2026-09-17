// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommentBuyAdapter} from "../../src/helper/CommentBuyAdapter.sol";

// Deliberately no listed()/bondingCurve(): standard imported ERC20.
contract MarketERC20 is ERC20 {
    constructor() ERC20("Imported", "IMP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
contract MarketWrapperMock {
    address public feeAddress = address(55);
    function setFeeAddress(address a) external { feeAddress = a; }
    uint16 public tagaiRatio = 100;
    uint16 public sellsmanRatio = 100;
    uint16 public nutboxTokenRatio = 20;
    address public lastRecipient;
    address public lastSubject;
    bytes public lastSource;
    uint8 public lastType;
    bool public fail;
    function ipshare() external view returns (address) { return address(this); }
    function ipshareCreated(address a) external pure returns (bool) { return a == address(77); }
    function getImportedMarket(address) external pure returns (bool, address, address) { return (true, address(9), address(8)); }
    function resolveQuoteToken(address, uint8, bytes calldata) external pure returns (address) { return address(999); }
    function setFail() external { fail = true; }
    function buyToken(address token, uint8 kind, bytes calldata data, uint256, address recipient, uint256, address subject)
        external payable returns (uint256) {
        require(!fail, "SWAP_FAILED");
        lastRecipient = recipient; lastSubject = subject; lastSource = data; lastType = kind;
        MarketERC20(token).mint(recipient, 100);
        return 100;
    }
}
contract CommentMarketRoutesTest is Test {
    CommentBuyAdapter adapter;
    MarketWrapperMock wrapper;
    MarketERC20 imported;
    function setUp() public {
        wrapper = new MarketWrapperMock();
        adapter = new CommentBuyAdapter(address(wrapper), address(wrapper), address(wrapper));
        imported = new MarketERC20();
        vm.deal(address(this), 1 ether);
    }
    function plan(uint8 sourceType, bytes memory source) internal pure returns (bytes memory) {
        return abi.encode(sourceType, source);
    }
    function testExternalDexKeepsCallerSourceAndRecipient() public {
        for (uint8 kind; kind <= 3; ++kind) {
            if (kind == 2) continue; // RH / Uniswap V4 source intentionally unsupported
            bytes memory source = abi.encode(address(999), address(444), kind);
            adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 100,
                block.timestamp + 60, 2, plan(kind, source));
            assertEq(wrapper.lastSource(), source); assertEq(wrapper.lastType(), kind);
            assertEq(wrapper.lastRecipient(), address(123));
        }
        assertEq(imported.balanceOf(address(123)), 300);
        assertEq(adapter.outputFeeBps(address(imported), 2), 20);
        (uint256 gross, uint256 platform, uint256 subject,) = adapter.quoteInput(address(imported), 0.01 ether, 2);
        assertEq(platform, gross / 100); assertEq(subject, gross / 100);
        assertGe(gross - platform - subject, 0.01 ether);
    }
    function testInvalidPublisherCannotReceiveDirectCashInsteadOfIPShare() public {
        bytes memory route = plan(0, hex"01");
        vm.expectRevert("INVALID_SUBJECT");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(88), 1, block.timestamp + 60, 2, route);
        wrapper.setFeeAddress(address(77));
        assertFalse(adapter.isValidSubject(address(imported), address(77)));
    }
    function testRevertedSwapAndInsufficientOutputRollBackAllBalances() public {
        bytes memory route = plan(0, hex"01");
        vm.expectRevert("MINIMUM_NOT_DELIVERED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 101, block.timestamp + 60, 2, route);
        assertEq(imported.balanceOf(address(123)), 0); assertEq(address(wrapper).balance, 0);
        wrapper.setFail(); vm.expectRevert("SWAP_FAILED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 1, block.timestamp + 60, 2, route);
        assertEq(address(wrapper).balance, 0);
    }
    function testUniswapV4SourceRejected() public {
        vm.expectRevert("INVALID_MARKET");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 1, block.timestamp + 60, 2, plan(2, hex"01"));
    }
}
