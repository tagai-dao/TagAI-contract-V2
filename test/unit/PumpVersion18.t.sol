// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {Token} from "../../src/pump/Token.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {MockHandleRegistry} from "../helpers/HandleRegistryTestSetup.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

contract ReenteringCreationIPShare {
    Token private immutable _token;
    mapping(address => bool) public ipshareCreated;
    uint256 public blockedCallbacks;

    constructor(Token token_, address creator) {
        _token = token_;
        ipshareCreated[creator] = true;
    }

    function createShare(address subject) external payable {
        ipshareCreated[subject] = true;
        bytes[3] memory attempts = [
            abi.encodeCall(Token.buyToken, (0, address(0), 0)),
            abi.encodeCall(Token.sellToken, (1 ether, 0, address(0), 0)),
            bytes("")
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok, bytes memory reason) = address(_token).call(attempts[i]);
            require(
                !ok
                    && keccak256(reason)
                        == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")),
                "Creation callback bypassed guard"
            );
            ++blockedCallbacks;
        }
    }

    function valueCapture(address) external payable {}
}

contract PumpVersion18Test is PumpVersion13Test {
    using stdStorage for StdStorage;
    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = makeAddr("buyer");
        vm.deal(buyer, 1000 ether);
        vm.warp(token.createdAt() + 16);
    }

    function _buy(bool direct, address referral) internal returns (uint256 amount) {
        uint256 beforeBalance = token.balanceOf(buyer);
        vm.prank(buyer);
        if (direct) {
            (bool ok, bytes memory reason) = address(token).call{value: 0.01 ether}("");
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        } else {
            token.buyToken{value: 0.01 ether}(0, referral, 0);
        }
        amount = token.balanceOf(buyer) - beforeBalance;
    }

    function _assertCreated(address account) internal view {
        assertTrue(ipshare.ipshareCreated(account));
        // Self-referral and creator premine also buy back shares through valueCapture.
        assertGe(ipshare.ipshareSupply(account), 10 ether);
        assertEq(ipshare.totalStakedIPshare(account), 10 ether);
        assertEq(ipshare.ipshareBalance(account, account), 0);
        assertFalse(ipshare.ipshareCreated(address(pump)));
        assertFalse(ipshare.ipshareCreated(address(token)));
    }

    function _giveSellerTokens() internal returns (uint256 amount) {
        vm.prank(creator);
        amount = token.buyToken{value: 0.01 ether}(0, address(0), 0);
        vm.prank(creator);
        token.transfer(buyer, amount);
        assertFalse(ipshare.ipshareCreated(buyer), "transfer alone must not create IPShare");
    }

    function test_v18_versionAndSize() public view {
        assertEq(pump.VERSION(), 18);
        assertLe(pump.tokenImplementation().code.length, 24_576);
        assertLe(address(pump).code.length, 24_576);
    }

    function test_v18_ipshareDefaultCreationIsFreeAndStakesTenShares() public {
        assertEq(ipshare.createFee(), 0);
        assertEq(ipshare.getPrice(10 ether, 0), 0);
        uint256 beforeFees = feeReceiver.balance;
        vm.prank(buyer);
        ipshare.createShare(buyer);
        _assertCreated(buyer);
        assertEq(feeReceiver.balance, beforeFees);
        assertEq(address(ipshare).balance, 0);
    }

    function test_v18_buyCreatesForCallerBeforeTrading() public {
        assertFalse(ipshare.ipshareCreated(buyer));
        vm.expectCall(address(ipshare), abi.encodeCall(IIPShare.createShare, (buyer)), 1);
        uint256 beforeNative = buyer.balance;
        assertGt(_buy(false, address(0)), 0);
        _assertCreated(buyer);
        assertEq(beforeNative - buyer.balance, 0.01 ether);
        assertEq(token.innerMarketBought(buyer), token.balanceOf(buyer));
    }

    function test_v18_directBnbCreatesForCaller() public {
        vm.expectCall(address(ipshare), abi.encodeCall(IIPShare.createShare, (buyer)), 1);
        vm.recordLogs();
        assertGt(_buy(true, address(0)), 0);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 createTopic = keccak256("CreateIPshare(address,uint256,uint256)");
        uint256 creations;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(ipshare) && entries[i].topics[0] == createTopic) {
                ++creations;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), buyer);
            }
        }
        assertEq(creations, 1, "direct BNB buy must create only the buyer's IPShare");
        assertFalse(ipshare.ipshareCreated(address(0)));
        assertEq(ipshare.ipshareSupply(address(0)), 0);
        _assertCreated(buyer);
    }

    function test_v18_createsForCallerRatherThanTxOrigin() public {
        address origin = makeAddr("different-origin");
        vm.prank(buyer, origin);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        _assertCreated(buyer);
        assertFalse(ipshare.ipshareCreated(origin));
    }

    function test_v18_creationCallbackCannotReenterAnyTradingEntrypoint() public {
        ReenteringCreationIPShare callback = new ReenteringCreationIPShare(token, creator);
        pump.adminChangeIPShare(address(callback));
        assertGt(_buy(false, address(0)), 0);
        assertTrue(callback.ipshareCreated(buyer));
        assertEq(callback.blockedCallbacks(), 3);
    }

    function test_v18_ordinaryContractCannotBecomeIpShareSubject() public {
        _registerHandle(address(this));
        vm.deal(address(this), 1 ether);
        vm.expectRevert("Subject must be EOA");
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertFalse(ipshare.ipshareCreated(address(this)));
    }

    function test_v18_existingShareIsNotRecreatedOrCharged() public {
        ipshare.createShare(buyer);
        ipshare.adminSetCreateFee(0.01 ether);
        assertGt(_buy(false, creator), 0);
        assertGt(_buy(true, address(0)), 0);
        _assertCreated(buyer);
    }

    function test_v18_selfReferralWorksOnFirstBuy() public {
        assertGt(_buy(false, buyer), 0);
        _assertCreated(buyer);
        assertGt(address(ipshare).balance, 0);
    }

    function test_v18_sellCreatesForRecipientWithoutHandle() public {
        uint256 amount = _giveSellerTokens();
        MockHandleRegistry(HANDLE_REGISTRY).setHandle(buyer, "");
        uint256 beforeNative = buyer.balance;
        vm.prank(buyer);
        token.sellToken(amount, 0, address(0), 0);
        _assertCreated(buyer);
        assertEq(token.balanceOf(buyer), 0);
        assertGt(buyer.balance, beforeNative);
        assertEq(token.innerMarketBought(buyer), 0);
    }

    function test_v18_selfReferralWorksOnFirstSell() public {
        uint256 amount = _giveSellerTokens();
        vm.prank(buyer);
        token.sellToken(amount, 0, buyer, 0);
        _assertCreated(buyer);
    }

    function test_v18_premineChecksCreatorAndDoesNotCreatePumpShare() public {
        address fresh = makeAddr("v18-fresh-creator");
        vm.deal(fresh, 1 ether);
        vm.expectCall(address(ipshare), abi.encodeCall(IIPShare.createShare, (fresh)), 1);
        vm.prank(fresh, fresh);
        Token created = Token(payable(pump.createToken{value: 0.015 ether}("V18", bytes32(uint256(18)), _config())));
        _assertCreated(fresh);
        assertGt(created.balanceOf(fresh), 0);
        assertEq(created.innerMarketBought(fresh), created.balanceOf(fresh));
        assertEq(created.innerMarketBought(address(pump)), 0);
    }

    function test_v18_fillToCapCreatesForBothBuyEntrypoints() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            stdstore.target(address(token)).sig("bondingCurveSupply()").checked_write(645_000_000 ether);
            vm.prank(buyer);
            if (i == 0) {
                token.buyToken{value: 10 ether}(0, address(0), 0);
            } else {
                (bool ok,) = address(token).call{value: 10 ether}("");
                assertTrue(ok);
            }
            _assertCreated(buyer);
            assertTrue(token.listingPending());
            assertEq(token.innerMarketBought(buyer), 5_000_000 ether);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_v18_antiSnipeBuyStillCreatesShare() public {
        vm.warp(token.createdAt());
        uint256 received = _buy(false, address(0));
        _assertCreated(buyer);
        assertGt(token.bondingCurveSupply(), received);
    }

    function test_v18_buySlippageRollsBackCreationAndFunds() public {
        uint256 beforeNative = buyer.balance;
        uint256 beforeFees = feeReceiver.balance;
        vm.prank(buyer);
        vm.expectRevert(IToken.OutOfSlippage.selector);
        token.buyToken{value: 0.01 ether}(10_000_000 ether, creator, 1);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(buyer.balance, beforeNative);
        assertEq(feeReceiver.balance, beforeFees);
        assertEq(token.innerMarketBought(buyer), 0);
        assertEq(token.bondingCurveSupply(), 0);
    }

    function test_v18_sellSlippageRollsBackCreation() public {
        uint256 amount = _giveSellerTokens();
        uint256 supply = token.bondingCurveSupply();
        vm.prank(buyer);
        vm.expectRevert(IToken.OutOfSlippage.selector);
        token.sellToken(amount, 1 ether, creator, 1);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(token.balanceOf(buyer), amount);
        assertEq(token.bondingCurveSupply(), supply);
    }

    function test_v18_missingHandleStillRejectsBuyAndRollsBackCreation() public {
        MockHandleRegistry(HANDLE_REGISTRY).setHandle(buyer, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertFalse(ipshare.ipshareCreated(buyer));
    }

    function test_v18_unrelatedMissingReferralStillRejectsAndRollsBackCreation() public {
        vm.prank(buyer);
        vm.expectRevert(IToken.IPShareNotCreated.selector);
        token.buyToken{value: 0.01 ether}(0, makeAddr("unknown-referral"), 0);
        assertFalse(ipshare.ipshareCreated(buyer));
    }

    function test_v18_nonzeroCreationFeeRejectsBothBuyEntrypointsWithoutSpendingReserves() public {
        ipshare.adminSetCreateFee(0.001 ether);
        vm.deal(address(token), 1 ether);
        uint256 beforeNative = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert(IIPShare.InsufficientPay.selector);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(buyer);
        (bool ok, bytes memory reason) = address(token).call{value: 0.01 ether}("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IIPShare.InsufficientPay.selector));
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(address(token).balance, 1 ether);
        assertEq(buyer.balance, beforeNative);
        assertEq(token.bondingCurveSupply(), 0);
    }

    function test_v18_nonzeroCreationFeeRejectsSellWithoutSpendingReserves() public {
        uint256 amount = _giveSellerTokens();
        ipshare.adminSetCreateFee(0.001 ether);
        uint256 reserve = address(token).balance;
        vm.prank(buyer);
        vm.expectRevert(IIPShare.InsufficientPay.selector);
        token.sellToken(amount, 0, creator, 0);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(token.balanceOf(buyer), amount);
        assertEq(address(token).balance, reserve);
    }

    function test_v18_pausedIpshareRejectsCreationAtomically() public {
        ipshare.pause();
        vm.prank(buyer);
        vm.expectRevert("Pausable: paused");
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(token.bondingCurveSupply(), 0);
    }

    function test_v18_frozenMarketsRejectBeforeCreatingShare() public {
        stdstore.enable_packed_slots().target(address(token)).sig("listingPending()").checked_write(true);
        vm.prank(buyer);
        vm.expectRevert(IToken.TokenListingPending.selector);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(buyer);
        vm.expectRevert(IToken.TokenListingPending.selector);
        token.sellToken(1 ether, 0, creator, 0);
        assertFalse(ipshare.ipshareCreated(buyer));
    }
}
