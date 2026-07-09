// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPump.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IHourlyTickCalculator.sol";

/// @title TagAISwapHook
/// @notice Uniswap v4 hook: trading fees + Nutbox period settlement (Robinhood / generic v4 deployment).
/// @dev Hook address lower 14 bits must encode: beforeInitialize, beforeSwap, afterSwap, before/after swap return delta.
contract TagAISwapHook is IHooks, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    error NotPoolManager();
    error Unauthorized();
    error PoolNotRegistered();
    error OnlyPump();

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

    uint256 private constant DIVISOR = 10000;
    uint256 private constant RATIO_SCALE = 1e9;
    uint256 private constant MIN_INJECT_OUTPUT = 168 ether / 10;
    uint256 private constant PERIOD_LENGTH = 600;
    uint256 private constant MAX_PERIOD_BUY_VOLUME = 420_000_000 ether;

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

    struct HookTokenInfo {
        address community;
        uint96 remaining;
        address calculator;
    }

    struct PeriodBuyState {
        uint32 periodIndex;
        uint256 currentPeriodBuy;
    }

    IPoolManager public immutable poolManager;
    IPump public immutable pump;

    mapping(PoolId => address) public poolToken;
    mapping(address => HookTokenInfo) public tokenInfo;
    mapping(address => PeriodBuyState) public periodState;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _pump) {
        poolManager = _poolManager;
        pump = IPump(_pump);

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function registerPool(PoolId poolId, address token) external nonReentrant {
        if (!pump.createdTokens(token)) revert Unauthorized();
        if (msg.sender != token) revert Unauthorized();

        poolToken[poolId] = token;

        address community = IToken(token).nutboxCommunity();
        address calculator = IPump(address(pump)).getCalculator();

        tokenInfo[token] = HookTokenInfo({
            community: community,
            calculator: calculator,
            remaining: uint96(150_000_000 ether)
        });

        IERC20(token).approve(calculator, type(uint256).max);
        emit PoolRegistered(poolId, token);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        if (!pump.createdTokens(sender)) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (poolToken[key.toId()] == address(0)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (!(params.amountSpecified < 0 == params.zeroForOne)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 fee = _collectBeforeSwapFee(key, params, hookData);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function _collectBeforeSwapFee(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
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

        poolManager.take(key.currency0, address(this), totalFee);

        uint256 platformFee = (specifiedAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;
        address token = poolToken[key.toId()];

        _distributeFees(token, platformFee, deployerFee, hookData);
        emit SwapFeeCollected(key.toId(), token, platformFee, deployerFee);

        return totalFee.toInt128();
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        address token = poolToken[key.toId()];
        if (token == address(0)) return (IHooks.afterSwap.selector, 0);

        if (params.amountSpecified < 0 == params.zeroForOne) {
            if (params.zeroForOne) {
                _tryInject(token, delta.amount1());
            }
            return (IHooks.afterSwap.selector, 0);
        }

        int128 afterSwapFee = _collectAfterSwapFee(key, params, delta, hookData, token);

        if (params.zeroForOne) {
            _tryInject(token, delta.amount1());
        }

        return (IHooks.afterSwap.selector, afterSwapFee);
    }

    function _collectAfterSwapFee(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData,
        address token
    ) internal returns (int128) {
        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 totalFeeRatio = feeRatio[0] + feeRatio[1];
        if (totalFeeRatio == 0) return 0;

        int128 ethDelta = delta.amount0();
        uint256 unspecifiedAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        if (unspecifiedAmount == 0) return 0;

        uint256 totalFee = (unspecifiedAmount * totalFeeRatio) / DIVISOR;
        if (totalFee == 0) return 0;

        poolManager.take(key.currency0, address(this), totalFee);

        uint256 platformFee = (unspecifiedAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;

        _distributeFees(token, platformFee, deployerFee, hookData);
        emit SwapFeeCollected(key.toId(), token, platformFee, deployerFee);

        return totalFee.toInt128();
    }

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

    function _boughtAmountFromDelta(int128 tokenDelta) internal pure returns (uint256) {
        if (tokenDelta < 0) return uint256(uint128(-tokenDelta));
        if (tokenDelta > 0) return uint256(uint128(tokenDelta));
        return 0;
    }

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

    function _tryInject(address token, int128 tokenDelta) internal {
        if (tokenInfo[token].remaining == 0) return;
        uint256 boughtAmount = _boughtAmountFromDelta(tokenDelta);
        if (boughtAmount == 0) return;
        _accumulateBuy(token, boughtAmount);
    }

    function previewPeriodSettle(uint256 periodVolume)
        external
        pure
        returns (uint256 lookupVolume, uint32 ratioPpm, uint256 injectAmount)
    {
        lookupVolume = periodVolume;
        ratioPpm = _resolveRatioPpm(periodVolume);
        injectAmount = (periodVolume * ratioPpm) / RATIO_SCALE;
    }

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
            (bool success,) = feeReceiver.call{value: platformFee}("");
            require(success, "Platform fee transfer failed");
        }
        if (deployerFee > 0) {
            IIPShare(ipshare).valueCapture{value: deployerFee}(subject);
        }
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    receive() external payable {}
}
