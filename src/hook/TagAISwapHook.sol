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
/// On buy swaps, 0.2% of bought tokens are injected into the HourlyTickCalculator
/// for community reward distribution over a 7-day vesting window.
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

    // ================================ Constants ================================
    uint256 private constant DIVISOR = 10000;
    uint256 private constant INJECT_RATIO_BPS = 20; // 0.2%
    uint256 private constant MIN_INJECT_AMOUNT = 8400 ether; // Min bought amount to trigger inject

    // ================================ Data Structures ================================
    /// @notice Packed struct for per-token Nutbox info.
    /// Slot 1: community (160 bits) + remaining (96 bits) = 256 bits
    /// Slot 2: calculator (160 bits)
    struct HookTokenInfo {
        address community; // Nutbox community for this token
        uint96 remaining; // Remaining NUTBOX_ALLOCATION (max ~79B tokens, 150M fits in uint96)
        address calculator; // HourlyTickCalculator address
    }

    // ================================ State ================================
    ICLPoolManager public immutable clPoolManager;
    IVault public immutable vault;
    IPump public immutable pump;

    // poolId → token address (registered when token lists to DEX)
    mapping(PoolId => address) public poolToken;

    // token → HookTokenInfo (Nutbox injection state)
    mapping(address => HookTokenInfo) public tokenInfo;

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

    // ================================ Internal: Nutbox Injection ================================

    /// @notice Attempt to inject tokens into the Nutbox community reward pool.
    /// @dev Fast-skip if remaining allocation is exhausted or bought amount is below threshold.
    /// @param token The token address
    /// @param tokenDelta The token delta from the swap (negative = tokens leaving pool to buyer)
    function _tryInject(address token, int128 tokenDelta) internal {
        HookTokenInfo storage info = tokenInfo[token];

        // Fast-skip: allocation exhausted
        if (info.remaining == 0) return;

        // Calculate bought amount (negative delta = tokens leaving pool to user)
        uint256 boughtAmount = tokenDelta < 0 ? uint256(uint128(-tokenDelta)) : 0;
        if (boughtAmount == 0) return;

        // Fast-skip: below minimum threshold
        if (boughtAmount < MIN_INJECT_AMOUNT) return;

        // Calculate inject amount (0.2% of bought)
        uint256 injectAmount = (boughtAmount * INJECT_RATIO_BPS) / DIVISOR;

        // Cap to remaining
        if (injectAmount > uint256(info.remaining)) {
            injectAmount = uint256(info.remaining);
        }

        // Update remaining
        info.remaining -= uint96(injectAmount);

        // Try inject with try/catch
        try IHourlyTickCalculator(info.calculator).inject(info.community, injectAmount) {
            emit NutboxInjected(token, info.community, injectAmount, info.remaining);
        } catch (bytes memory reason) {
            // Restore remaining on failure
            info.remaining += uint96(injectAmount);
            emit NutboxInjectionFailed(token, info.community, injectAmount, reason);
        }
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
