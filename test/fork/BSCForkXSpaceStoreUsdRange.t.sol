// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkXSpaceStoreBase.t.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/**
 * @title BSCForkXSpaceStoreUsdRangeTest
 * @notice USD-priced concentrated liquidity scenario on BSC fork.
 *
 * Scenario:
 *   - Token spot ≈ $167, BNB ≈ $600
 *   - LP range $160–$177
 *   - In-range buy/sell
 *   - Verify price can break below $160 (snapshot probe)
 *   - Push above $177, remove LP, re-add ±$10 band around new spot, buy/sell again
 *
 *   test_fork_xspace_dropTo160_relp200_220_trade:
 *   - Drop to ~$160, remove LP, add $200–$220 LP, push into range, trade
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkXSpaceStoreUsdRangeTest --fork-url "$BSC_RPC_URL" -vvv
 */
contract BSCForkXSpaceStoreUsdRangeTest is BSCForkXSpaceStoreBase {
    uint256 internal constant TOKEN_USD_INIT = 167e18;
    uint256 internal constant TOKEN_USD_LOW = 160e18;
    uint256 internal constant TOKEN_USD_HIGH = 177e18;
    uint256 internal constant TOKEN_USD_200 = 200e18;
    uint256 internal constant TOKEN_USD_210 = 210e18;
    uint256 internal constant TOKEN_USD_220 = 220e18;
    uint256 internal constant USD_BAND = 10e18;

    uint256 internal constant LP_BNB = 30 ether;
    uint256 internal constant IN_RANGE_BUY_ETH = 0.5 ether;
    uint256 internal constant IN_RANGE_SELL_TOKEN = 2 ether;

    int24 internal constant TICK_SLACK = 300;

    int24 internal tickLowerRange1;
    int24 internal tickUpperRange1;

    function setUp() public override {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkReady = false;
            return;
        }

        vm.createSelectFork(rpc);
        if (block.chainid != 56) {
            forkReady = false;
            return;
        }

        forkReady = true;

        lpProvider = makeAddr("xspaceLpProvider");
        trader = makeAddr("xspaceTrader");
        ipshareSubject = makeAddr("xspaceIpshareSubject");

        hook = _deployHookWithValidBitmap();
        router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));

        poolKey = _buildPoolKey();
        poolId = poolKey.toId();

        // $177 → lower tick; $160 → upper tick (more tokens/BNB = higher tick)
        tickLowerRange1 = _tickFromTokenUsd(TOKEN_USD_HIGH);
        tickUpperRange1 = _tickFromTokenUsd(TOKEN_USD_LOW);
        assertEq(_b(tickLowerRange1 < tickUpperRange1), 1, "tick order");

        int24 initTick = _tickFromTokenUsd(TOKEN_USD_INIT);
        initialSqrtPriceX96 = TickMath.getSqrtRatioAtTick(initTick);
        ICLPoolManager(CL_POOL_MANAGER).initialize(poolKey, initialSqrtPriceX96);

        _ensureIPShare(ipshareSubject);
    }

    function test_fork_xspace_usdRange_fullScenario() public onlyBscFork {
        // ── 1) Init price ≈ $167 (tick-aligned) ───────────────────────────────
        int24 initTick = _tickFromTokenUsd(TOKEN_USD_INIT);
        assertEq(_currentSqrtPrice(), initialSqrtPriceX96, "init sqrt price");
        assertEq(_currentTick(), initTick, "init tick");
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange1, tickUpperRange1)), 1, "init spot in range");

        // ── 2) Add LP in $160–$177 band ─────────────────────────────────────
        uint256 tokenBudget = FullMath.mulDiv(LP_BNB, BNB_USD, TOKEN_USD_INIT);
        (uint128 liquidity1,,) = _addLiquidityAtTicks(tickLowerRange1, tickUpperRange1, LP_BNB, tokenBudget);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity1, "liquidity after range1 add");
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange1, tickUpperRange1)), 1, "spot in range after add");

        // ── 3) In-range buy / sell ──────────────────────────────────────────
        uint256 feeBeforeBuy = FEE_RECEIVER.balance;
        uint256 traderTokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);
        BalanceDelta buyDelta = _swapBuyExactEth(trader, IN_RANGE_BUY_ETH);

        assertEq(FEE_RECEIVER.balance - feeBeforeBuy, _hookFeeOnEthSpecified(IN_RANGE_BUY_ETH), "in-range buy hook fee");
        assertEq(
            IERC20(XSPACE_TOKEN).balanceOf(trader) - traderTokenBefore,
            uint256(uint128(buyDelta.amount1())),
            "in-range buy token delta"
        );
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange1, tickUpperRange1)), 1, "still in range after buy");

        uint256 sellAmount = IN_RANGE_SELL_TOKEN;
        _fundToken(trader, sellAmount);
        uint256 sellFeeBefore = FEE_RECEIVER.balance;
        BalanceDelta sellDelta = _swapSellExactToken(trader, sellAmount);
        uint256 ethNet = uint256(uint128(sellDelta.amount0()));

        assertEq(FEE_RECEIVER.balance - sellFeeBefore, _hookFeeOnEthGrossFromNet(ethNet), "in-range sell hook fee");
        assertEq(uint256(uint128(-sellDelta.amount1())), sellAmount, "in-range sell token delta");
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange1, tickUpperRange1)), 1, "still in range after sell");
        assertEq(address(hook).balance, 0, "hook empty after in-range trades");

        // ── 3b) Probe: price can break below $160 (revert state after check) ─
        uint256 snapBeforeBreak = vm.snapshotState();
        address probeSeller = makeAddr("probeSeller");
        _fundToken(probeSeller, 5000 ether);
        _swapSellExactToken(probeSeller, 5000 ether);
        assertEq(_b(_currentTick() >= tickUpperRange1), 1, "can break below 160 usd");
        vm.revertToState(snapBeforeBreak);

        // ── 4) Push above $177 (buy from in-range; controlled band) ──────────
        uint256 pushUpEth = _pushTickToBandBelow(tickLowerRange1);
        assertEq(_b(_tickInBandBelow(_currentTick(), tickLowerRange1)), 1, "tick at or above 177 usd bound");

        // ── 5) Remove all liquidity from range 1 ────────────────────────────
        _removeLiquidityAtTicks(tickLowerRange1, tickUpperRange1, liquidity1);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), 0, "all liquidity removed");

        // ── 6) New spot ± $10 band LP (tick-centered; ~400 ticks ≈ $10 at $177) ─
        int24 spotTick = _currentTick();
        uint256 newSpotUsd = _tokenUsdFromSqrtPrice(_currentSqrtPrice());
        assertEq(_b(newSpotUsd >= USD_BAND), 1, "spot usd supports -10 band");

        uint256 bandLowUsd = newSpotUsd - USD_BAND;
        uint256 bandHighUsd = newSpotUsd + USD_BAND;

        int24 halfBandTicks = 400;
        int24 tickLowerRange2 = _alignTickDown(spotTick - halfBandTicks);
        int24 tickUpperRange2 = _alignTickUp(spotTick + halfBandTicks);
        assertEq(_b(tickLowerRange2 < tickUpperRange2), 1, "range2 tick order");
        assertEq(_b(_tickInRange(spotTick, tickLowerRange2, tickUpperRange2)), 1, "spot in new range before add");

        uint256 tokenBudget2 = FullMath.mulDiv(LP_BNB, BNB_USD, newSpotUsd);
        (uint128 liquidity2,,) = _addLiquidityAtTicks(tickLowerRange2, tickUpperRange2, LP_BNB, tokenBudget2);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity2, "liquidity after range2 add");
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange2, tickUpperRange2)), 1, "spot in new range");

        // ── 7) Buy / sell again on new range ────────────────────────────────
        feeBeforeBuy = FEE_RECEIVER.balance;
        traderTokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);
        buyDelta = _swapBuyExactEth(trader, IN_RANGE_BUY_ETH);

        assertEq(FEE_RECEIVER.balance - feeBeforeBuy, _hookFeeOnEthSpecified(IN_RANGE_BUY_ETH), "range2 buy hook fee");
        assertEq(
            IERC20(XSPACE_TOKEN).balanceOf(trader) - traderTokenBefore,
            uint256(uint128(buyDelta.amount1())),
            "range2 buy token delta"
        );

        sellAmount = IN_RANGE_SELL_TOKEN;
        _fundToken(trader, sellAmount);
        sellFeeBefore = FEE_RECEIVER.balance;
        sellDelta = _swapSellExactToken(trader, sellAmount);
        ethNet = uint256(uint128(sellDelta.amount0()));

        assertEq(FEE_RECEIVER.balance - sellFeeBefore, _hookFeeOnEthGrossFromNet(ethNet), "range2 sell hook fee");
        assertEq(_b(ethNet > 0), 1, "range2 sell received eth");
        assertEq(address(hook).balance, 0, "hook empty end");

        assertEq(pushUpEth, pushUpEth, "pushUpEth recorded");
        assertEq(bandLowUsd + USD_BAND, newSpotUsd, "band low identity");
        assertEq(bandHighUsd - USD_BAND, newSpotUsd, "band high identity");
    }

    /// @notice Price drops to ~$160, remove LP, re-add at $200–$220, push in-range, trade.
    function test_fork_xspace_dropTo160_relp200_220_trade() public onlyBscFork {
        // ── 1) Init + LP $160–$177 at ~$167 ───────────────────────────────────
        int24 initTick = _tickFromTokenUsd(TOKEN_USD_INIT);
        assertEq(_currentTick(), initTick, "init tick");

        uint256 tokenBudget = FullMath.mulDiv(LP_BNB, BNB_USD, TOKEN_USD_INIT);
        (uint128 liquidity1,,) = _addLiquidityAtTicks(tickLowerRange1, tickUpperRange1, LP_BNB, tokenBudget);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity1, "liquidity after range1 add");

        // ── 2) Push price down to ~$160 ─────────────────────────────────────
        _pushTickNearTarget(tickUpperRange1);
        assertEq(_b(_tickNearTarget(_currentTick(), tickUpperRange1)), 1, "spot near 160 usd");

        // ── 3) Remove all range-1 liquidity ─────────────────────────────────
        _removeLiquidityAtTicks(tickLowerRange1, tickUpperRange1, liquidity1);
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), 0, "all liquidity removed");

        // ── 4) Add LP in $200–$220 (spot still ~$160, below new range) ────────
        int24 tickLowerRange2 = _tickFromTokenUsd(TOKEN_USD_220);
        int24 tickUpperRange2 = _tickFromTokenUsd(TOKEN_USD_200);
        assertEq(_b(tickLowerRange2 < tickUpperRange2), 1, "range2 tick order");
        assertEq(_b(_currentTick() > tickUpperRange2), 1, "spot below 200-220 range before add");

        uint256 tokenBudget2 = FullMath.mulDiv(LP_BNB, BNB_USD, TOKEN_USD_210);
        (uint128 liquidity2,,) = _addLiquidityAtTicks(tickLowerRange2, tickUpperRange2, LP_BNB, tokenBudget2);
        assertEq(_b(liquidity2 > 0), 1, "range2 liquidity minted");
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), 0, "no active liq until price enters range");

        // ── 5) Buy up into $200–$220 range (~$210 center) ─────────────────────
        int24 tickMid210 = _tickFromTokenUsd(TOKEN_USD_210);
        uint256 pushUpEth = _pushTickToBandBelow(tickMid210);
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange2, tickUpperRange2)), 1, "spot in 200-220 range");
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity2, "active liquidity in range");

        // ── 6) Buy / sell inside $200–$220 range ─────────────────────────────
        uint256 feeBeforeBuy = FEE_RECEIVER.balance;
        uint256 traderTokenBefore = IERC20(XSPACE_TOKEN).balanceOf(trader);
        BalanceDelta buyDelta = _swapBuyExactEth(trader, IN_RANGE_BUY_ETH);

        assertEq(FEE_RECEIVER.balance - feeBeforeBuy, _hookFeeOnEthSpecified(IN_RANGE_BUY_ETH), "range2 buy hook fee");
        assertEq(
            IERC20(XSPACE_TOKEN).balanceOf(trader) - traderTokenBefore,
            uint256(uint128(buyDelta.amount1())),
            "range2 buy token delta"
        );
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange2, tickUpperRange2)), 1, "still in range after buy");

        uint256 sellAmount = IN_RANGE_SELL_TOKEN;
        _fundToken(trader, sellAmount);
        uint256 sellFeeBefore = FEE_RECEIVER.balance;
        BalanceDelta sellDelta = _swapSellExactToken(trader, sellAmount);
        uint256 ethNet = uint256(uint128(sellDelta.amount0()));

        assertEq(FEE_RECEIVER.balance - sellFeeBefore, _hookFeeOnEthGrossFromNet(ethNet), "range2 sell hook fee");
        assertEq(uint256(uint128(-sellDelta.amount1())), sellAmount, "range2 sell token delta");
        assertEq(_b(_tickInRange(_currentTick(), tickLowerRange2, tickUpperRange2)), 1, "still in range after sell");
        assertEq(address(hook).balance, 0, "hook empty end");

        assertEq(pushUpEth, pushUpEth, "pushUpEth recorded");
    }

    /// @dev Push tick into [target - slack, target + slack].
    function _pushTickNearTarget(int24 targetTick) internal {
        if (_currentTick() < targetTick - TICK_SLACK) {
            _sellUntilTickAtLeast(targetTick);
        }
        if (_currentTick() > targetTick + TICK_SLACK) {
            _buyUntilTickNearTarget(targetTick);
        }
        assertEq(_b(_tickNearTarget(_currentTick(), targetTick)), 1, "failed to reach target tick band");
    }

    /// @dev Sell until tick first reaches `targetTick`.
    function _sellUntilTickAtLeast(int24 targetTick) internal {
        address actor = makeAddr("pushDownSeller");
        uint256 step = 0.05 ether;

        for (uint256 i = 0; i < 20_000; i++) {
            if (_currentTick() >= targetTick) break;
            _fundToken(actor, step);
            _swapSellExactToken(actor, step);
        }

        assertEq(_b(_currentTick() >= targetTick), 1, "failed to push tick above target");
    }

    /// @dev Binary-search BNB buy to land tick in [target - slack, target + slack].
    function _buyUntilTickNearTarget(int24 targetTick) internal {
        address actor = makeAddr("buyBack");
        uint256 snap = vm.snapshotState();

        uint256 lo = 0;
        uint256 hi = 500 ether;

        while (lo + 0.01 ether < hi) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);

            if (mid > 0) {
                _swapBuyExactEth(actor, mid);
            }

            int24 tick = _currentTick();
            if (_tickNearTarget(tick, targetTick)) {
                hi = mid;
            } else if (tick > targetTick + TICK_SLACK) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        vm.revertToState(snap);
        if (hi > 0) {
            _swapBuyExactEth(actor, hi);
        }

        assertEq(_b(_tickNearTarget(_currentTick(), targetTick)), 1, "buy back to target band failed");
    }

    function _tickNearTarget(int24 tick, int24 target) internal pure returns (bool) {
        return tick >= target - TICK_SLACK && tick <= target + TICK_SLACK;
    }

    /// @dev Buy BNB until tick lands in [target - slack, target] (token price ≥ ~$177).
    function _pushTickToBandBelow(int24 targetTick) internal returns (uint256 totalEthSpent) {
        address actor = makeAddr("pushUpBuyer");
        uint256 step = 0.02 ether;

        for (uint256 i = 0; i < 3000; i++) {
            if (_tickInBandBelow(_currentTick(), targetTick)) break;
            _swapBuyExactEth(actor, step);
            totalEthSpent += step;
        }

        assertEq(_b(_tickInBandBelow(_currentTick(), targetTick)), 1, "failed to push tick below target band");
    }

    function _alignTickDown(int24 tick) internal pure returns (int24) {
        int24 spacing = 10;
        int24 r = tick % spacing;
        if (r == 0) return tick;
        if (tick < 0) return tick - r;
        return tick - r;
    }

    function _alignTickUp(int24 tick) internal pure returns (int24) {
        int24 spacing = 10;
        int24 r = tick % spacing;
        if (r == 0) return tick;
        if (tick < 0) return tick - r + spacing;
        return tick - r + spacing;
    }

    function _tickInBandBelow(int24 tick, int24 target) internal pure returns (bool) {
        return tick <= target && tick >= target - TICK_SLACK;
    }

    function _tickInRange(int24 tick, int24 lower, int24 upper) internal pure returns (bool) {
        return tick >= lower && tick <= upper;
    }

    function _b(bool v) internal pure returns (uint256) {
        return v ? 1 : 0;
    }
}
