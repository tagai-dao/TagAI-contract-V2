// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/pump/IPShare.sol";
import "../../src/pump/Pump.sol";
import "../../src/pump/Token.sol";
import "../../src/hook/TagAISwapHook.sol";
import "../mocks/MockCLPoolManager.sol";
import "../mocks/MockVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenTest
 * @notice Unit tests for Token contract — buyToken/sellToken without signature, receive() behavior, dust guards.
 */
contract TokenTest is Test {
    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    Pump public pump;
    TagAISwapHook public hook;

    Token public token; // freshly created token in setUp

    address public creator;
    address public buyer;
    address public feeRecipient;
    address public claimSigner;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        vm.deal(creator, 1000 ether);
        vm.deal(buyer, 1000 ether);
        vm.deal(address(this), 1000 ether);

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = _deployCommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(communityFactory);
        scf = _deploySocialCurationFactory(communityFactory, claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);

        mockPoolManager = new MockCLPoolManager();
        mockVault = new MockVault();

        ipshare = new IPShare(feeRecipient);
        pump = new Pump(address(ipshare), feeRecipient);
        pump.adminSetPoolManager(address(mockPoolManager));
        pump.adminSetVault(address(mockVault));

        hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));

        vm.warp(3600);

        // Create a token via Pump
        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("UNIT", bytes32(uint256(1)));
        token = Token(payable(tokenAddr));
        vm.stopPrank();
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "CF deploy failed");
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "SCF deploy failed");
        return d;
    }

    // ─── No signature required ───

    function test_buyToken_noSignatureRequired() public {
        // Skip anti-snipe window for predictable behavior
        vm.warp(block.timestamp + 16);

        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);
        assertGt(received, 0, "Buyer should receive tokens");
    }

    function test_sellToken_noSignatureRequired() public {
        // First buy some tokens
        vm.warp(block.timestamp + 16);
        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);

        // Now sell
        uint256 sellAmount = received / 2;
        vm.prank(buyer, buyer);
        token.sellToken(sellAmount, 0, creator, 0);

        // Verify buyer's balance decreased
        assertEq(IERC20(address(token)).balanceOf(buyer), received - sellAmount);
    }

    // ─── receive() behavior ───

    function test_receive_buysWhenNotListed() public {
        vm.warp(block.timestamp + 16);

        uint256 buyerBalanceBefore = IERC20(address(token)).balanceOf(buyer);

        vm.prank(buyer, buyer);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertTrue(success, "Direct ETH send should succeed when not listed");

        uint256 buyerBalanceAfter = IERC20(address(token)).balanceOf(buyer);
        assertGt(buyerBalanceAfter, buyerBalanceBefore, "Buyer should receive tokens via receive()");
    }

    function test_receive_revertsWhenListed() public {
        // Force-list the token by directly setting `listed` is not possible (not exposed),
        // so we skip until we can fill the bonding curve. For this unit test, document the behavior.
        // FullLifecycle.t.sol covers the listed=true path.
        vm.skip(true);
    }

    // ─── Total supply invariant ───

    function test_totalSupply_oneBillion() public {
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }

    function test_totalSupply_invariantAfterTrades() public {
        vm.warp(block.timestamp + 16);

        // Mirror the working pattern from test_sellToken_noSignatureRequired
        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);

        // Skip if listing was triggered (would prevent sell)
        if (token.listed()) {
            vm.skip(true);
            return;
        }

        // Sell half (proven to work)
        vm.prank(buyer, buyer);
        token.sellToken(received / 2, 0, creator, 0);

        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY, "Total supply must not change after trades");
    }

    // ─── Initialize protection ───

    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert();
        token.initialize(address(pump), creator, "AGAIN");
    }

    // ─── Dust guard ───

    function test_buyToken_revertsBelowDustGuard() public {
        vm.warp(block.timestamp + 16);

        // Very tiny ETH amount → sellsmanFee < 1e8 wei → DustIssue
        vm.prank(buyer, buyer);
        vm.expectRevert();
        token.buyToken{value: 1}(0, creator, 0); // 1 wei
    }

    // ─── setNutboxAddresses access control ───

    function test_setNutboxAddresses_onlyManager() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        token.setNutboxAddresses(makeAddr("comm"), makeAddr("pool"));
    }

    // ─── Anti-Snipe Window behavior ───

    function test_antiSnipeWindow_dynamicSellsmanFee() public {
        // Within window — feeRatio dynamic
        // Use first buy: at supply == 0, anti-snipe is NOT applied (per fee logic)
        // After first buy, anti-snipe kicks in
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.1 ether}(0, creator, 0); // first buy, normal fees

        // Next buy within window — sellsman fee should be elevated
        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        assertGt(sellsmanFee, 30, "Sellsman fee should be elevated within anti-snipe window");
        assertEq(platformFee, 30, "Platform fee should remain 30 BPS");
    }

    function test_antiSnipeWindow_normalFeesAfter15s() public {
        // First buy
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.1 ether}(0, creator, 0);

        // Skip window
        vm.warp(block.timestamp + 16);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        assertEq(platformFee, 30);
        assertEq(sellsmanFee, 30);
    }

    // ─── ipshareSubject ───

    function test_ipshareSubject_isCreator() public {
        assertEq(token.ipshareSubject(), creator);
    }

    function test_NUTBOX_ALLOCATION_isFifteenPercent() public {
        // 150M = 15% of 1B
        assertEq(token.NUTBOX_ALLOCATION(), 150_000_000 ether);
    }
}
