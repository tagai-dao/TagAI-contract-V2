// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

import {ICommunity} from "../interfaces/ICommunity.sol";
import {IHourlyTickCalculator} from "../interfaces/IHourlyTickCalculator.sol";

/// @title NutboxCommunityFeeHook
/// @notice Collects 1% of a configured community token on both buy and sell swaps and
///         periodically injects the accumulated token into Nutbox hourly distribution.
/// @dev An unconfigured or mismatched pool is deliberately fee-free. Injection is best-effort:
///      a failed calculator call preserves pending fees and never reverts the triggering swap.
contract NutboxCommunityFeeHook is IHooks, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    error NotPoolManager();
    error InvalidCommunity();
    error InvalidOwner();
    error PendingFeesExist();

    event PoolCommunitySet(PoolId indexed poolId, address indexed community, address indexed token, address calculator);
    event PoolCommunityRemoved(PoolId indexed poolId);
    event CommunityFeeCollected(PoolId indexed poolId, address indexed token, uint256 amount, bool tokenWasInput);
    event CommunityFeesInjected(
        PoolId indexed poolId, address indexed community, address indexed token, uint256 amount
    );
    event CommunityFeesInjectionFailed(
        PoolId indexed poolId, address indexed community, address indexed token, uint256 amount, bytes reason
    );

    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant INJECTION_INTERVAL = 10 minutes;

    struct PoolCommunityConfig {
        address community;
        address calculator;
        address token;
        uint48 lastInjectionAttemptAt;
        uint256 pendingFees;
    }

    IPoolManager public immutable poolManager;
    mapping(PoolId => PoolCommunityConfig) public poolConfig;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address initialOwner_) {
        if (initialOwner_ == address(0)) revert InvalidOwner();
        // CREATE2 deployments are executed by the canonical deployer contract, so msg.sender
        // is not the operational owner. Pin the intended owner explicitly at construction.
        _transferOwnership(initialOwner_);
        poolManager = poolManager_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
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

    /// @notice Assign a Nutbox community to a pool. Fees start only after this succeeds.
    /// @dev The community token and its canonical hourly calculator are cached. A pool can be
    ///      changed or disabled only after all previously collected fees have been injected.
    function setPoolCommunity(PoolId poolId, address community) external onlyOwner {
        PoolCommunityConfig storage config = poolConfig[poolId];
        if (config.pendingFees != 0) revert PendingFeesExist();

        address previousToken = config.token;
        address previousCalculator = config.calculator;
        if (previousToken != address(0) && previousCalculator != address(0)) {
            IERC20(previousToken).forceApprove(previousCalculator, 0);
        }

        if (community == address(0)) {
            delete poolConfig[poolId];
            emit PoolCommunityRemoved(poolId);
            return;
        }

        address token = ICommunity(community).getCommunityToken();
        address calculator = ICommunity(community).rewardCalculator();
        if (token == address(0) || calculator == address(0) || token.code.length == 0 || calculator.code.length == 0) {
            revert InvalidCommunity();
        }

        IERC20(token).forceApprove(calculator, type(uint256).max);
        poolConfig[poolId] = PoolCommunityConfig({
            community: community,
            calculator: calculator,
            token: token,
            lastInjectionAttemptAt: uint48(block.timestamp),
            pendingFees: 0
        });
        emit PoolCommunitySet(poolId, community, token, calculator);
    }

    /// @notice Permissionless best-effort retry for a pool whose fees are due.
    /// @return injected True only when a non-zero pending amount was successfully injected.
    function tryInjectPool(PoolId poolId) external returns (bool injected) {
        injected = _tryInject(poolId, poolConfig[poolId]);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolCommunityConfig storage config = poolConfig[poolId];
        if (!_matchesPool(config.token, key)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool exactInput = params.amountSpecified < 0;
        bool specifiedTokenIs0 = exactInput == params.zeroForOne;
        bool communityTokenIs0 = config.token == Currency.unwrap(key.currency0);
        if (specifiedTokenIs0 != communityTokenIs0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (specifiedAmount * FEE_BPS) / BPS_DENOMINATOR;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        poolManager.take(Currency.wrap(config.token), address(this), fee);
        config.pendingFees += fee;
        emit CommunityFeeCollected(poolId, config.token, fee, exactInput);
        _tryInject(poolId, config);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolCommunityConfig storage config = poolConfig[poolId];
        if (!_matchesPool(config.token, key)) return (IHooks.afterSwap.selector, 0);

        bool exactInput = params.amountSpecified < 0;
        bool specifiedTokenIs0 = exactInput == params.zeroForOne;
        bool communityTokenIs0 = config.token == Currency.unwrap(key.currency0);
        if (specifiedTokenIs0 == communityTokenIs0) return (IHooks.afterSwap.selector, 0);

        int128 rawTokenDelta = communityTokenIs0 ? delta.amount0() : delta.amount1();
        uint256 tokenAmount = rawTokenDelta < 0 ? uint256(uint128(-rawTokenDelta)) : uint256(uint128(rawTokenDelta));
        uint256 fee = (tokenAmount * FEE_BPS) / BPS_DENOMINATOR;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        poolManager.take(Currency.wrap(config.token), address(this), fee);
        config.pendingFees += fee;
        emit CommunityFeeCollected(poolId, config.token, fee, !exactInput);
        _tryInject(poolId, config);

        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function _tryInject(PoolId poolId, PoolCommunityConfig storage config) private returns (bool) {
        uint256 pending = config.pendingFees;
        if (
            pending == 0 || config.community == address(0)
                || block.timestamp < uint256(config.lastInjectionAttemptAt) + INJECTION_INTERVAL
        ) return false;

        // Record the attempt before the external call. Failure retries at most once per interval,
        // while preserving the full pending amount for a later attempt.
        config.lastInjectionAttemptAt = uint48(block.timestamp);
        try IHourlyTickCalculator(config.calculator).inject(config.community, pending) {
            config.pendingFees = 0;
            emit CommunityFeesInjected(poolId, config.community, config.token, pending);
            return true;
        } catch (bytes memory reason) {
            emit CommunityFeesInjectionFailed(poolId, config.community, config.token, pending, reason);
            return false;
        }
    }

    function _matchesPool(address token, PoolKey calldata key) private pure returns (bool) {
        if (token == address(0)) return false;
        return token == Currency.unwrap(key.currency0) || token == Currency.unwrap(key.currency1);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
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
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
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
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
