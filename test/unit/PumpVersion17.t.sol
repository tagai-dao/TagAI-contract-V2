// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {MockHandleRegistry} from "../helpers/HandleRegistryTestSetup.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";

/// @dev Also runs the inherited listing, pool-tax, buyback and reward regressions.
contract PumpVersion17Test is PumpVersion13Test {
    using stdStorage for StdStorage;
    address internal buyer;

    function setUp() public override {
        super.setUp();
        buyer = makeAddr("buyer");
        vm.deal(buyer, 1000 ether);
        vm.warp(block.timestamp + 16);
    }

    function _setHandle(address account, string memory handle) internal {
        MockHandleRegistry(HANDLE_REGISTRY).setHandle(account, handle);
    }

    function test_v17_listingBudgetConstantMatchesOriginalMath() public {
        uint256 nativeSeed = SqrtPriceMath.getAmount0Delta(
            225060284636549774439465527763777, TickMath.getSqrtRatioAtTick(191940), 52804626975085827442929, true
        );
        assertEq(nativeSeed, 15 ether);
        vm.deal(address(token), nativeSeed + 5 ether);
        assertEq(token.componentListingNativeBudget(), 5 ether);
        vm.deal(address(token), nativeSeed - 1);
        assertEq(token.componentListingNativeBudget(), 0);
    }

    function test_v17_versionAndDeployableSize() public view {
        assertEq(pump.VERSION(), 18);
        assertLe(pump.tokenImplementation().code.length, 24_576, "Token must fit EIP-170");
        assertLe(address(pump).code.length, 24_576, "Pump must fit EIP-170");
    }

    function _quotedBuy(address account, uint256 amount, bool direct) internal {
        vm.mockCall(address(pump), abi.encodeWithSelector(pump.getBuyAmountByValue.selector), abi.encode(amount));
        vm.prank(account);
        if (direct) {
            (bool ok, bytes memory reason) = address(token).call{value: 0.1 ether}("");
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        } else {
            assertEq(token.buyToken{value: 0.1 ether}(0, creator, 0), amount);
        }
        vm.clearMockedCalls();
    }

    function _expectQuotaFailure(address account, uint256 amount, bool direct) internal {
        vm.mockCall(address(pump), abi.encodeWithSelector(pump.getBuyAmountByValue.selector), abi.encode(amount));
        uint256 nativeBefore = account.balance;
        uint256 reserveBefore = address(token).balance;
        uint256 supplyBefore = token.bondingCurveSupply();
        uint256 boughtBefore = token.innerMarketBought(account);
        vm.prank(account);
        bytes memory errorData = abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, account);
        if (direct) {
            (bool ok, bytes memory reason) = address(token).call{value: 0.1 ether}("");
            assertFalse(ok);
            assertEq(reason, errorData);
        } else {
            vm.expectRevert(errorData);
            token.buyToken{value: 0.1 ether}(0, creator, 0);
        }
        vm.clearMockedCalls();
        assertEq(account.balance, nativeBefore);
        assertEq(address(token).balance, reserveBefore);
        assertEq(token.bondingCurveSupply(), supplyBefore);
        assertEq(token.innerMarketBought(account), boughtBefore);
    }

    function test_v17_exactLimitThenTransfer400kCannotBuyTenMore() public {
        _quotedBuy(buyer, 10_000_000 ether, false);
        address recipient = makeAddr("recipient");
        _registerHandle(recipient);
        vm.prank(buyer);
        token.transfer(recipient, 400_000 ether);
        assertEq(token.balanceOf(buyer), 9_600_000 ether);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
        assertEq(token.innerMarketBought(recipient), 0);
        _expectQuotaFailure(buyer, 10 ether, false);
        _expectQuotaFailure(buyer, 1, true);
    }

    function test_v17_multipleBuysAndBothEntrypointsShareOneQuota() public {
        _quotedBuy(buyer, 3_000_000 ether, false);
        _quotedBuy(buyer, 4_000_000 ether, true);
        assertEq(token.innerMarketBought(buyer), 7_000_000 ether);
        _expectQuotaFailure(buyer, 3_000_000 ether + 1, false);
        _quotedBuy(buyer, 3_000_000 ether, true);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
        _expectQuotaFailure(buyer, 1, false);
    }

    function test_v17_sellingAllDoesNotRestoreQuota() public {
        _quotedBuy(buyer, 10_000_000 ether, false);
        vm.prank(buyer);
        token.sellToken(10_000_000 ether, 0, creator, 0);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
        _expectQuotaFailure(buyer, 1, false);
    }

    function test_v17_receivedTokensDoNotConsumeRecipientBuyQuota() public {
        _quotedBuy(buyer, 10_000_000 ether, false);
        vm.prank(buyer);
        token.transfer(creator, 10_000_000 ether);
        _quotedBuy(creator, 10_000_000 ether, false);
        assertEq(token.balanceOf(creator), 20_000_000 ether);
        assertEq(token.innerMarketBought(creator), 10_000_000 ether);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
    }

    function test_v17_transferFromDoesNotMovePurchaseHistory() public {
        _quotedBuy(buyer, 10_000_000 ether, false);
        vm.prank(buyer);
        token.approve(address(this), type(uint256).max);
        token.transferFrom(buyer, creator, 10_000_000 ether);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
        assertEq(token.innerMarketBought(creator), 0);
        _expectQuotaFailure(buyer, 10 ether, false);
    }

    function test_v17_contractRecipientsAndContractSendersRemainRestricted() public {
        _quotedBuy(buyer, 1_000_000 ether, false);
        address[4] memory recipients = [address(router), address(vault), address(factory), address(0)];
        for (uint256 i; i < recipients.length; ++i) {
            vm.prank(buyer);
            vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
            token.transfer(recipients[i], 1 ether);
        }
        vm.prank(buyer);
        token.approve(address(this), 1 ether);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(buyer, address(router), 1 ether);
        assertEq(token.allowance(buyer, address(this)), 1 ether);
        _registerHandle(address(this));
        // V18 auto-creation rejects ordinary contracts as IPShare subjects. Seed this
        // balance directly to keep testing the independent contract-sender transfer guard.
        deal(address(token), address(this), 1_000_000 ether);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(creator, 1 ether);
    }

    function test_v17_componentPairCannotReceiveBeforeListing() public {
        _quotedBuy(buyer, 1_000_000 ether, false);
        (,, address pair) = token.componentAt(0);
        vm.prank(buyer);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(pair, 1 ether);
    }

    function test_v17_premineCountsAgainstCreatorAndRejectsOversizeAtomically() public {
        _setHandle(creator, "");
        vm.prank(creator, creator);
        Token created =
            Token(payable(pump.createToken{value: 0.015 ether}("QUOTA17", bytes32(uint256(117)), _config())));
        uint256 premine = created.balanceOf(creator);
        assertGt(premine, 0);
        assertEq(created.innerMarketBought(creator), premine);
        assertEq(created.innerMarketBought(address(pump)), 0);
        _registerHandle(creator);
        vm.warp(block.timestamp + 16);
        vm.mockCall(
            address(pump), abi.encodeWithSelector(pump.getBuyAmountByValue.selector), abi.encode(10_000_000 ether)
        );
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, creator));
        created.buyToken{value: 0.1 ether}(0, creator, 0);
        vm.clearMockedCalls();
        uint256 totalBefore = pump.totalTokens();
        uint256 balanceBefore = creator.balance;
        vm.prank(creator, creator);
        vm.expectRevert(IPump.PreMineTokenFail.selector);
        pump.createToken{value: 1.005 ether}("OVER17", bytes32(uint256(118)), _config());
        assertFalse(pump.createdTicks("OVER17"));
        assertEq(pump.totalTokens(), totalBefore);
        assertEq(creator.balance, balanceBefore);
    }

    function test_v17_antiSnipeChargesOnlyBuyerTokensAndRollbackKeepsQuota() public {
        vm.warp(token.createdAt());
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertEq(token.innerMarketBought(buyer), received);
        assertGt(token.bondingCurveSupply(), received, "protocol reward injection is separate");
        vm.warp(token.createdAt() + 16);
        vm.prank(buyer);
        vm.expectRevert(IToken.OutOfSlippage.selector);
        token.buyToken{value: 0.01 ether}(10_000_000 ether, creator, 1);
        assertEq(token.innerMarketBought(buyer), received);
    }

    function test_v17_fillToCapChargesActualOutputForBothEntrypoints() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            // Isolate the final-buy branch; complete real multi-wallet graduation is inherited above.
            stdstore.target(address(token)).sig("bondingCurveSupply()").checked_write(645_000_000 ether);
            vm.prank(buyer);
            if (i == 0) {
                assertEq(token.buyToken{value: 100 ether}(0, creator, 0), 5_000_000 ether);
            } else {
                (bool ok,) = address(token).call{value: 100 ether}("");
                assertTrue(ok);
            }
            assertEq(token.innerMarketBought(buyer), 5_000_000 ether);
            assertEq(token.balanceOf(buyer), 5_000_000 ether);
            assertTrue(token.listingPending());
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_v17_fillToCapRejectsWhenActualOutputExceedsRemainingQuota() public {
        _quotedBuy(buyer, 6_000_000 ether, false);
        stdstore.target(address(token)).sig("bondingCurveSupply()").checked_write(645_000_000 ether);
        for (uint256 i; i < 2; ++i) {
            vm.prank(buyer);
            if (i == 0) {
                vm.expectRevert(abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, buyer));
                token.buyToken{value: 100 ether}(0, creator, 0);
            } else {
                (bool ok, bytes memory reason) = address(token).call{value: 100 ether}("");
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, buyer));
            }
            assertEq(token.innerMarketBought(buyer), 6_000_000 ether);
            assertFalse(token.listingPending());
        }
    }

    function testFuzz_v17_cumulativeQuotaIsIndependentOfTransfers(uint256 first, uint256 second) public {
        first = bound(first, 1, 10_000_000 ether);
        second = bound(second, 1, 10_000_000 ether);
        _quotedBuy(buyer, first, false);
        vm.prank(buyer);
        token.transfer(creator, first);
        if (first + second > token.INNER_MARKET_BUY_LIMIT()) {
            _expectQuotaFailure(buyer, second, true);
        } else {
            _quotedBuy(buyer, second, true);
            assertEq(token.innerMarketBought(buyer), first + second);
        }
    }

    function test_v17_registeredBuyerCanBuy() public {
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (buyer)));
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertGt(received, 0);
        assertEq(token.balanceOf(buyer), received);
    }

    function test_v17_unregisteredBuyerCannotBorrowCreatorOrOriginEligibility() public {
        _setHandle(buyer, "");
        uint256 reserveBefore = address(token).balance;
        uint256 supplyBefore = token.bondingCurveSupply();
        vm.prank(buyer, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertEq(address(token).balance, reserveBefore);
        assertEq(token.bondingCurveSupply(), supplyBefore);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(buyer.balance, 1000 ether);
    }

    function test_v17_directBNBBuyRequiresHandle() public {
        _setHandle(buyer, "");
        vm.prank(buyer);
        (bool success, bytes memory reason) = address(token).call{value: 0.01 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        assertEq(token.balanceOf(buyer), 0);
        _registerHandle(buyer);
        vm.prank(buyer);
        (success,) = address(token).call{value: 0.01 ether}("");
        assertTrue(success);
        assertGt(token.balanceOf(buyer), 0);
    }

    function test_v17_creatorFirstBuyAfterCreationRequiresHandleWithoutPremine() public {
        _setHandle(creator, "");
        uint256 createFee = pump.createFee();
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: createFee}("NOPRE15", bytes32(uint256(17)), _config())));
        assertEq(created.bondingCurveSupply(), 0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        created.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(creator, creator);
        (bool success, bytes memory reason) = address(created).call{value: 0.01 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        assertEq(created.bondingCurveSupply(), 0);
        _registerHandle(creator);
        vm.prank(creator, creator);
        assertGt(created.buyToken{value: 0.01 ether}(0, creator, 0), 0);
    }

    function test_v17_creatorLaterBuysRequireHandleAfterExemptPremine() public {
        _setHandle(creator, "");
        assertEq(bytes(IHandleRegistry(HANDLE_REGISTRY).handleOf(creator)).length, 0);
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: 0.015 ether}("LATER15", bytes32(uint256(18)), _config())));
        uint256 premine = created.balanceOf(creator);
        uint256 reserveBefore = address(created).balance;
        assertGt(premine, 0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        created.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(creator, creator);
        (bool success, bytes memory reason) = address(created).call{value: 0.01 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        assertEq(created.balanceOf(creator), premine);
        assertEq(address(created).balance, reserveBefore);
        _registerHandle(creator);
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        assertGt(created.buyToken{value: 0.01 ether}(0, creator, 0), 0);
        vm.prank(creator, creator);
        (success,) = address(created).call{value: 0.01 ether}("");
        assertTrue(success);
    }

    function test_v17_creationAndPremineDoNotRequireHandle() public {
        _setHandle(creator, "");
        assertEq(bytes(IHandleRegistry(HANDLE_REGISTRY).handleOf(creator)).length, 0);
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: 0.015 ether}("PRE15", bytes32(uint256(15)), _config())));
        assertGt(created.balanceOf(creator), 0);
        assertEq(created.balanceOf(address(pump)), 0);
    }

    function test_v17_optionalPoolOverloadPremineDoesNotRequireHandle() public {
        _setHandle(creator, "");
        vm.prank(creator, creator);
        Token created = Token(
            payable(pump.createToken{value: 0.015 ether}(
                    "OPT15", bytes32(uint256(16)), _config(), new IPump.OptionalPoolConfig[](0)
                ))
        );
        assertGt(created.balanceOf(creator), 0);
    }

    function test_v17_sellingDoesNotRequireHandle() public {
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        _setHandle(buyer, "");
        uint256 nativeBefore = buyer.balance;
        vm.prank(buyer);
        token.sellToken(received, 0, creator, 0);
        assertEq(token.balanceOf(buyer), 0);
        assertGt(buyer.balance, nativeBefore);
    }

    function test_v17_innerMarketTransferToAnotherWalletIsAllowed() public {
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        address recipient = makeAddr("inner-market-recipient");
        _registerHandle(recipient);

        vm.prank(buyer);
        token.transfer(recipient, received);

        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(recipient), received);
    }

    function test_v17_innerMarketTransferFromToAnotherWalletSpendsAllowance() public {
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        address spender = makeAddr("inner-market-spender");
        address recipient = makeAddr("inner-market-recipient");
        _registerHandle(recipient);

        vm.prank(buyer);
        token.approve(spender, received);
        vm.prank(spender);
        token.transferFrom(buyer, recipient, received);

        assertEq(token.allowance(buyer, spender), 0);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(recipient), received);
    }

    function test_v17_transferReadsBothHandlesDirectlyWithoutMulticall() public {
        _quotedBuy(buyer, 1_000_000 ether, false);
        vm.etch(0xcA11bde05977b3631167028862bE2a173976CA11, hex"");
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (buyer)));
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (creator)));
        vm.prank(buyer);
        token.transfer(creator, 1 ether);
        assertEq(token.balanceOf(creator), 1 ether);
    }

    function test_v17_transferAndTransferFromRequireBothHandlesWithoutChangingState() public {
        _quotedBuy(buyer, 1_000_000 ether, false);
        vm.prank(buyer);
        token.approve(address(this), 1 ether);
        uint256 quota = token.innerMarketBought(buyer);
        for (uint256 missing; missing < 2; ++missing) {
            address account = missing == 0 ? buyer : creator;
            _setHandle(account, "");
            vm.prank(buyer, creator);
            vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, account));
            token.transfer(creator, 1 ether);
            // Registered operator and tx.origin cannot supply the missing participant's qualification.
            vm.prank(address(this), creator);
            vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, account));
            token.transferFrom(buyer, creator, 1 ether);
            assertEq(token.allowance(buyer, address(this)), 1 ether);
            assertEq(token.balanceOf(buyer), 1_000_000 ether);
            assertEq(token.balanceOf(creator), 0);
            assertEq(token.innerMarketBought(buyer), quota);
            _registerHandle(account);
        }
        _setHandle(address(this), "");
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (buyer)));
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (creator)));
        token.transferFrom(buyer, creator, 1 ether);
        assertEq(token.balanceOf(creator), 1 ether);
        assertEq(token.allowance(buyer, address(this)), 0);
    }

    function test_v17_transferRejectsRegistryFailureOrMalformedDataWithoutChangingState() public {
        _quotedBuy(buyer, 1_000_000 ether, false);
        vm.prank(buyer);
        token.approve(address(this), 1 ether);
        for (uint256 i; i < 2; ++i) {
            address account = i == 0 ? buyer : creator;
            bytes memory input = abi.encodeCall(IHandleRegistry.handleOf, (account));
            bytes memory reason = abi.encodeWithSignature("Error(string)", "registry unavailable");
            vm.mockCallRevert(HANDLE_REGISTRY, input, reason);
            vm.expectRevert(reason);
            token.transferFrom(buyer, creator, 1 ether);
            vm.clearMockedCalls();
            vm.mockCall(HANDLE_REGISTRY, input, hex"");
            vm.expectRevert();
            token.transferFrom(buyer, creator, 1 ether);
            vm.clearMockedCalls();
            assertEq(token.allowance(buyer, address(this)), 1 ether);
            assertEq(token.balanceOf(buyer), 1_000_000 ether);
            assertEq(token.balanceOf(creator), 0);
            assertEq(token.innerMarketBought(buyer), 1_000_000 ether);
        }
    }

    function test_v17_pendingListingTransfersStillRequireBothHandles() public {
        _fillToListingPending();
        _setHandle(buyer, "");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.transfer(buyer, 1 ether);
        _registerHandle(buyer);
        vm.prank(creator);
        token.transfer(buyer, 1 ether);
        assertEq(token.balanceOf(buyer), 1 ether);
    }

    function test_v17_innerMarketTransfersWithTokenContractRemainAvailable() public {
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 0.01 ether}(0, creator, 0);
        uint256 contractBalanceBefore = token.balanceOf(address(token));

        vm.prank(buyer);
        token.transfer(address(token), received / 4);
        assertEq(token.balanceOf(address(token)), contractBalanceBefore + received / 4);
    }

    function test_v17_antiSnipeBuyAlsoRequiresHandle() public {
        vm.warp(token.createdAt());
        _setHandle(buyer, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 0.01 ether}(0, creator, 0);
    }

    function test_v17_fillToCapCannotBypassGate() public {
        _setHandle(buyer, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 100 ether}(0, creator, 0);
        _registerHandle(buyer);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, buyer));
        token.buyToken{value: 100 ether}(0, creator, 0);
        assertFalse(token.listingPending());
    }

    function test_v17_postListingTransfersDoNotRequireHandle() public {
        _list();
        _setHandle(buyer, "");
        vm.prank(creator);
        token.transfer(buyer, 100 ether);
        vm.prank(buyer);
        token.approve(creator, 100 ether);
        address recipient = makeAddr("unregistered-recipient");
        vm.prank(creator);
        token.transferFrom(buyer, recipient, 100 ether);
        assertEq(token.balanceOf(recipient), 100 ether);
    }

    function test_v17_anyNonemptyStringIsAccepted() public {
        _setHandle(buyer, "any string: no format validation!");
        vm.prank(buyer);
        assertGt(token.buyToken{value: 0.01 ether}(0, creator, 0), 0);
    }
}
