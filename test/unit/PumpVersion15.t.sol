// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {MockHandleRegistry} from "../helpers/HandleRegistryTestSetup.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";

/// @dev Also runs the inherited listing, pool-tax, buyback and reward regressions.
contract PumpVersion15Test is PumpVersion13Test {
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

    function test_v15_versionAndDeployableSize() public view {
        assertEq(pump.VERSION(), 15);
        assertLe(pump.tokenImplementation().code.length, 24_576, "Token must fit EIP-170");
        assertLe(address(pump).code.length, 24_576, "Pump must fit EIP-170");
    }

    function test_v15_registeredBuyerCanBuy() public {
        vm.expectCall(HANDLE_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (buyer)));
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);
        assertGt(received, 0);
        assertEq(token.balanceOf(buyer), received);
    }

    function test_v15_unregisteredBuyerCannotBorrowCreatorOrOriginEligibility() public {
        _setHandle(buyer, "");
        uint256 reserveBefore = address(token).balance;
        uint256 supplyBefore = token.bondingCurveSupply();
        vm.prank(buyer, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 1 ether}(0, creator, 0);
        assertEq(address(token).balance, reserveBefore);
        assertEq(token.bondingCurveSupply(), supplyBefore);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(buyer.balance, 1000 ether);
    }

    function test_v15_directBNBBuyRequiresHandle() public {
        _setHandle(buyer, "");
        vm.prank(buyer);
        (bool success, bytes memory reason) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        assertEq(token.balanceOf(buyer), 0);
        _registerHandle(buyer);
        vm.prank(buyer);
        (success,) = address(token).call{value: 1 ether}("");
        assertTrue(success);
        assertGt(token.balanceOf(buyer), 0);
    }

    function test_v15_creatorFirstBuyAfterCreationRequiresHandleWithoutPremine() public {
        _setHandle(creator, "");
        uint256 createFee = pump.createFee();
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: createFee}("NOPRE15", bytes32(uint256(17)), _config())));
        assertEq(created.bondingCurveSupply(), 0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        created.buyToken{value: 1 ether}(0, creator, 0);
        vm.prank(creator, creator);
        (bool success, bytes memory reason) = address(created).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        assertEq(created.bondingCurveSupply(), 0);
        _registerHandle(creator);
        vm.prank(creator, creator);
        assertGt(created.buyToken{value: 1 ether}(0, creator, 0), 0);
    }

    function test_v15_creatorLaterBuysRequireHandleAfterExemptPremine() public {
        _setHandle(creator, "");
        assertEq(bytes(IHandleRegistry(HANDLE_REGISTRY).handleOf(creator)).length, 0);
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: 1.005 ether}("LATER15", bytes32(uint256(18)), _config())));
        uint256 premine = created.balanceOf(creator);
        uint256 reserveBefore = address(created).balance;
        assertGt(premine, 0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        created.buyToken{value: 1 ether}(0, creator, 0);
        vm.prank(creator, creator);
        (bool success, bytes memory reason) = address(created).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        assertEq(created.balanceOf(creator), premine);
        assertEq(address(created).balance, reserveBefore);
        _registerHandle(creator);
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        assertGt(created.buyToken{value: 1 ether}(0, creator, 0), 0);
        vm.prank(creator, creator);
        (success,) = address(created).call{value: 1 ether}("");
        assertTrue(success);
    }

    function test_v15_creationAndPremineDoNotRequireHandle() public {
        _setHandle(creator, "");
        assertEq(bytes(IHandleRegistry(HANDLE_REGISTRY).handleOf(creator)).length, 0);
        vm.prank(creator, creator);
        Token created = Token(payable(pump.createToken{value: 1.005 ether}("PRE15", bytes32(uint256(15)), _config())));
        assertGt(created.balanceOf(creator), 0);
        assertEq(created.balanceOf(address(pump)), 0);
    }

    function test_v15_optionalPoolOverloadPremineDoesNotRequireHandle() public {
        _setHandle(creator, "");
        vm.prank(creator, creator);
        Token created = Token(
            payable(pump.createToken{value: 1.005 ether}(
                    "OPT15", bytes32(uint256(16)), _config(), new IPump.OptionalPoolConfig[](0)
                ))
        );
        assertGt(created.balanceOf(creator), 0);
    }

    function test_v15_sellingAndOrdinaryTransfersDoNotRequireHandle() public {
        vm.prank(buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);
        _setHandle(buyer, "");
        vm.prank(buyer);
        token.transfer(creator, received / 2);
        uint256 nativeBefore = buyer.balance;
        vm.prank(buyer);
        token.sellToken(received - received / 2, 0, creator, 0);
        assertEq(token.balanceOf(buyer), 0);
        assertGt(buyer.balance, nativeBefore);
    }

    function test_v15_antiSnipeBuyAlsoRequiresHandle() public {
        vm.warp(token.createdAt());
        _setHandle(buyer, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 1 ether}(0, creator, 0);
    }

    function test_v15_fillToCapCannotBypassGate() public {
        _setHandle(buyer, "");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, buyer));
        token.buyToken{value: 100 ether}(0, creator, 0);
        _registerHandle(buyer);
        vm.prank(buyer);
        token.buyToken{value: 100 ether}(0, creator, 0);
        assertTrue(token.listingPending());
    }

    function test_v15_postListingTransfersDoNotRequireHandle() public {
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

    function test_v15_anyNonemptyStringIsAccepted() public {
        _setHandle(buyer, "any string: no format validation!");
        vm.prank(buyer);
        assertGt(token.buyToken{value: 1 ether}(0, creator, 0), 0);
    }
}
