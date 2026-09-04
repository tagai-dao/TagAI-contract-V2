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

    uint256 private constant BPS = 10_000;
    uint256 private constant TAGAI_SHARE_BPS = 1_000;

    error NotPoolManager();
    error OnlyPump();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error InvalidPool();
    error InvalidAmount();
    error ExactOutputUnsupported();

    struct PoolConfig {
        address token;
        address vault;
        address creatorFeeRecipient;
        uint16 totalFeeBps;
        uint16 creatorShareBps;
        bool registered;
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

    function registerPool(PoolKey calldata key, address token, address vault) external nonReentrant {
        if (msg.sender != address(pump)) revert OnlyPump();
        PoolId id = key.toId();
        if (poolConfig[id].registered) revert PoolAlreadyRegistered();
        if (!pump.createdTokens(token) || vault == address(0) || address(key.hooks) != address(this)) {
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
            totalFeeBps: IToken12HookConfig(token).totalFeeBps(),
            creatorShareBps: IToken12HookConfig(token).creatorShareBps(),
            registered: true
        });
        poolToken[id] = token;
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

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        PoolConfig storage config = poolConfig[key.toId()];
        if (!config.registered || sender != config.vault) revert PoolNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();

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
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig storage config = poolConfig[id];
        if (!config.registered) revert PoolNotRegistered();

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
