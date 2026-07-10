// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {RHV4TestBase} from "./RHV4TestBase.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

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

    /// @dev Simulate pool buy volume for Nutbox period settlement (calls Hook.afterSwap as PoolManager).
    function _simulateHookBuy(Token token, uint256 boughtAmount) internal {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(boughtAmount)));

        vm.prank(address(manager));
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
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
