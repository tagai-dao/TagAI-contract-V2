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
/// @notice PancakeSwap V4 (Infinity) CL Hook that collects trading fees on every swap
///   and injects a portion of bought tokens into the Nutbox community reward pool.
///   - feeRatio[0] → platform feeReceiver
///   - feeRatio[1] → IPShare.valueCapture() for user-specified subject (or token creator as fallback)
/// Fees are always collected from the ETH side for immediate distribution.
/// On buy swaps, bought token volume is accumulated per 10-minute period (no per-swap inject).
/// On the first buy of the next period, the previous period is settled once into HourlyTickCalculator.
/// Settlement ratio uses 10-minute periodVolume directly against the extract-ratio tier table (T0–T12).
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
    event SwapFeeCollected(PoolId indexed poolId, address indexed token, uint256 platformFee, uint256 deployerFee);
    event NutboxInjected(address indexed token, address indexed community, uint256 injectAmount, uint96 remaining);
    event NutboxInjectionFailed(address indexed token, address indexed community, uint256 injectAmount, bytes reason);
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
    /// @dev Ratio scale: injectAmount = boughtAmount * ratioPpm / RATIO_SCALE (ratioPpm = percent * 1e7).
    uint256 private constant RATIO_SCALE = 1e9;
    /// @dev Minimum inject output (16.8 whole tokens); below this the period settlement is skipped.
    uint256 private constant MIN_INJECT_OUTPUT = 168 ether / 10;
    /// @dev 10-minute period length in seconds.
    uint256 private constant PERIOD_LENGTH = 600;
    /// @dev Per-period cumulative buy volume cap (210M tokens per 10-minute window).
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
    /// @notice Packed struct for per-token Nutbox info.
    /// Slot 1: community (160 bits) + remaining (96 bits) = 256 bits
    /// Slot 2: calculator (160 bits)
    struct HookTokenInfo {
        address community; // Nutbox community for this token
        uint96 remaining; // Remaining NUTBOX_ALLOCATION (max ~79B tokens, 150M fits in uint96)
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

        tokenInfo[token] = HookTokenInfo({
            community: community,
            calculator: calculator,
            remaining: uint96(150_000_000 ether) // NUTBOX_ALLOCATION
        });

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

    /// @notice Collect fees from the specified token if it is ETH (beforeSwap path).
    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (poolToken[key.toId()] == address(0))
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // We only take fee in beforeSwap if ETH is the specified token
        if (!(params.amountSpecified < 0 == params.zeroForOne))
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        int128 fee = _collectBeforeSwapFee(key, params, hookData);

        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev Internal helper to collect fees in beforeSwap when ETH is specified.
    ///      Returns the fee amount as int128 for the hook delta.
    function _collectBeforeSwapFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal returns (int128) {
        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 totalFeeRatio = feeRatio[0] + feeRatio[1];
        if (totalFeeRatio == 0) return 0;

        uint256 specifiedAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        uint256 totalFee = (specifiedAmount * totalFeeRatio) / DIVISOR;
        if (totalFee == 0) return 0;

        // In PCS V4, take() is on the Vault
        vault.take(key.currency0, address(this), totalFee);

        uint256 platformFee = (specifiedAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;
        address token = poolToken[key.toId()];

        _distributeFees(token, platformFee, deployerFee, hookData);
        emit SwapFeeCollected(key.toId(), token, platformFee, deployerFee);

        return totalFee.toInt128();
    }

    /// @notice Collect fees from the unspecified token if it is ETH (afterSwap path),
    ///         and trigger Nutbox injection on buy swaps.
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, int128) {
        address token = poolToken[key.toId()];
        if (token == address(0)) return (ICLHooks.afterSwap.selector, 0);

        // If ETH is specified (exactInput ETH or exactOutput ETH), fee was taken in beforeSwap
        if (params.amountSpecified < 0 == params.zeroForOne) {
            // ETH was specified → fee already collected in beforeSwap
            // But still check for injection on buy (zeroForOne = true means ETH→Token = buy)
            if (params.zeroForOne) {
                _tryInject(token, delta.amount1());
            }
            return (ICLHooks.afterSwap.selector, 0);
        }

        int128 afterSwapFee = _collectAfterSwapFee(key, params, delta, hookData, token);

        // Try inject on buy (zeroForOne = true means ETH→Token)
        if (params.zeroForOne) {
            _tryInject(token, delta.amount1());
        }

        return (ICLHooks.afterSwap.selector, afterSwapFee);
    }

    /// @dev Internal helper to collect fees in afterSwap when ETH is unspecified.
    ///      Returns the fee amount as int128 for the hook delta.
    function _collectAfterSwapFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData,
        address token
    ) internal returns (int128) {
        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 totalFeeRatio = feeRatio[0] + feeRatio[1];
        if (totalFeeRatio == 0) return 0;

        uint256 unspecifiedAmount;
        {
            int128 ethDelta = delta.amount0();
            unspecifiedAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        }

        if (unspecifiedAmount == 0) return 0;

        uint256 totalFee = (unspecifiedAmount * totalFeeRatio) / DIVISOR;
        if (totalFee == 0) return 0;

        // In PCS V4, take() is on the Vault
        vault.take(key.currency0, address(this), totalFee);

        uint256 platformFee = (unspecifiedAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;

        _distributeFees(token, platformFee, deployerFee, hookData);
        emit SwapFeeCollected(key.toId(), token, platformFee, deployerFee);

        return totalFee.toInt128();
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
    function _settlePeriod(address token, uint256 periodVolume, uint32 settledPeriodIndex) internal {
        HookTokenInfo storage info = tokenInfo[token];
        if (info.remaining == 0) return;

        uint256 lookupVolume = periodVolume;
        uint32 ratioPpm = _resolveRatioPpm(periodVolume);
        uint256 injectAmount = (periodVolume * ratioPpm) / RATIO_SCALE;

        if (injectAmount < MIN_INJECT_OUTPUT) {
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, 0);
            return;
        }

        if (injectAmount > uint256(info.remaining)) {
            injectAmount = uint256(info.remaining);
        }

        info.remaining -= uint96(injectAmount);

        try IHourlyTickCalculator(info.calculator).inject(info.community, injectAmount) {
            emit NutboxInjected(token, info.community, injectAmount, info.remaining);
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, injectAmount);
        } catch (bytes memory reason) {
            info.remaining += uint96(injectAmount);
            emit NutboxInjectionFailed(token, info.community, injectAmount, reason);
            emit PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, 0);
        }
    }

    // ================================ Internal: Nutbox Injection ================================

    /// @notice Track buy volume per 10-minute period; prior period is settled on the next period's first buy.
    /// @param token The token address
    /// @param tokenDelta The token delta from the swap (negative = tokens leaving pool to buyer)
    function _tryInject(address token, int128 tokenDelta) internal {
        if (tokenInfo[token].remaining == 0) return;

        uint256 boughtAmount = _boughtAmountFromDelta(tokenDelta);
        if (boughtAmount == 0) return;

        _accumulateBuy(token, boughtAmount);
    }

    /// @notice Preview settlement ratio and inject amount for a completed period volume (view-only).
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
