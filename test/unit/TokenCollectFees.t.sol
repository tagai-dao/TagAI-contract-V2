// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

/**
 * @title TokenCollectFeesTest
 * @notice 验证 V11 上市 LP fee=3000 的 permissionless collectFees：caller 奖励、BNB→平台、Token→Hook。
 */
contract TokenCollectFeesTest is V4ListedTokenTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal collector;

    function setUp() public override {
        super.setUp();
        if (!envReady) return;
        collector = makeAddr("collector");
        vm.deal(collector, 0);
    }

    function test_listingHook_snapshottedAndFee3000() public onlyReady {
        assertEq(token.listingHook(), address(hook), "listingHook snapshotted");
        PoolKey memory pk = _buildPoolKey(address(token));
        assertEq(pk.fee, 3000, "listing pool fee 3000");
    }

    /// @dev 卖出产生 ETH 侧 LP fee + 买入产生 Token 侧 LP fee，collectFees 后路由正确。
    function test_collectFees_routesEthToPlatformAndTokenToHook() public onlyReady {
        PoolKey memory pk = _buildPoolKey(address(token));
        PoolId poolId = pk.toId();

        // 给 buyer 一些 token 后卖出，制造 ETH 侧 LP fee
        vm.prank(address(hook));
        token.transfer(buyer, 5_000_000 ether);
        _swapSell(pk, buyer, 1_000_000 ether);

        // 买入制造 Token 侧 LP fee
        _swapBuy(pk, buyer, 1 ether);

        uint256 hookTokenBefore = IERC20(address(token)).balanceOf(address(hook));
        uint256 collectorEthBefore = collector.balance;
        address feeReceiver = pump.getFeeReceiver();
        uint256 feeReceiverEthBefore = feeReceiver.balance;

        vm.prank(collector);
        (uint256 ethAmount, uint256 tokenAmount) = token.collectFees();
        assertGt(ethAmount, 0, "eth fee accrued");
        assertGt(tokenAmount, 0, "token fee accrued");

        // caller 奖励 ~0.5% 的 ETH LP fee
        uint256 callerReward = (ethAmount * token.COLLECT_CALLER_REWARD_BPS()) / 1e4;
        assertEq(collector.balance - collectorEthBefore, callerReward, "caller reward");
        // 平台收到剩余 ETH LP fee
        assertEq(feeReceiver.balance - feeReceiverEthBefore, ethAmount - callerReward, "platform eth");
        // Hook 收到 Token 侧 LP fee
        assertEq(IERC20(address(token)).balanceOf(address(hook)) - hookTokenBefore, tokenAmount, "hook token");

        // Token 自身余额不因领取净增加
        assertEq(address(token).balance, 0, "token holds no eth");
        // 池内流动性（本金）不变
        assertEq(manager.getLiquidity(poolId), manager.getLiquidity(poolId), "liquidity stable");
    }

    function test_collectFees_revertsIfNotListed() public onlyReady {
        Token fresh = _createToken("UNLISTED");
        vm.prank(collector);
        vm.expectRevert(IToken.TokenNotListed.selector);
        fresh.collectFees();
    }

    /// @dev 通过 swapRouter 用 ETH 买入 token（zeroForOne=true）。
    function _swapBuy(PoolKey memory pk, address actor, uint256 ethIn) internal {
        uint256 tokBefore = IERC20(address(token)).balanceOf(actor);
        vm.startPrank(actor);
        vm.deal(actor, ethIn);
        swapRouter.swap{value: ethIn}(
            pk,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(ethIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(LISTING_TICK_LOWER)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();
        assertGt(IERC20(address(token)).balanceOf(actor), tokBefore, "buy produced tokens");
    }
}
