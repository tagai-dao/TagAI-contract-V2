// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import "../interfaces/IIPShare.sol";

/// @title XSpaceStoreHook
/// @notice Standalone PCS V4 CL Hook for a fixed external token (XSpace Store).
///   Total swap cost: 1% = 0.4% native LP fee (PoolKey.fee) + 0.6% Hook fee on ETH side.
///   Hook fee split (hardcoded):
///     - 0.3% → platform feeReceiver
///     - 0.3% → IPShare.valueCapture() when hookData carries a valid subject, else feeReceiver
///   No Pump dependency, no Nutbox injection.
contract XSpaceStoreHook is ICLHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // ================================ Errors ================================
    error NotPoolManager();
    error InvalidPoolPair();
    error InvalidTickSpacing();
    error InvalidPoolManager();

    // ================================ Events ================================
    event PoolRegistered(PoolId indexed poolId, address indexed token);
    event SwapFeeCollected(
        PoolId indexed poolId,
        address indexed token,
        uint256 platformFee,
        uint256 ipshareFee,
        bool ipshareRouted
    );

    // ================================ Constants ================================
    uint256 private constant DIVISOR = 10000;
    /// @dev Hook-side platform fee (bps). LP fee is set separately via PoolKey.fee.
    uint256 private constant PLATFORM_FEE_BPS = 20;
    uint256 private constant IPSHARE_FEE_BPS = 20;
    /// @dev Recommended LP fee in PCS pips (hundredths of a bip): 4000 = 0.4%.
    uint24 public constant RECOMMENDED_LP_FEE_PIPS = 4000;
    int24 public constant TICK_SPACING = 10;

    // ================================ State ================================
    ICLPoolManager public immutable clPoolManager;
    IVault public immutable vault;
    address public immutable token;
    address public immutable feeReceiver;
    address public immutable ipshare;

    mapping(PoolId => address) public poolToken;

    // ================================ Modifiers ================================
    modifier onlyPoolManager() {
        if (msg.sender != address(clPoolManager)) revert NotPoolManager();
        _;
    }

    // ================================ Constructor ================================
    constructor(
        ICLPoolManager _clPoolManager,
        IVault _vault,
        address _token,
        address _feeReceiver,
        address _ipshare
    ) {
        clPoolManager = _clPoolManager;
        vault = _vault;
        token = _token;
        feeReceiver = _feeReceiver;
        ipshare = _ipshare;
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

    // ================================ Hook Callbacks ================================

    /// @notice Only allow ETH + configured token pools with the expected tick spacing.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override onlyPoolManager returns (bytes4) {
        _validatePoolKey(key);

        PoolId poolId = key.toId();
        poolToken[poolId] = token;
        emit PoolRegistered(poolId, token);

        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice Collect Hook fees from the specified token when it is ETH (beforeSwap path).
    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (poolToken[key.toId()] == address(0)) {
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Only take fee in beforeSwap if ETH is the specified token.
        if (!(params.amountSpecified < 0 == params.zeroForOne)) {
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 fee = _collectBeforeSwapFee(key, params, hookData);
        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @notice Collect Hook fees from the unspecified token when it is ETH (afterSwap path).
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (poolToken[key.toId()] == address(0)) return (ICLHooks.afterSwap.selector, 0);

        // ETH specified → fee already collected in beforeSwap.
        if (params.amountSpecified < 0 == params.zeroForOne) {
            return (ICLHooks.afterSwap.selector, 0);
        }

        int128 afterSwapFee = _collectAfterSwapFee(key, delta, hookData);
        return (ICLHooks.afterSwap.selector, afterSwapFee);
    }

    // ================================ Internal: Fee Collection ================================

    function _collectBeforeSwapFee(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal returns (int128) {
        uint256 specifiedAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        uint256 totalHookFee = (specifiedAmount * (PLATFORM_FEE_BPS + IPSHARE_FEE_BPS)) / DIVISOR;
        if (totalHookFee == 0) return 0;

        vault.take(key.currency0, address(this), totalHookFee);

        uint256 platformFee = (specifiedAmount * PLATFORM_FEE_BPS) / DIVISOR;
        uint256 ipshareFee = totalHookFee - platformFee;

        _distributeFees(key.toId(), platformFee, ipshareFee, hookData);

        return totalHookFee.toInt128();
    }

    function _collectAfterSwapFee(
        PoolKey calldata key,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (int128) {
        int128 ethDelta = delta.amount0();
        uint256 unspecifiedAmount = ethDelta < 0 ? uint256(uint128(-ethDelta)) : uint256(uint128(ethDelta));
        if (unspecifiedAmount == 0) return 0;

        uint256 totalHookFee = (unspecifiedAmount * (PLATFORM_FEE_BPS + IPSHARE_FEE_BPS)) / DIVISOR;
        if (totalHookFee == 0) return 0;

        vault.take(key.currency0, address(this), totalHookFee);

        uint256 platformFee = (unspecifiedAmount * PLATFORM_FEE_BPS) / DIVISOR;
        uint256 ipshareFee = totalHookFee - platformFee;

        _distributeFees(key.toId(), platformFee, ipshareFee, hookData);

        return totalHookFee.toInt128();
    }

    // ================================ Internal: Fee Distribution ================================

    /// @notice Resolve IPShare subject from hookData.
    /// @dev hookData format: abi.encode(address subjectAddress)
    function _resolveIPShareSubject(bytes calldata hookData) internal view returns (address subject, bool valid) {
        if (hookData.length < 32) return (address(0), false);

        address candidate = abi.decode(hookData, (address));
        if (candidate == address(0)) return (address(0), false);
        if (!IIPShare(ipshare).ipshareCreated(candidate)) return (address(0), false);

        return (candidate, true);
    }

    function _distributeFees(
        PoolId poolId,
        uint256 platformFee,
        uint256 ipshareFee,
        bytes calldata hookData
    ) internal {
        (address subject, bool validSubject) = _resolveIPShareSubject(hookData);

        if (validSubject) {
            if (platformFee > 0) {
                (bool success, ) = feeReceiver.call{value: platformFee}("");
                require(success, "Platform fee transfer failed");
            }
            if (ipshareFee > 0) {
                IIPShare(ipshare).valueCapture{value: ipshareFee}(subject);
            }
            emit SwapFeeCollected(poolId, token, platformFee, ipshareFee, true);
            return;
        }

        uint256 totalToPlatform = platformFee + ipshareFee;
        if (totalToPlatform > 0) {
            (bool success, ) = feeReceiver.call{value: totalToPlatform}("");
            require(success, "Platform fee transfer failed");
        }
        emit SwapFeeCollected(poolId, token, platformFee, ipshareFee, false);
    }

    function _validatePoolKey(PoolKey calldata key) internal view {
        if (address(key.poolManager) != address(clPoolManager)) revert InvalidPoolManager();
        if (Currency.unwrap(key.currency0) != Currency.unwrap(CurrencyLibrary.NATIVE)) revert InvalidPoolPair();
        if (Currency.unwrap(key.currency1) != token) revert InvalidPoolPair();

        int24 tickSpacing = CLPoolParametersHelper.getTickSpacing(key.parameters);
        if (tickSpacing != TICK_SPACING) revert InvalidTickSpacing();
    }

    // ================================ Unimplemented hooks ================================

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return ICLHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return ICLHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return ICLHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return ICLHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return ICLHooks.afterDonate.selector;
    }

    receive() external payable {}
}
