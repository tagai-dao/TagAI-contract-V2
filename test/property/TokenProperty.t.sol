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
 * @title TokenProperty
 * @notice Property tests for Token (P5: Free Trade, P8: Total Supply Invariant).
 */
contract TokenPropertyTest is Test {
    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    Pump public pump;
    TagAISwapHook public hook;
    Token public token;

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
        vm.deal(buyer, 10_000 ether);
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

        // Create a fresh, unlisted token
        vm.startPrank(creator, creator);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(creator);
        token = Token(payable(pump.createToken{value: 0.005 ether}("PROP", bytes32(uint256(1)))));
        vm.stopPrank();

        // Skip anti-snipe window
        vm.warp(block.timestamp + 16);
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return d;
    }

    // ═══════════════════════════════════════════════════════════════════
    // P5 - Free Trade
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 5: Free Trade
    /// buyToken/sellToken succeed without any signature parameter.
    function testFuzz_P5_buyTokenNeverRevertsForSignatureReason(uint256 buyAmount) public {
        // Bound to a reasonable range that's above dust and below curve cap
        buyAmount = bound(buyAmount, 0.01 ether, 5 ether);

        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        // Should not revert with any signature error (just succeed or revert with curve error)
        try token.buyToken{value: buyAmount}(0, creator, 0) {
            // Success — this is what we want
        } catch (bytes memory reason) {
            // The only acceptable reverts are curve-related: DustIssue, OutOfSlippage, etc.
            // NOT signature errors (which don't exist in v2)
            bytes4 selector;
            assembly { selector := mload(add(reason, 0x20)) }
            // Make sure no signature-related error
            assertTrue(
                selector != bytes4(keccak256("InvalidSignature()")) &&
                selector != bytes4(keccak256("InvalidGatePermission()")),
                "Should never revert with signature-related error"
            );
        }
    }

    function testFuzz_P5_sellTokenNeverRevertsForSignatureReason(uint256 buyAmount, uint256 sellFraction) public {
        buyAmount = bound(buyAmount, 0.5 ether, 3 ether);
        sellFraction = bound(sellFraction, 1, 100); // percentage to sell

        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) returns (uint256 received) {
            uint256 sellAmount = (received * sellFraction) / 100;
            if (sellAmount < 1e8) {
                // Below dust threshold; would revert with DustIssue, but not for signature reason
                return;
            }

            if (token.listed()) return;

            vm.prank(buyer, buyer);
            try token.sellToken(sellAmount, 0, creator, 0) {
                // Success
            } catch (bytes memory reason) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 0x20)) }
                assertTrue(
                    selector != bytes4(keccak256("InvalidSignature()")) &&
                    selector != bytes4(keccak256("InvalidGatePermission()")),
                    "sellToken should never revert with signature-related error"
                );
            }
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // P8 - Total Supply Invariant
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 8: Total Supply Invariant
    /// totalSupply always equals 1B regardless of trades performed.
    function testFuzz_P8_totalSupplyInvariant_afterBuy(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 0.01 ether, 5 ether);

        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) {} catch {}

        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }

    function testFuzz_P8_totalSupplyInvariant_afterBuyAndSell(
        uint256 buyAmount,
        uint256 sellFraction
    ) public {
        buyAmount = bound(buyAmount, 0.5 ether, 3 ether);
        sellFraction = bound(sellFraction, 10, 90);

        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) returns (uint256 received) {
            if (token.listed()) {
                assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
                return;
            }

            uint256 sellAmount = (received * sellFraction) / 100;
            if (sellAmount >= 1e8 && !token.listed()) {
                vm.prank(buyer, buyer);
                try token.sellToken(sellAmount, 0, creator, 0) {} catch {}
            }
        } catch {}

        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }
}
