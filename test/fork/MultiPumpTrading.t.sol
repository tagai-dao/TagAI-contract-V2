// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TagAITradeRouterForkTest} from "./TagAITradeRouter.t.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {CommentBuyAdapter} from "../../src/helper/CommentBuyAdapter.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

/// @dev Current Pump14 source, real deployed V13 Token template, real BSC pools. No broadcast.
contract MultiPumpTradingForkTest is TagAITradeRouterForkTest {
    function _defaultForkBlock() internal pure override returns (uint256) { return 123498860; }
    function _tokenTemplate() internal pure override returns (address) { return 0xcC8f585593feAb2a27f9e699a6b578d46446c88C; }

    function test_multiPumpFork_newPumpAdmissionAdapterBuyAndRouterSell() public {
        Token t = _create(_config(0, 2, true));
        _fill(t);
        _list(t);
        TagAITradeRouter executor = new TagAITradeRouter(
            0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa, address(router), Config.pancakeV2Factory());
        assertFalse(executor.supportsToken(address(t)));
        executor.setPump(address(pump), true);
        assertTrue(executor.supportsToken(address(t)));
        // V13 admission remains active alongside the newly configured Pump14.
        assertTrue(executor.supportsToken(0xbc59192DfaD0eF94db82B6dD1a2Dd97e040D3333));
        CommentBuyAdapter adapter = new CommentBuyAdapter(address(executor),
            0xaC29EaEb5764A83f7Ed03240EA2aF54018210cc1, 0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F);
        vm.expectRevert("UNREVIEWED_HOOK");
        adapter.quoteInput(address(t), 0.001 ether, 1);
        adapter.setHookPolicy(address(hook), true, 30, 30, 30);
        (uint256 gross,,,) = adapter.quoteInput(address(t), 0.001 ether, 1);
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = _tradeLeg(executor, t, 0, gross, true);
        address buyer = makeAddr("multi-pump-buyer");
        uint256 out = adapter.buy{value: gross}(address(t), buyer, creator, 1, block.timestamp + 60, 1, abi.encode(legs));
        assertGt(out, 0);
        assertEq(t.balanceOf(buyer), out);
        assertEq(t.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        vm.prank(buyer);
        t.approve(address(executor), out);
        legs[0] = _tradeLeg(executor, t, 0, out, false);
        vm.prank(buyer);
        assertGt(executor.sell(address(t), out, legs, 1, block.timestamp + 60, buyer, creator), 0);
        assertEq(t.balanceOf(buyer), 0);
        assertEq(address(executor).balance, 0);
        executor.setPump(address(pump), false);
        assertFalse(executor.supportsToken(address(t)));
        assertTrue(executor.supportsToken(0xbc59192DfaD0eF94db82B6dD1a2Dd97e040D3333));
    }
}
