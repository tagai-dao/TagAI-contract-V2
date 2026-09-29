// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13BuybackForkTest} from "./Pump13Buyback.t.sol";
import {ForkOwner} from "./Pump13Mainnet.t.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";

/// @dev Run test_reuse_*; tests inherit real BSC/Basket integration helpers.
contract Pump14TemplateReuseForkTest is Pump13BuybackForkTest {
    address constant V13_TEMPLATE = 0xcC8f585593feAb2a27f9e699a6b578d46446c88C;
    address constant V13_PUMP = 0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa;

    function _defaultForkBlock() internal pure override returns (uint256) {
        // V13 template was deployed at 120527169, after the original harness pin.
        return 120700000;
    }

    function _tokenTemplate() internal pure override returns (address) {
        return V13_TEMPLATE;
    }

    function _assertRealTemplate() private view {
        assertGt(V13_TEMPLATE.code.length, 0);
        assertEq(Pump(payable(V13_PUMP)).tokenImplementation(), V13_TEMPLATE);
        assertEq(pump.tokenImplementation(), V13_TEMPLATE);
    }

    function test_reuse_existingV13TemplateListingBuybackAndHolderClaims() public {
        _assertRealTemplate();
        test_buyback_fourLegFirstAndSubsequentPublicExecutionAndClaims();
    }

    function test_reuse_optionalTradePoolAndIndependentTokenClones() public {
        _assertRealTemplate();
        bytes32 originalCodeHash = V13_TEMPLATE.codehash;
        TradeCurationFactory f = new TradeCurationFactory(COMMUNITY_FACTORY, vm.addr(0x141414));
        vm.prank(ForkOwner(COMMITTEE).owner());
        ICommittee(COMMITTEE).adminAddContract(address(f));
        pump.adminSetOptionalPoolFactory(address(f), "Trade Curation", 8000, true);
        IPump.OptionalPoolConfig[] memory options = new IPump.OptionalPoolConfig[](1);
        options[0] = IPump.OptionalPoolConfig(address(f), 8000, "");
        IPump.IndexConfig memory config = _config(2, 4, true);
        uint256 ipFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 fee = pump.createFee() + ipFee + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * 5;
        vm.prank(creator, creator);
        Token a =
            Token(payable(pump.createToken{value: fee + 1 ether}("REUSE14", bytes32(uint256(14)), config, options)));
        Token b = _create(_config(6, 2, false));
        bytes memory cloneCode =
            abi.encodePacked(hex"363d3d373d3d3d363d73", V13_TEMPLATE, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(address(a).code, cloneCode);
        assertEq(address(b).code, cloneCode);
        // Index baskets are created when the token lists.
        assertEq(a.indexToken(), address(0));
        assertEq(b.indexToken(), address(0));
        assertTrue(a.nutboxCommunity() != b.nutboxCommunity());
        assertFalse(Pump(payable(V13_PUMP)).createdTokens(address(a)));
        assertTrue(pump.createdTokens(address(a)));
        assertTrue(ICommunity(a.nutboxCommunity()).activedPools(4) != address(0));
        uint256 bSupply = b.totalSupply();
        uint256 bCreatorBalance = b.balanceOf(creator);
        _fill(a);
        _list(a);
        assertTrue(a.indexToken() != address(0));
        assertEq(b.indexToken(), address(0));
        assertEq(a.listingHook(), address(hook));
        _buyT(a, 1 ether);
        uint256 received = hook.executeBuyback(address(a), 1, block.timestamp + 60, _buybackData(a, _legs(a)));
        assertGt(received, 0);
        assertGt(a.pendingBuybackReward(creator), 0);
        a.claimBuybackReward(creator);
        assertEq(b.totalIndexRewardsNotified(), 0);
        assertEq(b.totalSupply(), bSupply);
        assertEq(b.balanceOf(creator), bCreatorBalance);
        assertEq(V13_TEMPLATE.codehash, originalCodeHash);
        _assertNoAdapterResidue();
    }
}
