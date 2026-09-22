// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest, ForkOwner, ForkStake} from "./Pump13Mainnet.t.sol";
import {ColdCallGas} from "../helpers/ColdCallGas.sol";
import {ICreateOptional} from "../unit/PumpVersion14.t.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {Token} from "../../src/pump/Token.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {TradeCuration} from "../../src/nutbox/dapps/trade-curation/TradeCuration.sol";

interface IFork14Fees {
    function adminSetCreateCommunityFee(uint256 fee) external;
    function adminSetCommunitySettingsFee(uint256 fee) external;
    function adminSetPoolOperationFee(uint256 fee) external;
}

/// @dev Uses the V13 harness's pinned real BSC infrastructure and separately built Basket artifacts.
/// Run only test_v14Fork_* to avoid duplicating the inherited V13 cases.
contract Pump14MainnetForkTest is Pump13MainnetForkTest, ColdCallGas {
    uint256 constant TRADE_SIGNER_KEY = 0x141414;

    function _options(uint256 count, uint16 eachRatio) private returns (IPump.OptionalPoolConfig[] memory p) {
        p = new IPump.OptionalPoolConfig[](count);
        for (uint256 i; i < count; ++i) {
            TradeCurationFactory f = new TradeCurationFactory(COMMUNITY_FACTORY, vm.addr(TRADE_SIGNER_KEY));
            vm.prank(ForkOwner(COMMITTEE).owner());
            ICommittee(COMMITTEE).adminAddContract(address(f));
            pump.adminSetOptionalPoolFactory(address(f), "Trade Curation", 8000, true);
            p[i] = IPump.OptionalPoolConfig(address(f), eachRatio, "");
        }
    }

    function _create14(IPump.IndexConfig memory c, IPump.OptionalPoolConfig[] memory p, uint256 premine)
        private
        returns (Token t)
    {
        (t,) = _create14Measured(c, p, premine, 16_700_000);
    }

    function _create14Measured(
        IPump.IndexConfig memory c,
        IPump.OptionalPoolConfig[] memory p,
        uint256 premine,
        uint256 executionBudget
    ) private returns (Token t, uint256 gasUsed) {
        uint256 ipFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 value = pump.createFee() + ipFee + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * (c.constituentAssets.length + p.length) + premine;
        bytes memory payload = abi.encodeCall(ICreateOptional.createToken, ("FORK14", bytes32(uint256(14)), c, p));
        bytes memory result;
        (result, gasUsed) =
            _coldCall("BSC V14 cold creation incl intrinsic", creator, address(pump), value, payload, executionBudget);
        if (executionBudget <= 16_700_000) assertLt(gasUsed, 16_777_216, "project transaction gas budget exceeded");
        t = Token(payable(abi.decode(result, (address))));
        assertTrue(pump.createdTokens(address(t)));
        assertEq(ForkOwner(t.nutboxCommunity()).owner(), c.retainCommunityOwnership ? creator : address(0));
        for (uint256 i; i < c.constituentAssets.length; ++i) {
            (,, address pair) = t.componentAt(i);
            assertEq(ForkStake(ICommunity(t.nutboxCommunity()).activedPools(i)).stakeToken(), pair);
        }
    }

    function test_v14Fork_maxSixPoolsCreatePremineAndList() public {
        Token t = _create14(_config(0, 4, true), _options(2, 4000), 1 ether);
        assertGt(t.balanceOf(creator), 0);
        for (uint256 i; i < 2; ++i) {
            TradeCuration p = TradeCuration(payable(ICommunity(t.nutboxCommunity()).activedPools(4 + i)));
            assertEq(p.community(), t.nutboxCommunity());
        }
        _fill(t);
        _list(t);
    }

    function test_v14Fork_sixPoolsLargeMetadataAndFeesFitsBudget() public {
        IPump.IndexConfig memory c = _config(0, 4, true);
        c.name = "1234567890123456789012345678901234567890123456789012345678901234";
        c.symbol = "1234567890123456";
        IPump.OptionalPoolConfig[] memory p = _options(2, 4000);
        for (uint256 i; i < p.length; ++i) {
            pump.adminSetOptionalPoolFactory(p[i].factory, c.name, 8000, true);
        }
        vm.startPrank(ForkOwner(COMMITTEE).owner());
        IFork14Fees(COMMITTEE).adminSetCreateCommunityFee(0.001 ether);
        IFork14Fees(COMMITTEE).adminSetCommunitySettingsFee(0.001 ether);
        vm.stopPrank();
        (Token t, uint256 gasUsed) = _create14Measured(c, p, 1 ether, 16_700_000);
        emit log_named_uint("BSC six pools large metadata/fees creation gas", gasUsed);
        assertLt(gasUsed, 16_777_216);
        assertEq(t.indexName(), c.name);
        assertEq(t.indexSymbol(), c.symbol);
        _fill(t);
        _list(t);
    }

    function _sign(TradeCuration p, uint256 order, uint256 amount, address to) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nutbox TradeCuration"),
                keccak256("1"),
                uint256(56),
                address(p)
            )
        );
        bytes32 claimHash = keccak256(
            abi.encode(
                keccak256(
                    "Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)"
                ),
                uint256(56),
                address(p),
                order,
                amount,
                to,
                block.timestamp + 1 days
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(TRADE_SIGNER_KEY, keccak256(abi.encodePacked("\x19\x01", domain, claimHash)));
        return abi.encodePacked(r, s, v);
    }

    function test_v14Fork_eightyPercentRewardHarvestSignedClaimAndReplay() public {
        Token t = _create14(_config(0, 2, false), _options(1, 8000), 1 ether);
        TradeCuration p = TradeCuration(payable(ICommunity(t.nutboxCommunity()).activedPools(2)));
        vm.startPrank(creator, creator);
        t.approve(address(calculator), 168_000 ether);
        calculator.inject(t.nutboxCommunity(), 168_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 168 hours);
        address recipient = makeAddr("fork14-reward-user");
        vm.deal(recipient, 1 ether);
        vm.prank(ForkOwner(COMMITTEE).owner());
        IFork14Fees(COMMITTEE).adminSetPoolOperationFee(0.001 ether);
        uint256 fee = ICommittee(COMMITTEE).getPoolOperationFee();
        bytes memory sig = _sign(p, 1, 100 ether, recipient);
        bytes memory payload = abi.encodeCall(p.claim, (1, 100 ether, block.timestamp + 1 days, sig));
        _coldCall(
            "BSC V14 harvest-and-claim incl intrinsic", recipient, address(p), fee + 0.1 ether, payload, 1_000_000
        );
        assertEq(t.balanceOf(recipient), 100 ether);
        assertEq(t.balanceOf(address(p)), 134_300 ether);
        assertEq(recipient.balance, 1 ether - fee);
        vm.prank(recipient);
        vm.expectRevert("Claimed");
        p.claim(1, 100 ether, block.timestamp + 1 days, sig);
        // Direct feeFree claim is verified against the deployed Committee too.
        vm.prank(ForkOwner(COMMITTEE).owner());
        (bool allowed,) = COMMITTEE.call(abi.encodeWithSignature("adminAddFeeFreeAddress(address)", recipient));
        assertTrue(allowed);
        sig = _sign(p, 2, 10 ether, recipient);
        uint256 beforeBnb = recipient.balance;
        vm.prank(recipient);
        p.claim(2, 10 ether, block.timestamp + 1 days, sig);
        assertEq(recipient.balance, beforeBnb);
        assertEq(t.balanceOf(recipient), 110 ether);
    }

    function test_v14Fork_noOptionalPoolLegacyCreationAndListing() public {
        Token t = _create(_config(0, 2, true));
        _fill(t);
        _list(t);
    }
}
