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
 * @dev V11 余额制注入：注入量用 calculator.totalInjected 校验，cap 用 hook 余额。
 *
 * Run:
 *   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkTest -vvv
 */
contract RHForkTest is RHForkBase {
    using PoolIdLibrary for PoolKey;

    function _injected(address tokenAddr) internal view returns (uint256) {
        return calculator.totalInjected(Token(payable(tokenAddr)).nutboxCommunity());
    }

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
        assertEq(IERC20(address(token)).balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox allocation");

        assertTrue(ICommittee(address(committee)).verifyContract(address(calculator)));
        assertGt(RH_POOL_MANAGER.code.length, 0);
    }

    function test_fork_buySwap_triggersHookFeeAndInject() public onlyRhFork {
        Token token = _createAndListToken("FORKBUY");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

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

        // Hook 累计的是毛成交额（含 0.3% token fee），用 periodState 读取作为注入档位输入。
        (, uint256 grossVolume) = _readPeriodState(tokenAddr);

        uint256 injected0 = _injected(tokenAddr);
        assertEq(_injected(tokenAddr), injected0, "same period: no inject");

        _warpToNextPeriod();
        _swapBuyExactIn(poolKey, buyer2, 2 ether);

        uint256 expectedInject = _capInjectAmount(
            _expectedPeriodSettleInject(grossVolume),
            IERC20(tokenAddr).balanceOf(address(hook))
        );

        if (expectedInject > 0) {
            assertEq(_injected(tokenAddr) - injected0, expectedInject, "inject on next-period first buy");
        } else {
            assertEq(_injected(tokenAddr), injected0, "below min: skip");
        }
    }

    function test_fork_sellSwap_doesNotInject() public onlyRhFork {
        Token token = _createAndListToken("FORKSELL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        _swapBuyExactIn(poolKey, buyer, 3 ether);
        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertGt(tokenBal, 0);

        uint256 injectedBefore = _injected(tokenAddr);
        _swapSellExactIn(poolKey, buyer, tokenBal / 2);
        assertEq(_injected(tokenAddr), injectedBefore, "sell never injects");
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
