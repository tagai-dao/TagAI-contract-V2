// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IPump12HookManager {
    function createdTokens(address token) external view returns (bool);
    function tagAI() external view returns (address);
}

interface IToken12HookConfig {
    function totalFeeBps() external view returns (uint16);
    function creatorShareBps() external view returns (uint16);
    function creatorFeeRecipient() external view returns (address);
}

/// @title NetNetHook
/// @notice Pump12 官方池共享 Hook：双向收取 USDG 费用并按 poolId 隔离 Pending。
contract NetNetHook is IHooks, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint256 private constant TAGAI_SHARE_BPS = 1_000;
    uint256 private constant Q128 = uint256(1) << 128;
    uint256 private constant PRICE_DECIMAL_SCALE = 1e30;

    uint8 public constant OBSERVATION_CAPACITY = 32;
    uint40 public constant CHECKPOINT_INTERVAL = 30 minutes;
    uint40 public constant MIN_TWAP_WINDOW = 4 hours;
    uint40 public constant MAX_TWAP_WINDOW = 8 hours;
    uint40 public constant MAX_OBSERVATION_STALENESS = 1 hours;

    error NotPoolManager();
    error OnlyPump();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error InvalidPool();
    error InvalidAmount();
    error ExactOutputUnsupported();
    error OracleAlreadyInitialized();
    error OracleNotInitialized();
    error TimestampRegression();
    error InvalidTWAP();
    error OnlyBurnNet();
    error InvalidBurnNet();
    error InvalidKeeperBounty();

    struct PoolConfig {
        address token;
        address vault;
        address creatorFeeRecipient;
        address premiumSeller;
        uint16 totalFeeBps;
        uint16 creatorShareBps;
        bool usdgIsCurrency0;
        bool registered;
    }

    struct Observation {
        uint40 timestamp;
        int24 tick;
        int56 tickCumulative;
    }

    struct OracleState {
        uint40 lastCheckpointAt;
        uint40 lastSpotAt;
        int24 lastSpotTick;
        int56 runningCumulative;
        uint8 index;
        uint8 count;
    }

    IPoolManager public immutable poolManager;
    IPump12HookManager public immutable pump;
    IERC20 public immutable usdg;

    mapping(PoolId id => PoolConfig config) public poolConfig;
    mapping(PoolId id => address token) public poolToken;
    mapping(PoolId id => uint256 amount) public claimableTagAI;
    mapping(PoolId id => uint256 amount) public claimableCreator;
    mapping(PoolId id => uint256 amount) public pendingUSDG;
    mapping(PoolId id => uint256 amount) public pendingEligibleTradeFeeUSDG;
    mapping(PoolId id => address burnNet) public poolBurnNet;
    mapping(PoolId id => OracleState state) public oracleState;
    mapping(PoolId id => mapping(uint8 index => Observation observation)) public observations;

    event PoolRegistered(PoolId indexed poolId, address indexed token, address indexed vault);
    event HookFeeAccrued(
        PoolId indexed poolId, uint256 totalFeeRaw, uint256 tagAIFeeRaw, uint256 creatorFeeRaw, uint256 burnNetFeeRaw
    );
    event HookFeeClaimed(PoolId indexed poolId, address indexed recipient, bool indexed isTagAI, uint256 amountRaw);
    event PendingUSDGAdded(
        PoolId indexed poolId,
        address indexed token,
        address indexed funder,
        uint256 requestedRaw,
        uint256 receivedRaw,
        bool eligibleForDistributor
    );
    event OracleInitialized(PoolId indexed poolId, uint40 indexed timestamp, int24 tick);
    event OracleCheckpoint(
        PoolId indexed poolId, uint8 indexed index, uint40 timestamp, int24 tick, int56 tickCumulative
    );
    event PendingUSDGActivated(
        PoolId indexed poolId,
        address indexed burnNet,
        address indexed keeper,
        uint256 pendingBefore,
        uint256 keeperPaid,
        uint256 activated,
        uint256 eligibleKeeperPaid,
        uint256 eligibleActivated
    );

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address pump_, address usdg_) {
        poolManager = poolManager_;
        pump = IPump12HookManager(pump_);
        usdg = IERC20(usdg_);

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

    function registerPool(PoolKey calldata key, address token, address vault, address burnNet, address premiumSeller)
        external
        nonReentrant
    {
        if (msg.sender != address(pump)) revert OnlyPump();
        PoolId id = key.toId();
        if (poolConfig[id].registered) revert PoolAlreadyRegistered();
        if (
            !pump.createdTokens(token) || vault == address(0) || burnNet.code.length == 0
                || premiumSeller.code.length == 0 || address(key.hooks) != address(this)
        ) {
            revert InvalidPool();
        }
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (!((currency0 == address(usdg) && currency1 == token) || (currency0 == token && currency1 == address(usdg))))
        {
            revert InvalidPool();
        }

        poolConfig[id] = PoolConfig({
            token: token,
            vault: vault,
            creatorFeeRecipient: IToken12HookConfig(token).creatorFeeRecipient(),
            premiumSeller: premiumSeller,
            totalFeeBps: IToken12HookConfig(token).totalFeeBps(),
            creatorShareBps: IToken12HookConfig(token).creatorShareBps(),
            usdgIsCurrency0: currency0 == address(usdg),
            registered: true
        });
        poolToken[id] = token;
        poolBurnNet[id] = burnNet;
        emit PoolRegistered(id, token, vault);
    }

    function addPendingUSDG(PoolId id, uint256 amount) external nonReentrant returns (uint256 received) {
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();
        if (amount == 0) revert InvalidAmount();

        uint256 beforeBalance = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        received = usdg.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
        pendingUSDG[id] += received;
        emit PendingUSDGAdded(id, config.token, msg.sender, amount, received, false);
    }

    /// @notice Atomically removes one pool's complete pending balance and preserves its eligible/non-eligible ratio.
    function pullPendingUSDG(PoolId id, address keeper, uint256 keeperBounty)
        external
        nonReentrant
        returns (uint256 activated, uint256 eligibleActivated, uint256 eligibleKeeperPaid)
    {
        address burnNet = poolBurnNet[id];
        if (msg.sender != burnNet) revert OnlyBurnNet();
        if (burnNet == address(0)) revert InvalidBurnNet();

        uint256 pendingBefore = pendingUSDG[id];
        if (keeperBounty > pendingBefore || (keeperBounty != 0 && keeper == address(0))) {
            revert InvalidKeeperBounty();
        }
        uint256 eligibleBefore = pendingEligibleTradeFeeUSDG[id];
        eligibleKeeperPaid = pendingBefore == 0 ? 0 : Math.mulDiv(eligibleBefore, keeperBounty, pendingBefore);
        activated = pendingBefore - keeperBounty;
        eligibleActivated = eligibleBefore - eligibleKeeperPaid;

        pendingUSDG[id] = 0;
        pendingEligibleTradeFeeUSDG[id] = 0;
        if (keeperBounty != 0) usdg.safeTransfer(keeper, keeperBounty);
        if (activated != 0) usdg.safeTransfer(burnNet, activated);
        emit PendingUSDGActivated(
            id, burnNet, keeper, pendingBefore, keeperBounty, activated, eligibleKeeperPaid, eligibleActivated
        );
    }

    function claimTagAIFees(PoolId id) external nonReentrant returns (uint256 amount) {
        amount = claimableTagAI[id];
        if (amount == 0) return 0;
        claimableTagAI[id] = 0;
        address recipient = pump.tagAI();
        usdg.safeTransfer(recipient, amount);
        emit HookFeeClaimed(id, recipient, true, amount);
    }

    function claimCreatorFees(PoolId id) external nonReentrant returns (uint256 amount) {
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();
        amount = claimableCreator[id];
        if (amount == 0) return 0;
        claimableCreator[id] = 0;
        usdg.safeTransfer(config.creatorFeeRecipient, amount);
        emit HookFeeClaimed(id, config.creatorFeeRecipient, false, amount);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        PoolConfig storage config = poolConfig[id];
        if (!config.registered || sender != config.vault) revert PoolNotRegistered();
        _initializeOracle(id, TickMath.getTickAtSqrtPrice(sqrtPriceX96));
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        if (sender == config.premiumSeller) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool inputIsCurrency0 = params.zeroForOne;
        address inputCurrency = Currency.unwrap(inputIsCurrency0 ? key.currency0 : key.currency1);
        if (inputCurrency != address(usdg)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 grossInput = uint256(-params.amountSpecified);
        uint256 fee = Math.mulDiv(grossInput, config.totalFeeBps, BPS);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        poolManager.take(inputIsCurrency0 ? key.currency0 : key.currency1, address(this), fee);
        _accrueFee(id, config, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        _updateOracle(id, currentTick);
        if (sender == config.premiumSeller) return (IHooks.afterSwap.selector, 0);

        bool inputIsCurrency0 = params.zeroForOne;
        address inputCurrency = Currency.unwrap(inputIsCurrency0 ? key.currency0 : key.currency1);
        if (inputCurrency == address(usdg)) return (IHooks.afterSwap.selector, 0);

        bool usdgIsCurrency0 = Currency.unwrap(key.currency0) == address(usdg);
        int128 outputDelta = usdgIsCurrency0 ? delta.amount0() : delta.amount1();
        if (outputDelta <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 fee = Math.mulDiv(uint256(uint128(outputDelta)), config.totalFeeBps, BPS);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        poolManager.take(usdgIsCurrency0 ? key.currency0 : key.currency1, address(this), fee);
        _accrueFee(id, config, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function _accrueFee(PoolId id, PoolConfig storage config, uint256 fee) private {
        uint256 tagAIFee = Math.mulDiv(fee, TAGAI_SHARE_BPS, BPS);
        uint256 creatorFee = Math.mulDiv(fee, config.creatorShareBps, BPS);
        uint256 burnNetFee = fee - tagAIFee - creatorFee;

        claimableTagAI[id] += tagAIFee;
        claimableCreator[id] += creatorFee;
        pendingUSDG[id] += burnNetFee;
        pendingEligibleTradeFeeUSDG[id] += burnNetFee;
        emit HookFeeAccrued(id, fee, tagAIFee, creatorFee, burnNetFee);
    }

    /// @notice Permissionless observation checkpoint. A checkpoint created at the current timestamp is not
    ///         eligible for a TWAP consultation until time advances.
    function checkpoint(PoolId id) external returns (bool written) {
        if (!poolConfig[id].registered) revert PoolNotRegistered();
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        written = _updateOracle(id, currentTick);
    }

    /// @notice Returns the only market price BurnNet modules may consume, denominated as USDG per whole Token (WAD).
    function validTWAP(PoolId id) external view returns (uint256 priceWad) {
        (bool valid, uint256 price,) = _consult(id, 0);
        if (!valid) revert InvalidTWAP();
        return price;
    }

    /// @notice Same consultation, additionally requiring both endpoints to have formed at or after `notBefore`.
    function validTWAPAfter(PoolId id, uint40 notBefore) external view returns (uint256 priceWad) {
        (bool valid, uint256 price,) = _consult(id, notBefore);
        if (!valid) revert InvalidTWAP();
        return price;
    }

    function tryTWAP(PoolId id, uint40 notBefore)
        external
        view
        returns (bool valid, uint256 priceWad, uint40 observedAt)
    {
        return _consult(id, notBefore);
    }

    function _initializeOracle(PoolId id, int24 tick) private {
        OracleState storage state = oracleState[id];
        if (state.count != 0) revert OracleAlreadyInitialized();
        uint40 timestamp = uint40(block.timestamp);
        state.lastCheckpointAt = timestamp;
        state.lastSpotAt = timestamp;
        state.lastSpotTick = tick;
        state.count = 1;
        observations[id][0] = Observation({timestamp: timestamp, tick: tick, tickCumulative: 0});
        emit OracleInitialized(id, timestamp, tick);
    }

    function _updateOracle(PoolId id, int24 currentTick) private returns (bool written) {
        OracleState storage state = oracleState[id];
        if (state.count == 0) revert OracleNotInitialized();

        uint40 timestamp = uint40(block.timestamp);
        if (timestamp < state.lastSpotAt) revert TimestampRegression();
        uint40 elapsed = timestamp - state.lastSpotAt;
        if (elapsed != 0) {
            state.runningCumulative += int56(state.lastSpotTick) * int56(uint56(elapsed));
            state.lastSpotAt = timestamp;
        }
        state.lastSpotTick = currentTick;

        if (timestamp - state.lastCheckpointAt < CHECKPOINT_INTERVAL) return false;
        uint8 nextIndex = state.index + 1;
        if (nextIndex == OBSERVATION_CAPACITY) nextIndex = 0;
        state.index = nextIndex;
        if (state.count < OBSERVATION_CAPACITY) ++state.count;
        state.lastCheckpointAt = timestamp;
        observations[id][nextIndex] =
            Observation({timestamp: timestamp, tick: currentTick, tickCumulative: state.runningCumulative});
        emit OracleCheckpoint(id, nextIndex, timestamp, currentTick, state.runningCumulative);
        return true;
    }

    function _consult(PoolId id, uint40 notBefore)
        private
        view
        returns (bool valid, uint256 priceWad, uint40 observedAt)
    {
        PoolConfig storage config = poolConfig[id];
        OracleState storage state = oracleState[id];
        if (!config.registered || state.count < 2) return (false, 0, 0);

        uint40 now40 = uint40(block.timestamp);
        Observation memory newest;
        bool foundNewest;
        for (uint8 i; i < state.count; ++i) {
            Observation memory candidate = observations[id][i];
            if (
                candidate.timestamp < now40 && candidate.timestamp >= notBefore
                    && (!foundNewest || candidate.timestamp > newest.timestamp)
            ) {
                newest = candidate;
                foundNewest = true;
            }
        }
        if (!foundNewest || now40 - newest.timestamp > MAX_OBSERVATION_STALENESS) return (false, 0, 0);

        uint40 cutoff = newest.timestamp > MIN_TWAP_WINDOW ? newest.timestamp - MIN_TWAP_WINDOW : 0;
        uint40 earliest = newest.timestamp > MAX_TWAP_WINDOW ? newest.timestamp - MAX_TWAP_WINDOW : 0;
        if (earliest < notBefore) earliest = notBefore;

        Observation memory oldest;
        bool foundOldest;
        for (uint8 i; i < state.count; ++i) {
            Observation memory candidate = observations[id][i];
            if (
                candidate.timestamp >= earliest && candidate.timestamp <= cutoff
                    && (!foundOldest || candidate.timestamp > oldest.timestamp)
            ) {
                oldest = candidate;
                foundOldest = true;
            }
        }
        if (!foundOldest) return (false, 0, 0);

        uint40 elapsed = newest.timestamp - oldest.timestamp;
        if (elapsed < MIN_TWAP_WINDOW || elapsed > MAX_TWAP_WINDOW) return (false, 0, 0);
        int56 cumulativeDelta = newest.tickCumulative - oldest.tickCumulative;
        int56 elapsedSigned = int56(uint56(elapsed));
        int56 meanTick = cumulativeDelta / elapsedSigned;
        if (cumulativeDelta < 0 && cumulativeDelta % elapsedSigned != 0) --meanTick;
        if (meanTick < TickMath.MIN_TICK || meanTick > TickMath.MAX_TICK) return (false, 0, 0);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(int24(meanTick));
        uint256 ratioX128 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 64);
        if (ratioX128 == 0) return (false, 0, 0);
        priceWad = config.usdgIsCurrency0
            ? FullMath.mulDiv(Q128, PRICE_DECIMAL_SCALE, ratioX128)
            : FullMath.mulDiv(ratioX128, PRICE_DECIMAL_SCALE, Q128);
        return (priceWad != 0, priceWad, newest.timestamp);
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
}
