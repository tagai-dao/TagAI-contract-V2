// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest} from "./Pump13Mainnet.t.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {Token} from "../../src/pump/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

/// @dev Run only test_buyback_ here; base functional cases are inherited.
contract Pump13BuybackForkTest is Pump13MainnetForkTest {
    function _ready() internal returns (Token t) {
        t = _create(_config(2, 4, true));
        _fill(t);
        _list(t);
        _buyT(t, 1 ether);
    }

    function _legs(Token t) internal view returns (bytes memory) {
        BasketTradeData memory d;
        d.legMins = new uint256[](t.componentCount());
        d.allowFailedLegs = new bool[](t.componentCount());
        d.legSqrtPriceLimitsX96 = new uint160[](0);
        for (uint256 i; i < d.legMins.length; ++i) {
            d.legMins[i] = 1;
        }
        return abi.encode(d);
    }

    function _preview(Token t, bytes memory payload) internal returns (uint256 quoted) {
        uint256 snapshot = vm.snapshotState();
        quoted = hook.executeBuyback(address(t), 1, block.timestamp + 60, payload);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertGt(quoted, 0);
    }

    function _assertNoAdapterResidue() internal view {
        address adapter = pump.buybackRouter();
        assertEq(adapter.balance, 0);
        assertEq(IERC20(Config.settlementToken()).balanceOf(adapter), 0);
        assertEq(IERC20(Config.settlementToken()).allowance(adapter, address(basketRouter)), 0);
    }

    function _assertFailurePreserves(Token t, uint256 minimum, uint256 deadline, bytes memory payload) internal {
        uint256 reserve = hook.buybackBnbReserve(address(t));
        uint256 nativeBalance = address(hook).balance;
        uint256 supply = IERC20(t.indexToken()).totalSupply();
        uint256 notified = t.totalIndexRewardsNotified();
        uint256 indexHeld = IERC20(t.indexToken()).balanceOf(address(t));
        uint256 platformBefore = platform.balance;
        vm.expectRevert();
        hook.executeBuyback(address(t), minimum, deadline, payload);
        assertEq(hook.buybackBnbReserve(address(t)), reserve);
        assertEq(address(hook).balance, nativeBalance);
        assertEq(IERC20(t.indexToken()).totalSupply(), supply);
        assertEq(t.totalIndexRewardsNotified(), notified);
        assertEq(IERC20(t.indexToken()).balanceOf(address(t)), indexHeld);
        assertEq(platform.balance, platformBefore);
        _assertNoAdapterResidue();
    }

    function test_buyback_fourLegFirstAndSubsequentPublicExecutionAndClaims() public {
        Token t = _ready();
        bytes memory payload = _buybackData(t, _legs(t));
        uint256 quote = _preview(t, payload);
        address caller = makeAddr("permissionless-buyback-caller");
        vm.prank(caller);
        uint256 first = hook.executeBuyback(address(t), quote * 99 / 100, block.timestamp + 60, payload);
        assertEq(first, quote);
        assertEq(IERC20(t.indexToken()).balanceOf(caller), 0);
        assertEq(t.totalIndexRewardsNotified(), first);
        assertEq(IERC20(t.indexToken()).balanceOf(address(t)), first);
        uint256 due = t.pendingBuybackReward(creator);
        assertGt(due, 0);
        vm.prank(caller);
        t.claimBuybackReward(creator);
        assertEq(IERC20(t.indexToken()).balanceOf(creator), due);
        t.claimBuybackReward(creator);
        assertEq(IERC20(t.indexToken()).balanceOf(creator), due);
        assertEq(t.pendingBuybackReward(DEAD), 0);
        assertEq(t.pendingBuybackReward(address(hook)), 0);
        for (uint256 i; i < 4; ++i) {
            (,, address pair) = t.componentAt(i);
            assertEq(t.pendingBuybackReward(pair), 0);
        }
        _buyT(t, 0.2 ether);
        payload = _buybackData(t, _legs(t));
        quote = _preview(t, payload);
        uint256 second = hook.executeBuyback(address(t), quote * 99 / 100, block.timestamp + 60, payload);
        assertEq(second, quote);
        assertEq(t.totalIndexRewardsNotified(), first + second);
        assertGt(t.pendingBuybackReward(creator), 0);
        assertEq(IERC20(t.indexToken()).allowance(address(hook), address(t)), 0);
        _assertNoAdapterResidue();
    }

    function test_buyback_bothSlippageStagesRollbackAndRetry() public {
        Token t = _ready();
        bytes memory payload = _buybackData(t, _legs(t));
        uint256 quote = _preview(t, payload);
        // Intermediate BNB -> USDT bound fails without modifying reserve or pools.
        _assertFailurePreserves(t, 1, block.timestamp + 60, abi.encode(type(uint256).max, _legs(t)));
        // This failure occurs after the first conversion, exercising full atomic rollback.
        _assertFailurePreserves(t, quote + 1, block.timestamp + 60, payload);
        assertEq(hook.executeBuyback(address(t), quote * 99 / 100, block.timestamp + 60, payload), quote);
        _assertNoAdapterResidue();
    }

    function test_buyback_expiryMalformedAndMissingFirstLegBounds() public {
        Token t = _ready();
        _assertFailurePreserves(t, 1, block.timestamp - 1, _buybackData(t, _legs(t)));
        _assertFailurePreserves(t, 1, block.timestamp + 60, hex"1234");
        _assertFailurePreserves(t, 1, block.timestamp + 60, _buybackData(t, ""));
        _assertFailurePreserves(t, 0, block.timestamp + 60, _buybackData(t, _legs(t)));
        assertGt(hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, _legs(t))), 0);
    }

    function test_buyback_twoTokenReservesAndRewardsStayIsolated() public {
        Token a = _ready();
        Token b = _create(_config(6, 4, false));
        _fill(b);
        _list(b);
        _buyT(b, 0.2 ether);
        uint256 bReserve = hook.buybackBnbReserve(address(b));
        hook.executeBuyback(address(a), 1, block.timestamp + 60, _buybackData(a, _legs(a)));
        assertEq(hook.buybackBnbReserve(address(b)), bReserve);
        assertEq(b.totalIndexRewardsNotified(), 0);
        uint256 aReserve = hook.buybackBnbReserve(address(a));
        uint256 aRewards = a.totalIndexRewardsNotified();
        hook.executeBuyback(address(b), 1, block.timestamp + 60, _buybackData(b, _legs(b)));
        assertEq(hook.buybackBnbReserve(address(a)), aReserve);
        assertEq(a.totalIndexRewardsNotified(), aRewards);
        assertGt(b.totalIndexRewardsNotified(), 0);
        assertEq(address(hook).balance, aReserve + hook.buybackBnbReserve(address(b)));
        _assertNoAdapterResidue();
    }

    function test_buyback_directCallWrongIndexAndRecipientRejected() public {
        Token t = _ready();
        TagAIBuybackRouter adapter = TagAIBuybackRouter(pump.buybackRouter());
        address indexAddress = t.indexToken();
        bytes memory payload = _buybackData(t, _legs(t));
        vm.expectRevert(TagAIBuybackRouter.Unauthorized.selector);
        adapter.buyIndexWithBnb{value: 1 ether}(
            address(t), indexAddress, 1, block.timestamp + 60, payload, address(this)
        );
        vm.prank(address(hook));
        vm.expectRevert(TagAIBuybackRouter.Unauthorized.selector);
        adapter.buyIndexWithBnb(address(t), indexAddress, 1, block.timestamp + 60, payload, address(this));
        vm.prank(address(hook));
        vm.expectRevert(TagAIBuybackRouter.InvalidToken.selector);
        adapter.buyIndexWithBnb(address(t), Config.settlementToken(), 1, block.timestamp + 60, payload, address(hook));
        assertEq(hook.buybackBnbReserve(address(t)), 0.003 ether);
    }

    function test_buyback_existingTokenKeepsHookAfterPumpDefaultChanges() public {
        Token t = _ready();
        pump.adminSetHookAddress(makeAddr("replacement-hook"));
        assertGt(hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, _legs(t))), 0);
        assertEq(t.listingHook(), address(hook));
        _assertNoAdapterResidue();
    }

    function test_buyback_missingRouterCanBeConfiguredAndRetried() public {
        Token t = _ready();
        address adapter = pump.buybackRouter();
        bytes memory payload = _buybackData(t, _legs(t));
        pump.adminSetBuybackRouter(address(0));
        vm.expectRevert(TagAISwapHook.BuybackRouterNotConfigured.selector);
        hook.executeBuyback(address(t), 1, block.timestamp + 60, payload);
        assertEq(hook.buybackBnbReserve(address(t)), 0.003 ether);
        pump.adminSetBuybackRouter(adapter);
        assertGt(hook.executeBuyback(address(t), 1, block.timestamp + 60, payload), 0);
    }

    function test_buyback_beforeListingHasNoMining() public {
        Token t = _create(_config(2, 4, true));
        _fill(t);
        assertEq(hook.buybackBnbReserve(address(t)), 0);
        assertEq(t.totalIndexRewardsNotified(), 0);
        vm.expectRevert(TagAISwapHook.IndexTokenNotReady.selector);
        hook.executeBuyback(address(t), 1, block.timestamp + 60, "");
        _list(t);
        vm.expectRevert(TagAISwapHook.NoBuybackReserve.selector);
        hook.executeBuyback(address(t), 1, block.timestamp + 60, "");
    }
}
