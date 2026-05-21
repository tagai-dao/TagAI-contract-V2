// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";

/**
 * @title BSCForkTest
 * @notice BSC mainnet fork tests mirroring production deployment.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkTest --fork-url "$BSC_RPC_URL" -vvv
 */
contract BSCForkTest is BSCForkBase {
    function test_fork_listingOnRealPCS() public onlyBscFork {
        Token token = _createAndListToken("FORKLIST");

        assertTrue(token.listed(), "token should be listed");
        assertEq(uint16(uint160(address(hook))), TARGET_HOOK_BITMAP, "hook bitmap");

        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice, int24 tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        assertTrue(sqrtPrice > 0, "pool sqrtPrice should be initialized");
        assertTrue(tick != 0 || sqrtPrice > 0, "pool should have state");

        assertEq(hook.poolToken(poolId), address(token), "hook pool mapping");
        (, uint96 remaining,) = hook.tokenInfo(address(token));
        assertEq(uint256(remaining), NUTBOX_ALLOCATION, "hook nutbox remaining");
        assertEq(IERC20(address(token)).balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox allocation");

        assertTrue(ICommittee(COMMITTEE).verifyContract(address(calculator)), "calculator whitelisted");
    }

    function test_fork_buySwap_triggersHookFeeAndInject() public onlyBscFork {
        Token token = _createAndListToken("FORKBUY");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 feeReceiverBalBefore = FEE_RECEIVER.balance;
        uint256 buyerTokenBefore = IERC20(tokenAddr).balanceOf(buyer);

        uint256 ethIn = 50 ether;
        vm.deal(buyer, ethIn);

        vm.prank(buyer);
        router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 tokensReceived = IERC20(tokenAddr).balanceOf(buyer) - buyerTokenBefore;
        assertTrue(tokensReceived > 0, "buy swap should deliver tokens");
        assertTrue(FEE_RECEIVER.balance > feeReceiverBalBefore, "platform fee collected on buy");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        if (tokensReceived >= MIN_INJECT_AMOUNT) {
            assertTrue(uint256(remainingAfter) < uint256(remainingBefore), "inject when above threshold");

            uint256 expectedInject = (tokensReceived * 20) / 10_000;
            if (expectedInject > NUTBOX_ALLOCATION) expectedInject = NUTBOX_ALLOCATION;
            assertEq(
                uint256(remainingBefore) - uint256(remainingAfter),
                expectedInject,
                "inject equals 0.2% of bought tokens"
            );
        } else {
            assertEq(uint256(remainingAfter), uint256(remainingBefore), "no inject below threshold");
        }
    }

    function test_fork_sellSwap_doesNotInject() public onlyBscFork {
        Token token = _createAndListToken("FORKSELL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint256 ethIn = 100 ether;
        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertTrue(tokenBal > 0, "buyer should hold tokens");

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);

        uint256 sellAmount = tokenBal / 2;
        vm.prank(buyer);
        IERC20(tokenAddr).approve(address(router), sellAmount);

        vm.prank(buyer);
        router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "sell should not inject nutbox tokens");
    }

    function test_fork_fullLifecycle_listAndSwapBothDirections() public onlyBscFork {
        Token token = _createAndListToken("FORKFULL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        router.swap{value: 5 ether}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
        assertTrue(IERC20(tokenAddr).balanceOf(buyer) > 0, "buyer received tokens");

        uint256 bal = IERC20(tokenAddr).balanceOf(buyer);
        vm.prank(buyer);
        IERC20(tokenAddr).approve(address(router), bal);
        vm.prank(buyer);
        router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bal / 4),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        assertEq(IERC20(tokenAddr).totalSupply(), 1_000_000_000 ether, "total supply invariant");
    }
}
