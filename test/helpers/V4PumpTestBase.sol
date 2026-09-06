// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {RHV4TestBase} from "./RHV4TestBase.sol";
import {Token} from "../../src/pump/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @dev Uniswap v4 harness for Pump / Token / Hook unit tests (local PoolManager + CREATE2 hook).
abstract contract V4PumpTestBase is RHV4TestBase {
    uint256 internal constant HOOK_PERIOD_LENGTH = 600;
    uint256 internal constant HOOK_MAX_PERIOD_BUY = 420_000_000 ether;
    uint256 internal constant HOOK_RATIO_SCALE = 1e9;
    uint256 internal constant HOOK_TIER0_RATIO_PPM = 106_069_772;
    uint256 internal constant HOOK_TIER1_RATIO_PPM = 53_034_886;

    uint256 internal constant HOOK_MIN_INJECT_OUTPUT = 168 ether / 10;

    address internal deployer;
    address internal claimSigner;

    function setUp() public virtual override {
        deployer = address(this);
        claimSigner = makeAddr("claimSigner");
        super.setUp();
        if (!envReady) return;

        vm.deal(deployer, 1000 ether);
        if (_zeroIpShareCreateFee()) {
            ipshare.adminSetCreateFee(0);
        }
        ipshare.adminStartTrade();
        vm.warp(3600);
    }

    function _zeroIpShareCreateFee() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Simulate pool buy via real swapRouter (exact-in ETH) — runs Hook.beforeSwap/afterSwap inside PoolManager unlock, so token-fee `take` 正常工作。返回该次买入的**毛** token 成交额（即 Hook 累计到 periodBuy 的值，含 0.3% token fee）。用 periodState 前后差值推算，并处理跨周期重置。
    function _simulateHookBuy(Token token, uint256 ethIn) internal returns (uint256 grossVolume) {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        (uint32 idxBefore, uint256 pbBefore) = hook.periodState(address(token));
        vm.deal(address(this), address(this).balance + ethIn);
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
        (uint32 idxAfter, uint256 pbAfter) = hook.periodState(address(token));
        // 跨周期：periodBuy 重置为 0 后累加本次毛额 → gross = pbAfter；同期：gross = 差值。
        grossVolume = (idxAfter != idxBefore) ? pbAfter : (pbAfter - pbBefore);
    }

    /// @dev Simulate token→ETH sell path (exact-output ETH) — no Nutbox inject, no PoolManager.take.
    function _simulateHookSell(Token token, uint256) internal {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, int128(int256(10_000 ether)));

        vm.prank(address(manager));
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
    }

    function _warpNextHookPeriod() internal {
        vm.warp(block.timestamp + HOOK_PERIOD_LENGTH);
    }

    function _expectedHookSettleInject(uint256 periodVolume) internal view returns (uint256) {
        (,, uint256 injectAmount) = hook.previewPeriodSettle(periodVolume);
        if (injectAmount < HOOK_MIN_INJECT_OUTPUT) return 0;
        return injectAmount;
    }

    function _minPeriodVolumeForSettle() internal pure returns (uint256) {
        return (HOOK_MIN_INJECT_OUTPUT * HOOK_RATIO_SCALE + HOOK_TIER0_RATIO_PPM - 1) / HOOK_TIER0_RATIO_PPM;
    }
}
