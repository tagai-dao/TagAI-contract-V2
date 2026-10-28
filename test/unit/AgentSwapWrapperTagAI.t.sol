// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {AgentSwapWrapper} from "../../src/helper/AgentSwapWrapper.sol";
import {ImportedTokenSwapWrapper} from "../../src/helper/ImportedTokenSwapWrapper.sol";
import {MockHandleRegistry} from "../helpers/HandleRegistryTestSetup.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";

/// @dev Deterministic pool pricing with real TagAI Hook callbacks and real Vault token transfers.
contract AgentTagAIPoolManager {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function swap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        require(params.amountSpecified < 0, "EXACT_INPUT_ONLY");
        (, BeforeSwapDelta beforeFee,) = ICLHooks(address(key.hooks)).beforeSwap(msg.sender, key, params, hookData);
        int128 input = int128(-params.amountSpecified);
        if (params.zeroForOne) {
            int128 ammInput = input - beforeFee.getSpecifiedDelta();
            delta = toBalanceDelta(-ammInput, ammInput * 1000);
            ICLHooks(address(key.hooks)).afterSwap(msg.sender, key, params, delta, hookData);
            return toBalanceDelta(-input, ammInput * 1000);
        }
        int128 nativeOutput = input / 1000;
        delta = toBalanceDelta(nativeOutput, -input);
        (, int128 afterFee) = ICLHooks(address(key.hooks)).afterSwap(msg.sender, key, params, delta, hookData);
        return toBalanceDelta(nativeOutput - afterFee, -input);
    }
}

contract AgentSwapWrapperTagAITest is PumpVersion13Test {
    function _listedAgent() private returns (AgentSwapWrapper agent, bytes memory source, address platform) {
        _list();
        assertTrue(token.listed());
        AgentTagAIPoolManager swapManager = new AgentTagAIPoolManager(address(vault));
        vm.etch(address(manager), address(swapManager).code);
        vm.deal(address(vault), 100 ether);
        platform = makeAddr("agentPlatform");
        agent = new AgentSwapWrapper(address(router), platform, address(ipshare));
        agent.setReferralHook(address(hook), true);
        INutboxRouter.PancakeV4CLSource memory pool = INutboxRouter.PancakeV4CLSource(
            address(0), address(token), address(hook), address(manager), 0, token.listingPoolParameters()
        );
        source = abi.encode(ImportedTokenSwapWrapper.PancakeV4Source(address(0), pool));
    }

    function test_agentBuysRealListedTagAITokenAndPreservesHookFeesAndReferral() public {
        (AgentSwapWrapper agent, bytes memory source, address platform) = _listedAgent();
        address buyer = makeAddr("freshListedBuyer");
        address subject = makeAddr("listedReferral");
        _registerHandle(buyer);
        ipshare.createShare(subject);
        vm.deal(buyer, 1 ether);
        uint256 hookReserve = hook.buybackBnbReserve(address(token));
        vm.prank(buyer);
        uint256 bought = agent.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.PANCAKE_V4_CL,
            source,
            987.036 ether,
            buyer,
            block.timestamp + 1,
            subject
        );
        assertEq(bought, 987.036 ether);
        assertEq(token.balanceOf(buyer), bought);
        assertTrue(ipshare.ipshareCreated(buyer));
        assertEq(ipshare.totalStakedIPshare(buyer), 10 ether);
        assertGt(ipshare.getPendingProfits(subject, subject), 0);
        assertEq(platform.balance, 0.002 ether);
        assertEq(hook.buybackBnbReserve(address(token)) - hookReserve, 0.996 ether * 30 / 10_000);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(address(agent).balance, 0);
        assertEq(token.innerMarketBought(buyer), 0);
    }

    function test_agentSellsRealListedTagAITokenAndPreservesBothFeeLayers() public {
        (AgentSwapWrapper agent, bytes memory source, address platform) = _listedAgent();
        address seller = makeAddr("freshListedSeller");
        address subject = makeAddr("sellReferral");
        _registerHandle(seller);
        ipshare.createShare(subject);
        vm.prank(creator);
        token.transfer(seller, 1000 ether);
        vm.prank(seller);
        token.approve(address(agent), 1000 ether);
        vm.prank(seller);
        uint256 sold = agent.sellToken(
            address(token),
            INutboxRouter.SourceType.PANCAKE_V4_CL,
            source,
            1000 ether,
            0.987036 ether,
            seller,
            block.timestamp + 1,
            subject
        );
        assertEq(sold, 0.987036 ether);
        assertEq(seller.balance, sold);
        assertTrue(ipshare.ipshareCreated(seller));
        assertEq(ipshare.totalStakedIPshare(seller), 10 ether);
        assertEq(platform.balance, 0.991 ether * 20 / 10_000);
        assertGt(ipshare.getPendingProfits(subject, subject), 0);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(token.balanceOf(seller), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(address(agent).balance, 0);
    }

    function test_agentConfiguredNutboxFeeUsesRealTagAICommunityAndCalculator() public {
        (AgentSwapWrapper agent, bytes memory source, address platform) = _listedAgent();
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(Community(payable(community)).rewardCalculator());
        agent.setNutboxMarket(address(token), community, creator, 20);
        address trader = makeAddr("configuredNutboxAgent");
        _registerHandle(trader);
        vm.deal(trader, 1 ether);
        uint256 buyFee = 987.036 ether * 20 / 10_000;
        vm.prank(trader);
        uint256 bought = agent.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.PANCAKE_V4_CL,
            source,
            987.036 ether - buyFee,
            trader,
            block.timestamp + 1,
            creator
        );
        assertEq(bought, 987.036 ether - buyFee);
        assertTrue(ipshare.ipshareCreated(trader));
        assertEq(platform.balance, 0.002 ether);
        assertEq(agent.pendingNutboxInjection(address(token)), buyFee);
        // Preserve native Hook buyback fees even when optional token-side fees are enabled.
        assertEq(hook.buybackBnbReserve(address(token)), 0.996 ether * 30 / 10_000);
        vm.prank(creator);
        token.transfer(trader, 1000 ether);
        vm.prank(trader);
        token.approve(address(agent), 1000 ether);
        vm.prank(trader);
        uint256 sold = agent.sellToken(
            address(token),
            INutboxRouter.SourceType.PANCAKE_V4_CL,
            source,
            1000 ether,
            0.985061928 ether,
            trader,
            block.timestamp + 1,
            creator
        );
        assertEq(sold, 0.985061928 ether);
        uint256 pending = buyFee + 2 ether;
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        uint256 previousInjected = calculator.totalInjected(community);
        uint256 communityBalance = token.balanceOf(community);
        vm.warp(block.timestamp + 600);
        assertEq(agent.flushNutboxInjection(address(token)), pending);
        assertEq(calculator.totalInjected(community) - previousInjected, pending);
        assertEq(token.balanceOf(community) - communityBalance, pending);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(token.allowance(address(agent), address(calculator)), 0);
    }
}
