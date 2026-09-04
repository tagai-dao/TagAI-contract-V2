// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {BaseLiquidityMath} from "./libraries/BaseLiquidityMath.sol";

/// @title PermanentLiquidityVault
/// @notice 持有单一 Pump12 Token 的基础全域 POL；部署后不存在移除或领取入口。
contract PermanentLiquidityVault is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 public constant TICK_SPACING = 60;
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 887220;
    bytes32 public constant BASE_LP_SALT = keccak256("PUMP12_BASE_POL_V1");

    uint256 public constant TOKEN_BUDGET = 250_000_000e18;
    uint256 public constant USDG_BUDGET = 15_000e6;

    error OnlyPump();
    error OnlyPoolManager();
    error AlreadyConfigured();
    error AlreadyInitialized();
    error InvalidPoolKey();
    error InsufficientInventory();
    error ZeroLiquidity();
    error SettlementExceedsBudget();

    IPoolManager public poolManager;
    address public pump;
    address public token;
    address public usdg;

    bool public configured;
    bool public initialized;
    PoolId public poolId;
    uint160 public initialSqrtPriceX96;
    uint128 public lockedLiquidity;
    uint256 public tokenUsed;
    uint256 public usdgUsed;
    bool public tokenIsCurrency0;

    constructor() {
        configured = true;
    }

    function initialize(IPoolManager poolManager_, address pump_, address token_, address usdg_) external {
        if (configured) revert AlreadyConfigured();
        configured = true;
        poolManager = poolManager_;
        pump = pump_;
        token = token_;
        usdg = usdg_;
    }

    function initializeAndLock(PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (PoolId id, uint128 liquidity)
    {
        if (msg.sender != pump) revert OnlyPump();
        if (initialized) revert AlreadyInitialized();
        if (!_isExpectedKey(key)) revert InvalidPoolKey();
        if (
            Currency.wrap(token).balanceOf(address(this)) < TOKEN_BUDGET
                || Currency.wrap(usdg).balanceOf(address(this)) < USDG_BUDGET
        ) revert InsufficientInventory();

        initialized = true;
        initialSqrtPriceX96 = sqrtPriceX96;
        id = key.toId();
        poolId = id;
        tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint256 amount0 = Currency.unwrap(key.currency0) == token ? TOKEN_BUDGET : USDG_BUDGET;
        uint256 amount1 = Currency.unwrap(key.currency1) == token ? TOKEN_BUDGET : USDG_BUDGET;
        liquidity = BaseLiquidityMath.forAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1);
        if (liquidity == 0) revert ZeroLiquidity();
        lockedLiquidity = liquidity;

        poolManager.initialize(key, sqrtPriceX96);
        poolManager.unlock(abi.encode(key, liquidity));
    }

    /// @notice 从固定 position 的实时 liquidity 与价格计算基础 POL 中的 Token 数量。
    function polTokenInventory() external view returns (uint256 inventory) {
        (uint128 liquidity,,) = poolManager.getPositionInfo(poolId, address(this), TICK_LOWER, TICK_UPPER, BASE_LP_SALT);
        if (liquidity == 0) return 0;

        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint256 amount0;
        uint256 amount1;
        if (sqrtPrice <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPrice < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
        inventory = tokenIsCurrency0 ? amount0 : amount1;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId) || liquidity != lockedLiquidity) {
            revert InvalidPoolKey();
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: BASE_LP_SALT
            }),
            bytes("")
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return bytes("");
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta >= 0) return;
        uint256 amount = uint256(uint128(-delta));
        address currencyAddress = Currency.unwrap(currency);
        if (currencyAddress == token) {
            if (tokenUsed + amount > TOKEN_BUDGET) revert SettlementExceedsBudget();
            tokenUsed += amount;
        } else if (currencyAddress == usdg) {
            if (usdgUsed + amount > USDG_BUDGET) revert SettlementExceedsBudget();
            usdgUsed += amount;
        } else {
            revert InvalidPoolKey();
        }
        CurrencySettler.settle(currency, poolManager, address(this), amount, false);
    }

    function _isExpectedKey(PoolKey calldata key) private view returns (bool) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        return key.fee == 0 && key.tickSpacing == TICK_SPACING
            && ((currency0 == token && currency1 == usdg) || (currency0 == usdg && currency1 == token));
    }
}
