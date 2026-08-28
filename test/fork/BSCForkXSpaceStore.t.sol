// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkXSpaceStoreBase.t.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

/**
 * @title BSCForkXSpaceStoreTest
 * @notice BSC mainnet fork integration tests for XSpaceStoreHook + external token pool.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkXSpaceStoreTest --fork-url "$BSC_RPC_URL" -vvv
 */
contract BSCForkXSpaceStoreTest is BSCForkXSpaceStoreBase {
    uint256 internal constant LP_ETH = 5 ether;
    uint256 internal constant LP_TOKEN = 5 ether;
    uint256 internal constant BUY_ETH = 1 ether;
    uint256 internal constant SELL_TOKEN = 1 ether;

    function test_fork_xspace_poolInitialized() public onlyBscFork {
        assertEq(hook.poolToken(poolId), XSPACE_TOKEN, "pool token mapping");
        assertEq(hook.token(), XSPACE_TOKEN, "hook token");
        assertEq(hook.feeReceiver(), FEE_RECEIVER, "fee receiver");
        assertEq(hook.ipshare(), IPSHARE, "ipshare contract");
        assertEq(hook.TICK_SPACING(), 10, "tick spacing");
        assertEq(hook.RECOMMENDED_LP_FEE_PIPS(), 4000, "lp fee pips");
        assertEq(poolKey.fee, 40, "pool key lp fee");

        (uint160 sqrtPrice, int24 tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        assertEq(sqrtPrice, initialSqrtPriceX96, "initial sqrt price");
        assertEq(tick, 0, "initial tick");
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), 0, "liquidity before seed");
        assertEq(address(hook).balance, 0, "hook eth balance");
    }

    function test_fork_xspace_addLiquidity_exact() public onlyBscFork {
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(TICK_UPPER);
        uint128 expectedLiquidity = _liquidityForAmounts(initialSqrtPriceX96, sqrtLower, sqrtUpper, LP_ETH, LP_TOKEN);
        (uint256 expectedEth, uint256 expectedToken) =
            _amountsForLiquidity(initialSqrtPriceX96, sqrtLower, sqrtUpper, expectedLiquidity);

        (uint128 liquidity, uint256 spentEth, uint256 spentToken) = _seedLiquidity(LP_ETH, LP_TOKEN);

        assertEq(liquidity, expectedLiquidity, "liquidity amount");
        assertEq(spentEth, expectedEth, "spent eth");
        assertEq(spentToken, expectedToken, "spent token");
        assertEq(IERC20(XSPACE_TOKEN).balanceOf(lpProvider), 0, "lp provider token balance");
        assertEq(lpProvider.balance, 0, "lp provider eth balance");
        assertEq(liquidity, seededLiquidity, "seeded liquidity recorded");
    }

    function test_fork_xspace_removeLiquidity_exact() public onlyBscFork {
        (uint128 liquidity,,) = _seedLiquidity(LP_ETH, LP_TOKEN);
        uint128 removeLiquidity = liquidity / 2;

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(TICK_UPPER);
        (uint256 expectedEthOut, uint256 expectedTokenOut) =
            _amountsForLiquidity(initialSqrtPriceX96, sqrtLower, sqrtUpper, removeLiquidity, false);

        uint256 ethBefore = lpProvider.balance;
        uint256 tokenBefore = IERC20(XSPACE_TOKEN).balanceOf(lpProvider);

        vm.prank(lpProvider);
        (BalanceDelta delta,) = router.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(removeLiquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        assertEq(uint256(uint128(delta.amount0())), expectedEthOut, "remove LP eth delta");
        assertEq(uint256(uint128(delta.amount1())), expectedTokenOut, "remove LP token delta");
        assertEq(lpProvider.balance - ethBefore, expectedEthOut, "lp provider eth received");
        assertEq(IERC20(XSPACE_TOKEN).balanceOf(lpProvider) - tokenBefore, expectedTokenOut, "lp provider token received");
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity - removeLiquidity, "pool liquidity after remove");
    }

    function test_fork_xspace_buy_exactHookFee_noIPShare() public onlyBscFork {
        _seedLiquidity(LP_ETH, LP_TOKEN);

        uint256 feeBefore = FEE_RECEIVER.balance;
        uint256 tokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);
        uint256 expectedHookFee = _hookFeeOnEthSpecified(BUY_ETH);

        vm.deal(trader, BUY_ETH);
        vm.prank(trader);
        BalanceDelta delta = router.swap{value: BUY_ETH}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY_ETH),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 tokensOut = IERC20(XSPACE_TOKEN).balanceOf(trader) - tokenBefore;
        uint256 feeCollected = FEE_RECEIVER.balance - feeBefore;

        assertEq(feeCollected, expectedHookFee, "buy hook fee to platform");
        assertEq(feeCollected, (BUY_ETH * HOOK_FEE_BPS) / FEE_DIVISOR, "buy hook fee formula");
        assertEq(tokensOut, uint256(uint128(delta.amount1())), "buy token delta matches balance");
        assertEq(address(hook).balance, 0, "hook eth balance after buy");
    }

    function test_fork_xspace_buy_exactHookFee_withIPShare() public onlyBscFork {
        _seedLiquidity(LP_ETH, LP_TOKEN);

        uint256 feeBefore = FEE_RECEIVER.balance;
        uint256 subjectEthBefore = ipshareSubject.balance;
        uint256 supplyBefore = IIPShare(IPSHARE).ipshareSupply(ipshareSubject);
        uint256 expectedPlatformFee = (BUY_ETH * PLATFORM_FEE_BPS) / FEE_DIVISOR;
        uint256 expectedIpShareFee = (BUY_ETH * IPSHARE_FEE_BPS) / FEE_DIVISOR;
        (uint256 protocolFee, uint256 subjectFee, uint256 expectedShares) =
            _expectedIPShareValueCapture(expectedIpShareFee, supplyBefore);

        vm.deal(trader, BUY_ETH);
        vm.prank(trader);
        router.swap{value: BUY_ETH}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY_ETH),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(ipshareSubject)
        );

        assertEq(FEE_RECEIVER.balance - feeBefore, expectedPlatformFee + protocolFee, "buy platform + ipshare protocol fee");
        assertEq(ipshareSubject.balance - subjectEthBefore, subjectFee, "buy ipshare subject fee");
        assertEq(
            IIPShare(IPSHARE).ipshareSupply(ipshareSubject) - supplyBefore,
            expectedShares,
            "buy ipshare supply increase"
        );
        assertEq(expectedPlatformFee + expectedIpShareFee, _hookFeeOnEthSpecified(BUY_ETH), "buy total hook fee split");
        assertEq(address(hook).balance, 0, "hook eth balance after buy with ipshare");
    }

    function test_fork_xspace_sell_exactHookFee_noIPShare() public onlyBscFork {
        _seedLiquidity(LP_ETH, LP_TOKEN);
        _fundToken(trader, SELL_TOKEN);

        uint256 feeBefore = FEE_RECEIVER.balance;
        uint256 tokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);

        vm.startPrank(trader);
        IERC20(XSPACE_TOKEN).approve(address(router), SELL_TOKEN);
        BalanceDelta delta = router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(SELL_TOKEN),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
        vm.stopPrank();

        uint256 ethNet = uint256(uint128(delta.amount0()));
        uint256 feeCollected = FEE_RECEIVER.balance - feeBefore;
        uint256 expectedHookFee = _hookFeeOnEthGrossFromNet(ethNet);

        assertEq(tokenBefore - IERC20(XSPACE_TOKEN).balanceOf(trader), SELL_TOKEN, "sell token spent");
        assertEq(uint256(uint128(-delta.amount1())), SELL_TOKEN, "sell token delta");
        assertEq(feeCollected, expectedHookFee, "sell hook fee to platform");
        assertEq(feeCollected, (ethNet * HOOK_FEE_BPS) / (FEE_DIVISOR - HOOK_FEE_BPS), "sell hook fee formula");
        assertEq(address(hook).balance, 0, "hook eth balance after sell");
    }

    function test_fork_xspace_fullLifecycle_exact() public onlyBscFork {
        // 1) Add liquidity
        (uint128 liquidity,,) = _seedLiquidity(LP_ETH, LP_TOKEN);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity, "lifecycle liquidity after add");

        // 2) Buy with exact hook fee (no IPShare)
        uint256 buyFeeBefore = FEE_RECEIVER.balance;
        uint256 traderTokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);
        uint256 buyHookFeeExpected = _hookFeeOnEthSpecified(BUY_ETH);

        vm.deal(trader, BUY_ETH);
        vm.prank(trader);
        BalanceDelta buyDelta = router.swap{value: BUY_ETH}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY_ETH),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 buyTokens = IERC20(XSPACE_TOKEN).balanceOf(trader) - traderTokenBefore;
        assertEq(FEE_RECEIVER.balance - buyFeeBefore, buyHookFeeExpected, "lifecycle buy hook fee");
        assertEq(buyTokens, uint256(uint128(buyDelta.amount1())), "lifecycle buy token delta");

        // 3) Sell exact amount of received tokens
        uint256 sellAmount = buyTokens;
        uint256 sellFeeBefore = FEE_RECEIVER.balance;
        uint256 traderTokenBeforeSell = IERC20(XSPACE_TOKEN).balanceOf(trader);

        vm.startPrank(trader);
        IERC20(XSPACE_TOKEN).approve(address(router), sellAmount);
        BalanceDelta sellDelta = router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
        vm.stopPrank();

        uint256 ethNet = uint256(uint128(sellDelta.amount0()));
        uint256 sellHookFeeExpected = _hookFeeOnEthGrossFromNet(ethNet);

        assertEq(FEE_RECEIVER.balance - sellFeeBefore, sellHookFeeExpected, "lifecycle sell hook fee");
        assertEq(traderTokenBeforeSell - IERC20(XSPACE_TOKEN).balanceOf(trader), sellAmount, "lifecycle sell token spent");
        assertEq(uint256(uint128(-sellDelta.amount1())), sellAmount, "lifecycle sell token delta");

        // 4) Remove one quarter of remaining LP (use swap delta as exact expected amounts)
        uint128 liquidityBefore = ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId);
        uint128 removeLiquidity = liquidityBefore / 4;

        uint256 lpEthBefore = lpProvider.balance;
        uint256 lpTokenBefore = IERC20(XSPACE_TOKEN).balanceOf(lpProvider);

        vm.prank(lpProvider);
        (BalanceDelta removeDelta,) = router.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(removeLiquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        uint256 ethOut = uint256(uint128(removeDelta.amount0()));
        uint256 tokenOut = uint256(uint128(removeDelta.amount1()));

        assertEq(ethOut, lpProvider.balance - lpEthBefore, "lifecycle remove eth received");
        assertEq(tokenOut, IERC20(XSPACE_TOKEN).balanceOf(lpProvider) - lpTokenBefore, "lifecycle remove token received");
        assertEq(
            ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId),
            liquidityBefore - removeLiquidity,
            "lifecycle pool liquidity after remove"
        );
        assertEq(address(hook).balance, 0, "hook eth balance end of lifecycle");
    }
}
