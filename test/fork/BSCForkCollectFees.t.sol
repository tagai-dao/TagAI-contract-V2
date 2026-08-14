// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";

/**
 * @title BSCForkCollectFees
 * @notice Latest BSC mainnet-state coverage for the locked listing position's permissionless fee collection.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork BSC_RPC_URL=<rpc-url> FOUNDRY_ETH_RPC_URL= \
 *     forge test --match-contract BSCForkCollectFees -vvv
 */
contract BSCForkCollectFees is BSCForkBase {
    function test_fork_collectsRealPancakeV4FeesAndKeepsListingLiquidityLocked() public onlyBscFork {
        Token token = _createAndListToken("FORKCOLLECT");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);
        PoolId poolId = poolKey.toId();

        assertEq(token.listingHook(), address(hook), "listing hook snapshot");
        assertEq(token.listingPoolParameters(), poolKey.parameters, "listing parameters snapshot");
        assertEq(PoolId.unwrap(token.v4PoolId()), PoolId.unwrap(poolId), "listing pool id");

        CLPosition.Info memory positionBefore = ICLPoolManager(CL_POOL_MANAGER)
            .getPosition(poolId, tokenAddr, LISTING_TICK_LOWER, LISTING_TICK_UPPER, bytes32(0));
        assertGt(positionBefore.liquidity, 0, "locked listing position missing");

        // BNB exact-in buy accrues currency0 LP fees; token exact-in sell accrues currency1 LP fees.
        uint256 tokensBought = _swapBuyExactIn(poolKey, buyer2, 20 ether);
        assertGt(tokensBought, 0, "buy did not execute");
        uint256 bnbReceived = _swapSellExactIn(poolKey, buyer2, tokensBought / 2);
        assertGt(bnbReceived, 0, "sell did not execute");

        // A normal platform Hook upgrade must not alter this already-listed token's PoolKey or fee destination.
        address replacementHook = makeAddr("forkReplacementHook");
        pump.adminSetHookAddress(replacementHook);

        address collector = makeAddr("forkFeeCollector");
        uint256 collectorBnbBefore = collector.balance;
        uint256 platformBnbBefore = FEE_RECEIVER.balance;
        uint256 listingHookTokenBefore = IERC20(tokenAddr).balanceOf(address(hook));
        uint256 replacementHookTokenBefore = IERC20(tokenAddr).balanceOf(replacementHook);
        uint256 tokenContractBnbBefore = tokenAddr.balance;
        uint256 tokenContractTokenBefore = IERC20(tokenAddr).balanceOf(tokenAddr);
        uint256 vaultBnbBefore = VAULT.balance;
        uint256 vaultTokenBefore = IERC20(tokenAddr).balanceOf(VAULT);

        vm.prank(collector);
        (uint256 bnbAmount, uint256 tokenAmount) = token.collectFees();

        assertGt(bnbAmount, 0, "no real BNB LP fees collected");
        assertGt(tokenAmount, 0, "no real token LP fees collected");

        uint256 callerReward = bnbAmount * token.COLLECT_CALLER_REWARD_BPS() / 10_000;
        assertEq(collector.balance - collectorBnbBefore, callerReward, "collector reward");
        assertEq(FEE_RECEIVER.balance - platformBnbBefore, bnbAmount - callerReward, "platform BNB fees");
        assertEq(
            IERC20(tokenAddr).balanceOf(address(hook)) - listingHookTokenBefore,
            tokenAmount,
            "token fees must reach snapshotted Hook"
        );
        assertEq(
            IERC20(tokenAddr).balanceOf(replacementHook),
            replacementHookTokenBefore,
            "replacement Hook must receive nothing"
        );
        assertEq(tokenAddr.balance, tokenContractBnbBefore, "Token must not retain collected BNB");
        assertEq(
            IERC20(tokenAddr).balanceOf(tokenAddr), tokenContractTokenBefore, "Token must not retain collected tokens"
        );
        assertEq(vaultBnbBefore - VAULT.balance, bnbAmount, "Vault BNB fee take");
        assertEq(vaultTokenBefore - IERC20(tokenAddr).balanceOf(VAULT), tokenAmount, "Vault token fee take");

        CLPosition.Info memory positionAfter = ICLPoolManager(CL_POOL_MANAGER)
            .getPosition(poolId, tokenAddr, LISTING_TICK_LOWER, LISTING_TICK_UPPER, bytes32(0));
        assertEq(positionAfter.liquidity, positionBefore.liquidity, "collect must not remove listing liquidity");
        assertEq(token.listingHook(), address(hook), "listing Hook changed after Pump upgrade");
        assertEq(PoolId.unwrap(token.v4PoolId()), PoolId.unwrap(poolId), "listing pool changed");

        uint256 collectorAfterFirst = collector.balance;
        uint256 platformAfterFirst = FEE_RECEIVER.balance;
        uint256 hookAfterFirst = IERC20(tokenAddr).balanceOf(address(hook));

        vm.prank(collector);
        (uint256 secondBnbAmount, uint256 secondTokenAmount) = token.collectFees();

        assertEq(secondBnbAmount, 0, "immediate second BNB collect must be empty");
        assertEq(secondTokenAmount, 0, "immediate second token collect must be empty");
        assertEq(collector.balance, collectorAfterFirst, "second collect changed caller balance");
        assertEq(FEE_RECEIVER.balance, platformAfterFirst, "second collect changed platform balance");
        assertEq(IERC20(tokenAddr).balanceOf(address(hook)), hookAfterFirst, "second collect changed Hook balance");
        assertEq(
            ICLPoolManager(CL_POOL_MANAGER)
            .getPosition(poolId, tokenAddr, LISTING_TICK_LOWER, LISTING_TICK_UPPER, bytes32(0))
            .liquidity,
            positionBefore.liquidity,
            "second collect changed liquidity"
        );
    }
}
