// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPump.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IHourlyTickCalculator.sol";

/// @title TagAISwapHook
/// @notice PancakeSwap V4 (Infinity) CL Hook for post-list fee routing + Nutbox injection.
/// @dev Post-list fees are HARDCODED (never reads Pump.feeRatio — that is inner-market only):
///   - IPShare 0.3% (`IPSHARE_FEE_BPS`) from the BNB side on both buy and sell
///     → `IPShare.valueCapture(subject)` via `_resolveSubject` / hookData
///   - Directional 0.3% (`DIRECTIONAL_FEE_BPS`):
///       BUY  (`zeroForOne`): 0.3% of gross token output → left on Hook (Nutbox budget)
///       SELL: 0.3% of gross BNB → platform `feeReceiver`
///   - Sell BNB leg: IPShare 30 + platform directional 30 = 60 BPS on the SAME gross BNB base (not nested)
///   - Buy BNB leg: only IPShare 30 BPS (no platform cut from BNB)
/// `SwapFeeCollected.platformFee` = platform BNB portion; `deployerFee` = IPShare BNB portion.
/// On buys, 10-minute period volume accumulates; prior period settles into HourlyTickCalculator on next period's first buy.
/// Inject amount is capped by the Hook's live ERC20 balance (listing allocation + directional token fees + top-ups).
contract TagAISwapHook is ICLHooks, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // ================================ Errors ================================
    error NotPoolManager();
    error Unauthorized();
    error PoolNotRegistered();
    error OnlyPump();

    // ================================ Events ================================
    event PoolRegistered(PoolId indexed poolId, address indexed token);
    /// @param platformFee Platform BNB portion (sell-side directional only; 0 on buy BNB leg)
    /// @param deployerFee IPShare BNB portion
    event SwapFeeCollected(PoolId indexed poolId, address indexed token, uint256 platformFee, uint256 deployerFee);
    /// @param balanceAfter Hook's ERC20 balance after a successful inject (supports continuous top-ups).
    event NutboxInjected(address indexed token, address indexed community, uint256 injectAmount, uint256 balanceAfter);
    event NutboxInjectionFailed(address indexed token, address indexed community, uint256 injectAmount, bytes reason);
    /// @param lookupVolume Same as periodVolume (kept for observability / off-chain indexing).
    event PeriodSettled(
        address indexed token,
        uint32 indexed settledPeriodIndex,
        uint256 periodVolume,
        uint256 lookupVolume,
        uint32 ratioPpm,
        uint256 injectAmount
    );

    // ================================ Constants ================================
    uint256 private constant DIVISOR = 10000;
    /// @dev Hardcoded post-list IPShare fee: 0.3% of gross BNB (both buy and sell).
    uint256 private constant IPSHARE_FEE_BPS = 30;
    /// @dev Hardcoded directional fee: 0.3% — buy takes token output; sell takes BNB to platform.
    uint256 private constant DIRECTIONAL_FEE_BPS = 30;
    /// @dev Ratio scale: injectAmount = boughtAmount * ratioPpm / RATIO_SCALE (ratioPpm = percent * 1e7).
    uint256 private constant RATIO_SCALE = 1e9;
    /// @dev Minimum inject output (16.8 whole tokens); below this the period settlement is skipped.
    uint256 private constant MIN_INJECT_OUTPUT = 168 ether / 10;
    /// @dev 10-minute period length in seconds.
    uint256 private constant PERIOD_LENGTH = 600;
    /// @dev Per-period cumulative buy volume cap (420M tokens per 10-minute window).
    uint256 private constant MAX_PERIOD_BUY_VOLUME = 420_000_000 ether;
    // Volume upper bounds (whole-token units, 18 decimals) from extract-ratio-table.json (10-minute tiers).
    uint256 private constant T0 = 26_700 ether;
    uint256 private constant T1 = 93_200 ether;
    uint256 private constant T2 = 236_000 ether;
    uint256 private constant T3 = 548_000 ether;
    uint256 private constant T4 = 1_250_000 ether;
    uint256 private constant T5 = 3_320_000 ether;
    uint256 private constant T6 = 7_360_000 ether;
    uint256 private constant T7 = 14_500_000 ether;
    uint256 private constant T8 = 23_400_000 ether;
    uint256 private constant T9 = 41_400_000 ether;
    uint256 private constant T10 = 84_000_000 ether;
    uint256 private constant T11 = 355_000_000 ether;

    // ================================ Data Structures ================================
    /// @notice Per-token Nutbox routing info.
    /// @dev Injection budget is the Hook's live ERC20 balance (initial listing transfer + any later top-ups).
    struct HookTokenInfo {
        address community; // Nutbox community for this token
        address calculator; // HourlyTickCalculator address
    }

    /// @notice Per-token 10-minute period buy accumulation (settled on next period's first buy).
    struct PeriodBuyState {
        uint32 periodIndex; // block.timestamp / PERIOD_LENGTH for the active period
        uint256 currentPeriodBuy; // Cumulative buy volume in the active period (capped at MAX_PERIOD_BUY_VOLUME)
    }

    // ================================ State ================================
    ICLPoolManager public immutable clPoolManager;
    IVault public immutable vault;
    IPump public immutable pump;

    // poolId → token address (registered when token lists to DEX)
    mapping(PoolId => address) public poolToken;

    // token → HookTokenInfo (Nutbox injection state)
    mapping(address => HookTokenInfo) public tokenInfo;

    // token → 10-minute period buy accumulation
    mapping(address => PeriodBuyState) public periodState;

    // ================================ Modifiers ================================
    modifier onlyPoolManager() {
        if (msg.sender != address(clPoolManager)) revert NotPoolManager();
        _;
    }

    // ================================ Constructor ================================
    constructor(ICLPoolManager _clPoolManager, IVault _vault, address _pump) {
        clPoolManager = _clPoolManager;
        vault = _vault;
        pump = IPump(_pump);
    }

    /// @notice Returns the hook registration bitmap indicating which callbacks are active.
    /// Bits: beforeInitialize(0), beforeSwap(6), afterSwap(7),
    ///       beforeSwapReturnsDelta(10), afterSwapReturnsDelta(11)
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return
            uint16(
                (1 << 0) | // HOOKS_BEFORE_INITIALIZE_OFFSET
                    (1 << 6) | // HOOKS_BEFORE_SWAP_OFFSET
                    (1 << 7) | // HOOKS_AFTER_SWAP_OFFSET
                    (1 << 10) | // HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET
                    (1 << 11) // HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
            );
    }

    // ================================ Pool Registration ================================
    /// @notice Register a pool → token mapping. Called by Token contract during listing.
    /// @dev Dual validation: msg.sender must be the token AND token must be created by pump.
    function registerPool(PoolId poolId, address token) external nonReentrant {
        if (!pump.createdTokens(token)) revert Unauthorized();
        if (msg.sender != token) revert Unauthorized();

        poolToken[poolId] = token;

        // Read Nutbox info from Token
        address community = IToken(token).nutboxCommunity();
        address calculator = IPump(address(pump)).getCalculator();

        tokenInfo[token] = HookTokenInfo({community: community, calculator: calculator});

        // Approve calculator to pull tokens (for inject's transferFrom)
        IERC20(token).approve(calculator, type(uint256).max);

        emit PoolRegistered(poolId, token);
    }

    // ================================ Hook Callbacks ================================

    /// @notice Guard: only registered Token contracts can create pools with this Hook
    function beforeInitialize(
        address sender,
        PoolKey calldata /* key */,
        uint160 /* sqrtPriceX96 */
    ) external virtual override onlyPoolManager returns (bytes4) {
        if (!pump.createdTokens(sender)) revert Unauthorized();
        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice Collect fees when the fee currency is the swap's specified currency.
    /// @dev ETH specified → BNB IPShare (+ sell directional). Token specified on buy → directional token fee.
    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (poolToken[key.toId()] == address(0)) {
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Specified currency is ETH/BNB iff (exactIn == zeroForOne)
        bool ethSpecified = (params.amountSpecified < 0 == params.zeroForOne);

        if (ethSpecified) {
            int128 fee = _collectBeforeSwapBnbFee(key, params, hookData);
            return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
        }

        // Token specified + buy = exact-out buy: take directional token fee from specified output.
        // (afterSwap can only report unspecified=BNB delta, so token fee must be accounted here.)
        if (params.zeroForOne) {
            int128 tokenFee = _collectBeforeSwapBuyTokenFee(key, params);
            return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(tokenFee, 0), 0);
        }

        // Sell exact-in: BNB fee collected in afterSwap
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev BNB-side fees when ETH is the specified currency (exact-in buy or exact-out sell).
    function _collectBeforeSwapBnbFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal returns (int128) {
        uint256 specifiedAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        return _takeAndDistributeBnbFees(key, specifiedAmount, params.zeroForOne, hookData);
    }

    /// @dev Buy exact-out: directional token fee from specified token amount (PCS specified delta).
    function _collectBeforeSwapBuyTokenFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params
    ) internal returns (int128) {
        // exact-out → amountSpecified > 0
        uint256 specifiedAmount = uint256(params.amountSpecified);
        uint256 tokenFee = (specifiedAmount * DIRECTIONAL_FEE_BPS) / DIVISOR;
        if (tokenFee == 0) return 0;

        vault.take(key.currency1, address(this), tokenFee);
        return tokenFee.toInt128();
    }

    /// @notice Collect unspecified-currency fees + buy-side directional token fee; trigger Nutbox period tracking.
    /// @dev CRITICAL: when ETH was already fee'd in beforeSwap (exact-in buy), still take directional TOKEN
    ///      fee here and return it as afterSwapReturnsDelta (unspecified = token) so vault accounting balances.
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, int128) {
        address token = poolToken[key.toId()];
        if (token == address(0)) return (ICLHooks.afterSwap.selector, 0);

        bool ethSpecified = (params.amountSpecified < 0 == params.zeroForOne);
        int128 hookUnspecifiedDelta = 0;

        if (ethSpecified) {
            // BNB fee already collected in beforeSwap.
            // Exact-in buy: unspecified currency is the token — collect directional fee + report delta.
            if (params.zeroForOne) {
                hookUnspecifiedDelta = _collectBuyDirectionalTokenFee(key, delta);
                _tryInject(token, delta.amount1());
            }
            return (ICLHooks.afterSwap.selector, hookUnspecifiedDelta);
        }

        // ETH is unspecified: collect BNB fees here (exact-out buy or exact-in sell).
        hookUnspecifiedDelta = _collectAfterSwapBnbFee(key, params, delta, hookData, token);

        // Exact-out buy: directional token fee already taken in beforeSwap (specified delta).
        if (params.zeroForOne) {
            _tryInject(token, delta.amount1());
        }

        return (ICLHooks.afterSwap.selector, hookUnspecifiedDelta);
    }

    /// @dev BNB-side fees when ETH is unspecified (exact-out buy or exact-in sell).
    function _collectAfterSwapBnbFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData,
        address /* token */
    ) internal returns (int128) {
        uint256 unspecifiedAmount;
        {
            int128 ethDelta = delta.amount0();
            unspecifiedAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        }
        if (unspecifiedAmount == 0) return 0;

        return _takeAndDistributeBnbFees(key, unspecifiedAmount, params.zeroForOne, hookData);
    }

    /// @dev Shared BNB fee take + split. Buy: IPShare only. Sell: IPShare + platform on same gross base.
    function _takeAndDistributeBnbFees(
        PoolKey calldata key,
        uint256 bnbAmount,
        bool isBuy,
        bytes calldata hookData
    ) internal returns (int128) {
        uint256 ipshareFee = (bnbAmount * IPSHARE_FEE_BPS) / DIVISOR;
        // Sell: platform directional on the SAME gross BNB (not nested after IPShare).
        uint256 platformFee = isBuy ? 0 : (bnbAmount * DIRECTIONAL_FEE_BPS) / DIVISOR;
        uint256 totalFee = ipshareFee + platformFee;
        if (totalFee == 0) return 0;

        vault.take(key.currency0, address(this), totalFee);

        address token = poolToken[key.toId()];
        _distributeFees(token, platformFee, ipshareFee, hookData);
        emit SwapFeeCollected(key.toId(), token, platformFee, ipshareFee);

        return totalFee.toInt128();
    }

    /// @dev Buy-side directional: take 0.3% of gross token output; leave on Hook for Nutbox budget.
    /// @return Fee amount as int128 for afterSwapReturnsDelta (unspecified = token when ETH was specified).
    function _collectBuyDirectionalTokenFee(PoolKey calldata key, BalanceDelta delta) internal returns (int128) {
        uint256 bought = _boughtAmountFromDelta(delta.amount1());
        uint256 tokenFee = (bought * DIRECTIONAL_FEE_BPS) / DIVISOR;
        if (tokenFee == 0) return 0;

        vault.take(key.currency1, address(this), tokenFee);
        return tokenFee.toInt128();
    }

    // ================================ Internal: Period ratio ================================

    /// @notice Resolve injection ratio (parts-per-million of RATIO_SCALE) from 10-minute period volume.
    /// @dev Volume tiers and ratioPpm values from extract-ratio-table.json; fixed at deploy time.
    function _resolveRatioPpm(uint256 volume) internal pure returns (uint32) {
        if (volume < T0) return 106_069_772;
        if (volume < T1) return 53_034_886;
        if (volume < T2) return 31_517_443;
        if (volume < T3) return 15_758_722;
        if (volume < T4) return 7_079_361;
        if (volume < T5) return 6_003_489;
        if (volume < T6) return 4_727_617;
        if (volume < T7) return 3_651_745;
        if (volume < T8) return 3_000_000;
        if (volume < T9) return 1_575_873;
        if (volume < T10) return 787_936;
        if (volume < T11) return 393_969;
        return 196_984;
    }

    /// @dev PCS V4 buy deltas report token output as positive to the trader; unit tests may use negative.
    function _boughtAmountFromDelta(int128 tokenDelta) internal pure returns (uint256) {
        if (tokenDelta < 0) return uint256(uint128(-tokenDelta));
        if (tokenDelta > 0) return uint256(uint128(tokenDelta));
        return 0;
    }

    /// @notice Accumulate buy volume for the current 10-minute period; settle the prior period on roll-over.
    function _accumulateBuy(address token, uint256 boughtAmount) internal {
        PeriodBuyState storage state = periodState[token];
        uint32 currentPeriod = uint32(block.timestamp / PERIOD_LENGTH);

        if (state.periodIndex != currentPeriod) {
            if (state.currentPeriodBuy > 0) {
                _settlePeriod(token, state.currentPeriodBuy, state.periodIndex);
            }
            state.periodIndex = currentPeriod;
            state.currentPeriodBuy = 0;
        }

        uint256 room = MAX_PERIOD_BUY_VOLUME - state.currentPeriodBuy;
        uint256 addAmount = boughtAmount > room ? room : boughtAmount;
        state.currentPeriodBuy += addAmount;
    }

    /// @notice Settle one completed period: inject periodVolume × ratio(periodVolume) once.
    /// @dev Caps by Hook ERC20 balance so external top-ups can keep funding injections.
    ///      Final inject must still meet MIN_INJECT_OUTPUT (skip dust leftovers below the floor).
    function _settlePeriod(address token, uint256 periodVolume, uint32 settledPeriodIndex) internal {
        HookTokenInfo storage info = tokenInfo[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;

        uint256 lookupVolume = periodVolume;
        uint32 ratioPpm = _resolveRatioPpm(periodVolume);
        uint256 injectAmount = (periodVolume * ratioPpm) / RATIO_SCALE;

        // inject = min(calculated, balance); skip if that result is below the floor
        if (injectAmount > balance) {
            injectAmount = balance;
        }
        if (injectAmount < MIN_INJECT_OUTPUT) {
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, 0);
            return;
        }

        try IHourlyTickCalculator(info.calculator).inject(info.community, injectAmount) {
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            emit NutboxInjected(token, info.community, injectAmount, balanceAfter);
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, injectAmount);
        } catch (bytes memory reason) {
            // transferFrom reverts with the call — no local budget to roll back
            emit NutboxInjectionFailed(token, info.community, injectAmount, reason);
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, 0);
        }
    }

    // ================================ Internal: Nutbox Injection ================================

    /// @notice Track buy volume per 10-minute period; prior period is settled on the next period's first buy.
    /// @dev Always accumulate buys so a later top-up can fund settlement of prior period volume.
    /// @param token The token address
    /// @param tokenDelta The token delta from the swap (negative = tokens leaving pool to buyer)
    function _tryInject(address token, int128 tokenDelta) internal {
        uint256 boughtAmount = _boughtAmountFromDelta(tokenDelta);
        if (boughtAmount == 0) return;

        _accumulateBuy(token, boughtAmount);
    }

    /// @notice Preview settlement ratio and inject amount for a completed period volume (view-only).
    /// @return lookupVolume Equals periodVolume (tier lookup uses 10-minute volume directly).
    function previewPeriodSettle(uint256 periodVolume)
        external
        pure
        returns (uint256 lookupVolume, uint32 ratioPpm, uint256 injectAmount)
    {
        lookupVolume = periodVolume;
        ratioPpm = _resolveRatioPpm(periodVolume);
        injectAmount = (periodVolume * ratioPpm) / RATIO_SCALE;
    }

    // ================================ Internal: Fee Distribution ================================

    /// @notice Resolve the IPShare subject from hookData, falling back to token creator.
    ///   hookData format: abi.encode(address subjectAddress)
    ///   - If hookData is empty or the decoded address has no IPShare created, use token creator.
    function _resolveSubject(address token, bytes calldata hookData) internal returns (address) {
        address defaultSubject = IToken(token).getIPShare();

        if (hookData.length < 32) return defaultSubject;

        address candidate = abi.decode(hookData, (address));
        if (candidate == address(0)) return defaultSubject;

        address ipshare = pump.getIPShare();
        if (!IIPShare(ipshare).ipshareCreated(candidate)) return defaultSubject;

        return candidate;
    }

    /// @notice Route BNB fees: platform → feeReceiver; IPShare → valueCapture(subject).
    /// @param platformFee Platform BNB (sell directional); 0 on buy BNB leg
    /// @param deployerFee IPShare BNB portion
    function _distributeFees(
        address token,
        uint256 platformFee,
        uint256 deployerFee,
        bytes calldata hookData
    ) internal {
        address feeReceiver = pump.getFeeReceiver();
        address ipshare = pump.getIPShare();
        address subject = _resolveSubject(token, hookData);

        if (platformFee > 0) {
            (bool success, ) = feeReceiver.call{value: platformFee}("");
            require(success, "Platform fee transfer failed");
        }
        if (deployerFee > 0) {
            IIPShare(ipshare).valueCapture{value: deployerFee}(subject);
        }
    }

    // ================================ Unimplemented hooks ================================

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual override returns (bytes4) {
        return ICLHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return ICLHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return ICLHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return ICLHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external virtual override returns (bytes4) {
        return ICLHooks.afterDonate.selector;
    }

    // ================================ Receive ETH ================================
    receive() external payable {}
}
