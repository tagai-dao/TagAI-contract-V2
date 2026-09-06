// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

import {Token} from "../../src/pump/Token.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {RHV4TestBase} from "../helpers/RHV4TestBase.sol";

/// @dev RH mainnet fork harness: live Uniswap v4 PoolManager + locally deployed Nutbox/Pump/Hook.
abstract contract RHForkBase is RHV4TestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev RH mainnet Uniswap v4 PoolManager
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    uint256 internal constant RATIO_SCALE = 1e9;
    uint256 internal constant PERIOD_LENGTH = 600;
    uint256 internal constant MIN_INJECT_OUTPUT = 168 ether / 10;
    uint256 internal constant MAX_LISTING_DUST = 1 ether;

    address internal buyer2;

    function setUp() public virtual override {
        buyer2 = makeAddr("forkBuyer2");
        super.setUp();
        if (!envReady) return;
        vm.deal(buyer2, 50_000 ether);
    }

    modifier onlyRhFork() {
        if (!envReady) vm.skip(true);
        _;
    }

    /// @dev Select RH mainnet fork when live PM bytecode is not already present (e.g. anvil default).
    function _bootstrapPoolManager() internal virtual override returns (bool) {
        if (RH_POOL_MANAGER.code.length > 0) {
            manager = IPoolManager(RH_POOL_MANAGER);
            swapRouter = new PoolSwapTest(manager);
            return true;
        }

        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;

        vm.createSelectFork(rpc);
        if (RH_POOL_MANAGER.code.length == 0) return false;

        manager = IPoolManager(RH_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        return true;
    }

    function _createAndListToken(string memory tick) internal override returns (Token token) {
        token = _createAndListTokenWithBuyer(tick, buyer);
    }

    function _createAndListTokenWithBuyer(string memory tick, address actor) internal returns (Token token) {
        _ensureCreatorIPShare();
        uint256 totalFee = pump.createFee() + 1 ether;
        vm.deal(creator, totalFee + 100 ether);
        vm.prank(creator, creator);
        address tokenAddr =
            pump.createToken{value: totalFee}(tick, keccak256(abi.encodePacked(tick, block.timestamp)));
        token = Token(payable(tokenAddr));
        _fillBondingCurveUntilListed(token, actor);
        assertTrue(token.listed(), "listing failed on RH PM");
    }

    /// @dev No pre-mine: single account fills curve + receives Hook 150M → exactly 800M external sellable.
    function _createAndListForWhale(string memory tick, address whale) internal returns (Token token) {
        _ensureCreatorIPShare();

        uint256 totalFixedFee = pump.createFee();
        vm.deal(creator, totalFixedFee);
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: totalFixedFee}(
            tick, keccak256(abi.encodePacked("whale", tick, block.timestamp))
        );
        token = Token(payable(tokenAddr));

        _fillBondingCurveUntilListed(token, whale);
        assertEq(token.bondingCurveSupply(), BONDING_CURVE_TOTAL, "curve fully sold");
        assertEq(IERC20(tokenAddr).balanceOf(whale), BONDING_CURVE_TOTAL, "whale holds 650M");

        vm.prank(address(hook));
        IERC20(tokenAddr).transfer(whale, NUTBOX_ALLOCATION);

        assertEq(IERC20(tokenAddr).balanceOf(whale), EXTERNAL_SELLABLE, "whale holds 800M");
        assertEq(IERC20(tokenAddr).balanceOf(address(hook)), 0, "hook emptied");
        assertLe(IERC20(tokenAddr).balanceOf(tokenAddr), MAX_LISTING_DUST, "listing dust <= 1 token");
    }

    function _swapBuyExactIn(PoolKey memory poolKey, address actor, uint256 ethIn)
        internal
        returns (uint256 tokensReceived)
    {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 before = IERC20(tokenAddr).balanceOf(actor);
        vm.deal(actor, actor.balance + ethIn);

        vm.startPrank(actor);
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
        vm.stopPrank();

        return IERC20(tokenAddr).balanceOf(actor) - before;
    }

    function _swapSellExactIn(PoolKey memory poolKey, address actor, uint256 tokenIn)
        internal
        returns (uint256 ethReceived)
    {
        return _swapSellExactIn(poolKey, actor, tokenIn, TickMath.getSqrtPriceAtTick(LISTING_TICK_UPPER));
    }

    function _swapSellExactIn(PoolKey memory poolKey, address actor, uint256 tokenIn, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 ethReceived)
    {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 balBefore = actor.balance;

        vm.startPrank(actor);
        IERC20(tokenAddr).approve(address(swapRouter), tokenIn);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();

        return actor.balance - balBefore;
    }

    function _swapSellAll(PoolKey memory poolKey, address actor)
        internal
        returns (uint256 totalEth, uint256 totalSold, uint256 rounds)
    {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 chunk = 50_000_000 ether;
        uint256 remaining = IERC20(tokenAddr).balanceOf(actor);

        while (remaining > MAX_LISTING_DUST && rounds < 200) {
            uint256 sellAmt = remaining > chunk ? chunk : remaining;
            uint256 tokenBefore = IERC20(tokenAddr).balanceOf(actor);
            uint256 received;
            try this._swapSellExactInExternal(poolKey, actor, sellAmt) returns (uint256 r) {
                received = r;
            } catch {
                if (sellAmt <= 1 ether) break;
                chunk = sellAmt / 2;
                continue;
            }
            uint256 tokenAfter = IERC20(tokenAddr).balanceOf(actor);
            uint256 actuallySold = tokenBefore - tokenAfter;
            if (actuallySold == 0) {
                if (sellAmt <= 1 ether) break;
                chunk = sellAmt / 2;
                continue;
            }
            totalEth += received;
            totalSold += actuallySold;
            remaining = tokenAfter;
            rounds++;
        }
    }

    function _swapSellExactInExternal(PoolKey memory poolKey, address actor, uint256 tokenIn)
        external
        returns (uint256)
    {
        require(msg.sender == address(this));
        return _swapSellExactIn(poolKey, actor, tokenIn);
    }

    function _expectedPeriodSettleInject(uint256 periodVolume) internal view returns (uint256) {
        (,, uint256 injectAmount) = hook.previewPeriodSettle(periodVolume);
        if (injectAmount < MIN_INJECT_OUTPUT) return 0;
        return injectAmount;
    }

    function _capInjectAmount(uint256 injectAmount, uint256 remaining) internal pure returns (uint256) {
        return injectAmount > remaining ? remaining : injectAmount;
    }

    function _readPeriodState(address tokenAddr) internal view returns (uint32 periodIndex, uint256 currentPeriodBuy) {
        (periodIndex, currentPeriodBuy) = hook.periodState(tokenAddr);
    }

    function _warpToNextPeriod() internal {
        vm.warp(block.timestamp + PERIOD_LENGTH);
    }

    function _slot0(PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return StateLibrary.getSlot0(manager, poolId);
    }

    function _poolLiquidity(PoolId poolId) internal view returns (uint128) {
        return StateLibrary.getLiquidity(manager, poolId);
    }

    function _logPoolReserves(PoolKey memory poolKey, string memory label) internal view {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPrice, int24 tick,,) = _slot0(poolId);
        uint128 liquidity = _poolLiquidity(poolId);
        uint256 poolEth = _poolEthBalance(poolKey);

        console2.log("=== Pool balances:", label, "===");
        console2.log("  tick:", tick);
        console2.log("  liquidity:", liquidity);
        console2.log("  sqrtPriceX96:", sqrtPrice);
        console2.log("  pool ETH est (wei):", poolEth);
        console2.log("  token contract dust:", IERC20(tokenAddr).balanceOf(tokenAddr));
    }
}
