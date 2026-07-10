// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../src/pump/Token.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import "./RHForkBase.t.sol";

/**
 * @title RHForkTest
 * @notice RH mainnet fork integration tests against live Uniswap v4 PoolManager.
 *
 * Run:
 *   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkTest -vvv
 */
contract RHForkTest is RHForkBase {
    using PoolIdLibrary for PoolKey;

    function test_fork_listingOnRealPM() public onlyRhFork {
        Token token = _createAndListToken("FORKLIST");

        assertTrue(token.listed());
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), HOOK_FLAGS, "v4 hook flags");

        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice, int24 tick,,) = _slot0(poolId);
        assertGt(sqrtPrice, 0, "pool sqrtPrice initialized");
        assertGt(tick, LISTING_TICK_LOWER);
        assertLt(tick, LISTING_TICK_UPPER);

        assertEq(hook.poolToken(poolId), address(token));
        (, uint96 remaining,) = hook.tokenInfo(address(token));
        assertEq(uint256(remaining), NUTBOX_ALLOCATION);
        assertEq(IERC20(address(token)).balanceOf(address(hook)), NUTBOX_ALLOCATION);

        assertTrue(ICommittee(address(committee)).verifyContract(address(calculator)));
        assertGt(RH_POOL_MANAGER.code.length, 0);
    }

    function test_fork_buySwap_triggersHookFeeAndInject() public onlyRhFork {
        Token token = _createAndListToken("FORKBUY");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 feeReceiverBalBefore = feeRecipient.balance;
        uint256 buyerTokenBefore = IERC20(tokenAddr).balanceOf(buyer);

        uint256 ethIn = 5 ether;
        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        swapRouter.swap{value: ethIn}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 tokensReceived = IERC20(tokenAddr).balanceOf(buyer) - buyerTokenBefore;
        assertGt(tokensReceived, 0);
        assertGt(feeRecipient.balance, feeReceiverBalBefore, "platform fee collected");

        (, uint96 remainingAfterFirstBuy,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfterFirstBuy), uint256(remainingBefore), "same period: no inject");

        _warpToNextPeriod();
        _swapBuyExactIn(poolKey, buyer2, 2 ether);

        uint256 expectedInject =
            _capInjectAmount(_expectedPeriodSettleInject(tokensReceived), uint256(remainingBefore));

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        if (expectedInject > 0) {
            assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
            assertGt(calculator.totalInjected(token.nutboxCommunity()), 0);
        } else {
            assertEq(uint256(remainingAfter), uint256(remainingBefore));
        }
    }

    function test_fork_sellSwap_doesNotInject() public onlyRhFork {
        Token token = _createAndListToken("FORKSELL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 3 ether);
        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertGt(tokenBal, 0);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        _swapSellExactIn(poolKey, buyer, tokenBal / 2);

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore));
    }

    function test_fork_fullLifecycle_listAndSwapBothDirections() public onlyRhFork {
        Token token = _createAndListToken("FORKFULL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 1 ether);
        assertGt(IERC20(tokenAddr).balanceOf(buyer), 0);

        uint256 bal = IERC20(tokenAddr).balanceOf(buyer);
        _swapSellExactIn(poolKey, buyer, bal / 4);

        assertEq(IERC20(tokenAddr).totalSupply(), 1_000_000_000 ether);
    }
}
