// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {Pump19} from "../../src/pump/Pump19.sol";
import {Token19} from "../../src/pump/Token19.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

contract NutboxSender19 {
    function send(Token token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function approveToken(Token token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function sendFrom(Token token, address from, address to, uint256 amount) external {
        token.transferFrom(from, to, amount);
    }
}

/// @dev Run the actual V19 constructor, clones, community, listing, tax and reward regressions.
contract PumpVersion19Test is PumpVersion13Test {
    using stdStorage for StdStorage;
    address internal buyer;
    mapping(address => address[]) private _curveBuyers;

    function _deployPump() internal override returns (Pump) {
        return Pump(payable(address(new Pump19(address(ipshare), feeReceiver, new address[](0), address(0)))));
    }

    function setUp() public override {
        super.setUp();
        buyer = makeAddr("v19-unregistered-buyer");
        vm.deal(buyer, 1000 ether);
        vm.warp(token.createdAt() + 16);
        // No registry exists: neither purchases nor failed transfers may depend on handleOf.
        vm.etch(HANDLE_REGISTRY, hex"");
    }

    function _buy(address account, bool direct) internal returns (uint256 received) {
        uint256 beforeBalance = token.balanceOf(account);
        vm.prank(account, account);
        if (direct) {
            (bool ok, bytes memory reason) = address(token).call{value: 0.01 ether}("");
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        } else {
            token.buyToken{value: 0.01 ether}(0, address(0), 0);
        }
        received = token.balanceOf(account) - beforeBalance;
    }

    /// @dev Holdings stay with real buyers until listing; never bypass the transfer restriction to fill.
    function _fillInnerMarket(Token target, address recipient) internal override {
        vm.warp(target.createdAt() + 16);
        uint256 cap = 650_000_000 ether;
        if (target.bondingCurveSupply() == 0) {
            vm.deal(recipient, 1000 ether);
            vm.prank(recipient, recipient);
            target.buyToken{value: 0.01 ether}(0, address(0), 0);
        }
        while (target.bondingCurveSupply() < cap) {
            uint256 supply = target.bondingCurveSupply();
            address account = address(uint160(uint256(keccak256(abi.encode(address(target), supply, "v19-buyer")))));
            _curveBuyers[address(target)].push(account);
            vm.deal(account, 1000 ether);
            uint256 price = target.bondingCurve().getPrice(supply, 9_000_000 ether);
            (uint256 platform, uint256 salesman) = target.getBuyFeeRatios();
            uint256 denom = 10_000 - platform - salesman;
            uint256 value = cap - supply <= 9_000_000 ether ? 100 ether : (price * 10_000 + denom - 1) / denom;
            vm.prank(account, account);
            target.buyToken{value: value}(0, address(0), 0);
            assertLe(target.innerMarketBought(account), target.INNER_MARKET_BUY_LIMIT());
        }
        assertTrue(target.listingPending());
    }

    function _list() internal override returns (uint256 nativeSeed, uint256 tokenSeed, uint256 raisedNative) {
        (nativeSeed, tokenSeed, raisedNative) = super._list();
        for (uint256 i; i < _curveBuyers[address(token)].length; ++i) {
            address account = _curveBuyers[address(token)][i];
            uint256 amount = token.balanceOf(account);
            vm.prank(account);
            token.transfer(creator, amount);
        }
    }

    function test_v19_cannotReuseTheOldV18TokenTemplate() public {
        Token old = new Token();
        vm.expectRevert(IPump.InvalidTokenImplementation.selector);
        new Pump19(address(ipshare), feeReceiver, new address[](0), address(old));
    }

    function test_v19_calculatorStillNeedsAllowanceAndCannotRedirectTransfers() public {
        vm.warp(token.createdAt());
        _buy(buyer, false);
        address calculator = ICommunity(token.nutboxCommunity()).rewardCalculator();
        address community = token.nutboxCommunity();
        assertEq(token.allowance(address(token), calculator), 0);
        vm.prank(calculator);
        vm.expectRevert(bytes4(keccak256("InsufficientAllowance()")));
        token.transferFrom(address(token), community, 1);
        vm.prank(calculator);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(buyer, creator, 1);
    }

    function test_v19_manualNutboxInjectionPreservesCurveAndQuota() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(ICommunity(community).rewardCalculator());
        uint256 supply = token.bondingCurveSupply();
        uint256 quota = token.innerMarketBought(buyer);
        uint256 reserve = address(token).balance;
        vm.startPrank(buyer);
        token.approve(address(calculator), received);
        calculator.inject(community, received);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(community), received);
        assertEq(calculator.totalInjected(community), received);
        assertEq(token.allowance(buyer, address(calculator)), 0);
        assertEq(token.bondingCurveSupply(), supply);
        assertEq(token.innerMarketBought(buyer), quota);
        assertEq(address(token).balance, reserve);
    }

    function test_v19_manualInjectionRequiresAllowanceAndRollsBackAccounting() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(ICommunity(community).rewardCalculator());
        vm.prank(buyer);
        vm.expectRevert(bytes4(keccak256("InsufficientAllowance()")));
        calculator.inject(community, received);
        assertEq(token.balanceOf(buyer), received);
        assertEq(token.balanceOf(community), 0);
        assertEq(calculator.totalInjected(community), 0);
    }

    function testFuzz_v19_communityRecipientAllowsAnySenderAtAnyTime(uint32 elapsed, bool contractSender) public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(ICommunity(community).rewardCalculator());
        uint256 supply = token.bondingCurveSupply();
        uint256 quota = token.innerMarketBought(buyer);
        uint256 reserve = address(token).balance;
        vm.warp(token.createdAt() + bound(elapsed, 0, 86400));
        if (contractSender) {
            // Model a funded wallet acquiring code; transferring into a contract remains prohibited.
            vm.etch(buyer, type(NutboxSender19).runtimeCode);
            NutboxSender19(buyer).send(token, community, received);
        } else {
            vm.prank(buyer);
            token.transfer(community, received);
        }
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(community), received);
        assertEq(token.innerMarketBought(buyer), quota);
        assertEq(token.bondingCurveSupply(), supply);
        assertEq(address(token).balance, reserve);
        // Plain ERC20 deposits are allowed, but do not schedule calculator distributions.
        assertEq(calculator.totalInjected(community), 0);
    }

    function test_v19_walletAndContractSpendersCanDepositWithAllowanceBeforeAndAfter15Seconds() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        address spender = makeAddr("v19-spender");
        NutboxSender19 forwarder = new NutboxSender19();
        uint256 part = received / 4;
        vm.startPrank(buyer);
        token.approve(spender, 2 * part);
        token.approve(address(forwarder), 2 * part);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            vm.warp(token.createdAt() + (i == 0 ? 0 : 16));
            vm.prank(spender);
            token.transferFrom(buyer, community, part);
            forwarder.sendFrom(token, buyer, community, part);
        }
        assertEq(token.balanceOf(community), 4 * part);
        assertEq(token.allowance(buyer, spender), 0);
        assertEq(token.allowance(buyer, address(forwarder)), 0);
    }

    function test_v19_contractHolderCanApproveAnotherContractToFundCommunity() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        NutboxSender19 spender = new NutboxSender19();
        vm.etch(buyer, type(NutboxSender19).runtimeCode);
        NutboxSender19(buyer).approveToken(token, address(spender), received);
        spender.sendFrom(token, buyer, community, received);
        assertEq(token.balanceOf(community), received);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.allowance(buyer, address(spender)), 0);
    }

    function test_v19_recipientExceptionStillRejectsOtherRecipientsAndMissingAllowance() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        vm.expectRevert(bytes4(keccak256("InsufficientAllowance()")));
        token.transferFrom(buyer, community, received);
        vm.prank(buyer);
        token.approve(address(this), received);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(buyer, creator, received);
        assertEq(token.allowance(buyer, address(this)), received);
        assertEq(token.balanceOf(buyer), received);
    }

    function test_v19_manualInjectionWhileListingPendingIsAllowed() public {
        uint256 received = _buy(buyer, false);
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(ICommunity(community).rewardCalculator());
        stdstore.enable_packed_slots().target(address(token)).sig("listingPending()").checked_write(true);
        vm.startPrank(buyer);
        token.approve(address(calculator), received);
        calculator.inject(community, received);
        vm.stopPrank();
        assertTrue(token.listingPending());
        assertEq(calculator.totalInjected(community), received);
        vm.prank(buyer);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(creator, 0);
    }

    function test_v19_versionNewTemplateAndDeployableSize() public view {
        assertEq(pump.VERSION(), 19);
        assertEq(pump.tokenImplementation().codehash, keccak256(type(Token19).runtimeCode));
        assertLe(pump.tokenImplementation().code.length, 24_576);
        assertLe(address(pump).code.length, 24_576);
    }

    function test_v19_bothBuyEntrypointsWorkWithoutRegistryAndCreateIpShare() public {
        assertFalse(ipshare.ipshareCreated(buyer));
        assertGt(_buy(buyer, false), 0);
        assertGt(_buy(buyer, true), 0);
        assertTrue(ipshare.ipshareCreated(buyer));
        assertEq(ipshare.totalStakedIPshare(buyer), 10 ether);
        assertEq(token.innerMarketBought(buyer), token.balanceOf(buyer));
        assertFalse(ipshare.ipshareCreated(address(pump)));
        assertFalse(ipshare.ipshareCreated(address(token)));
    }

    function test_v19_selfReferralOnFirstBuyWithoutHandle() public {
        vm.prank(buyer);
        token.buyToken{value: 0.01 ether}(0, buyer, 0);
        assertTrue(ipshare.ipshareCreated(buyer));
    }

    function test_v19_sellUsesCurveAndDoesNotRestoreQuota() public {
        uint256 amount = _buy(buyer, false);
        uint256 bought = token.innerMarketBought(buyer);
        uint256 reserve = address(token).balance;
        uint256 beforeNative = buyer.balance;
        vm.prank(buyer);
        token.sellToken(amount, 0, address(0), 0);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.bondingCurveSupply(), 0);
        assertEq(token.innerMarketBought(buyer), bought);
        assertLt(address(token).balance, reserve);
        assertGt(buyer.balance, beforeNative);
    }

    function test_v19_allExternalTransfersBlockedIncludingTokenDepositsAndSelfTransfers() public {
        uint256 amount = _buy(buyer, false);
        address[8] memory recipients = [
            creator,
            buyer,
            address(token),
            address(pump),
            address(router),
            address(vault),
            address(0),
            token.LP_BURN_ADDRESS()
        ];
        for (uint256 i; i < recipients.length; ++i) {
            vm.prank(buyer);
            vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
            token.transfer(recipients[i], amount);
            vm.prank(buyer);
            vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
            token.transfer(recipients[i], 0);
        }
        assertEq(token.balanceOf(buyer), amount);
    }

    function testFuzz_v19_transferFromCannotBypassRestriction(address recipient, uint96 rawAmount) public {
        _buy(buyer, false);
        vm.assume(recipient != token.nutboxCommunity());
        uint256 amount = bound(rawAmount, 0, token.balanceOf(buyer));
        vm.prank(buyer);
        token.approve(address(this), type(uint256).max);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(buyer, recipient, amount);
        assertEq(token.allowance(buyer, address(this)), type(uint256).max);
    }

    function test_v19_transferFromCannotUseTokenAsAnEndpoint() public {
        uint256 amount = _buy(buyer, false);
        vm.prank(buyer);
        token.approve(address(this), amount);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(buyer, address(token), amount);
        vm.prank(address(token));
        token.approve(address(this), amount);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(address(token), buyer, amount);
        assertEq(token.allowance(buyer, address(this)), amount);
        assertEq(token.balanceOf(buyer), amount);
    }

    function test_v19_registeredWalletsAlsoCannotTransfer() public {
        _setUpHandleRegistry();
        _buy(buyer, false);
        _registerHandle(buyer);
        vm.prank(buyer);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(creator, 1);
    }

    function test_v19_premineForUnregisteredCreatorSucceedsButCannotBeTransferred() public {
        address fresh = makeAddr("v19-fresh-creator");
        vm.deal(fresh, 1 ether);
        vm.prank(fresh, fresh);
        Token created = Token(payable(pump.createToken{value: 0.015 ether}("V19", bytes32(uint256(19)), _config())));
        assertGt(created.balanceOf(fresh), 0);
        assertTrue(ipshare.ipshareCreated(fresh));
        assertEq(created.innerMarketBought(fresh), created.balanceOf(fresh));
        assertEq(created.innerMarketBought(address(pump)), 0);
        vm.prank(fresh);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        created.transfer(creator, 1);
    }

    function test_v19_cumulativeQuotaAcrossEntrypointsAndSell() public {
        vm.mockCall(
            address(pump), abi.encodeWithSelector(pump.getBuyAmountByValue.selector), abi.encode(10_000_000 ether)
        );
        vm.prank(buyer);
        token.buyToken{value: 0.1 ether}(0, creator, 0);
        vm.clearMockedCalls();
        vm.prank(buyer);
        token.sellToken(1 ether, 0, creator, 0);
        assertEq(token.innerMarketBought(buyer), 10_000_000 ether);
        vm.mockCall(address(pump), abi.encodeWithSelector(pump.getBuyAmountByValue.selector), abi.encode(1));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, buyer));
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(buyer);
        (bool ok, bytes memory reason) = address(token).call{value: 0.01 ether}("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IToken.InnerMarketBuyLimitExceeded.selector, buyer));
    }

    function test_v19_pendingStillBlocksTransfersAndListingRestoresThem() public {
        _fillToListingPending();
        vm.prank(creator);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(buyer, 1);
        vm.prank(creator);
        token.approve(address(this), 1);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transferFrom(creator, buyer, 1);
        pump.adminRecoverFailedListing(address(token));
        vm.prank(creator);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(buyer, 1);
    }

    function test_v19_slippageRollsBackCreationAndQuota() public {
        uint256 beforeNative = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert(IToken.OutOfSlippage.selector);
        token.buyToken{value: 0.01 ether}(10_000_000 ether, creator, 1);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(token.innerMarketBought(buyer), 0);
        assertEq(token.bondingCurveSupply(), 0);
        assertEq(buyer.balance, beforeNative);
    }

    function test_v19_nonzeroIpShareFeeStillFailsAtomically() public {
        ipshare.adminSetCreateFee(0.001 ether);
        vm.prank(buyer);
        vm.expectRevert(IIPShare.InsufficientPay.selector);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertFalse(ipshare.ipshareCreated(buyer));
        assertEq(token.bondingCurveSupply(), 0);
    }

    function test_v19_ordinaryContractStillCannotBecomeIpShareSubject() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert("Subject must be EOA");
        token.buyToken{value: 0.01 ether}(0, creator, 0);
    }

    function test_v19_antiSnipeInternalRewardsRemainAvailable() public {
        vm.warp(token.createdAt());
        uint256 amount = _buy(buyer, false);
        assertGt(token.bondingCurveSupply(), amount);
        assertEq(token.innerMarketBought(buyer), amount);
    }
}
