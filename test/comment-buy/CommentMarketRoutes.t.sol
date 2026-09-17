// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommentBuyAdapter} from "../../src/autopay/CommentBuyAdapter.sol";

// Deliberately no listed()/bondingCurve(): standard imported ERC20.
contract MarketERC20 is ERC20 {
    constructor() ERC20("Imported", "IMP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
contract LegacyMarketERC20 is MarketERC20 {
    function listed() external pure returns (bool) { return true; }
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
    function changeFee() external { tagaiRatio = 200; }
    function setFail() external { fail = true; }
    function buyToken(address subject, uint256, address[] calldata path, address recipient, uint256, address shares) external payable {
        require(shares == address(this));
        lastRecipient = recipient; lastSubject = subject;
        MarketERC20(path[1]).mint(recipient, 100);
    }
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
    LegacyMarketERC20 legacy;
    function setUp() public {
        wrapper = new MarketWrapperMock();
        adapter = new CommentBuyAdapter(address(wrapper), address(wrapper));
        imported = new MarketERC20(); legacy = new LegacyMarketERC20();
        vm.deal(address(this), 1 ether);
    }
    function route(address token) internal view returns (bytes memory) {
        (,,bytes32 hash) = adapter.routeContext(token); return abi.encode(hash);
    }
    function testLegacyListedBuysUseWrapperAndCorrectRegistry() public {
        adapter.configureLegacy(address(legacy), address(wrapper), address(wrapper), address(imported));
        adapter.buy{value: 0.01 ether}(address(legacy), address(123), address(77), 100, block.timestamp + 60, route(address(legacy)));
        assertEq(legacy.balanceOf(address(123)), 100);
        assertEq(wrapper.lastSubject(), address(77));
        (uint256 gross, uint256 platform, uint256 subject,) = adapter.quoteInput(address(legacy), 0.01 ether);
        assertEq(platform, gross / 100); assertEq(subject, gross / 100);
        assertGe(gross - platform - subject, 0.01 ether);
    }
    function testImportedV2V3V4KeepsNonNativePoolSourceAndRecipient() public {
        for (uint8 kind; kind <= 3; ++kind) {
            if (kind == 2) continue; // RH source intentionally unsupported in BSC release
            bytes memory source = abi.encode(address(999), address(444), kind);
            adapter.configureImported(address(imported), address(wrapper), kind, source);
            adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 100,
                block.timestamp + 60, route(address(imported)));
            assertEq(wrapper.lastSource(), source); assertEq(wrapper.lastType(), kind);
            assertEq(wrapper.lastRecipient(), address(123));
        }
        assertEq(imported.balanceOf(address(123)), 300);
        assertEq(adapter.outputFeeBps(address(imported)), 20);
    }
    function testSourceChangeInvalidatesOldQuoteEvenWhenOutputStillEnough() public {
        adapter.configureImported(address(imported), address(wrapper), 0, hex"01");
        bytes memory oldRoute = route(address(imported));
        adapter.configureImported(address(imported), address(wrapper), 0, hex"02");
        vm.expectRevert("ROUTE_CHANGED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 1, block.timestamp + 60, oldRoute);
    }
    function testWrapperFeeChangeInvalidatesOldQuote() public {
        adapter.configureImported(address(imported), address(wrapper), 0, hex"01");
        bytes memory oldRoute = route(address(imported)); wrapper.changeFee();
        vm.expectRevert("ROUTE_CHANGED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 1, block.timestamp + 60, oldRoute);
    }
    function testInvalidPublisherCannotReceiveDirectCashInsteadOfIPShare() public {
        adapter.configureImported(address(imported), address(wrapper), 0, hex"01");
        bytes memory plan = route(address(imported));
        vm.expectRevert("INVALID_SUBJECT");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(88), 1, block.timestamp + 60, plan);
        wrapper.setFeeAddress(address(77));
        assertFalse(adapter.isValidSubject(address(imported), address(77)));
    }
    function testRevertedSwapAndInsufficientOutputRollBackAllBalances() public {
        adapter.configureImported(address(imported), address(wrapper), 0, hex"01");
        bytes memory plan = route(address(imported));
        vm.expectRevert("MINIMUM_NOT_DELIVERED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 101, block.timestamp + 60, plan);
        assertEq(imported.balanceOf(address(123)), 0); assertEq(address(wrapper).balance, 0);
        wrapper.setFail(); vm.expectRevert("SWAP_FAILED");
        adapter.buy{value: 0.01 ether}(address(imported), address(123), address(77), 1, block.timestamp + 60, plan);
        assertEq(address(wrapper).balance, 0);
    }
    function testOnlyAdminCanRegisterAndRhSourceRejected() public {
        vm.prank(address(99)); vm.expectRevert("ADMIN_ONLY");
        adapter.configureImported(address(imported), address(wrapper), 0, hex"01");
        vm.expectRevert("INVALID_MARKET");
        adapter.configureImported(address(imported), address(wrapper), 2, hex"01");
    }
}
