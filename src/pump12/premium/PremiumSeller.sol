// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "../../utils/CurrencySettler.sol";

interface IHookPremium {
    function validTWAP(PoolId id) external view returns (uint256);
    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256);
}

interface IBurnNetPremium {
    function anchor() external view returns (uint256);
    function mintingAvailable() external view returns (bool);
}

interface ITreasuryPremium {
    function mintByPremium(address to, uint256 amount) external;
}

interface IPermanentLiquidityVaultPremium {
    function polTokenInventory() external view returns (uint256);
}

/// @title PremiumSeller
/// @notice Permissionless protocol sale above 2x Anchor, bounded by permanent POL inventory.
contract PremiumSeller is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;
    uint16 public constant CLIP_BPS = 25;
    uint16 public constant MAX_TWAP_DEVIATION_BPS = 100;
    uint40 public constant MIN_INTERVAL = 1 hours;
    int24 public constant TICK_SPACING = 60;

    error AlreadyInitialized();
    error InvalidInitialization();
    error NotActive();
    error IntervalNotElapsed(uint40 nextExecuteAt);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error OnlyPoolManager();
    error UnexpectedPoolDelta();

    bool public initialized;
    IERC20 public token;
    IERC20 public usdg;
    IHookPremium public hook;
    IBurnNetPremium public burnNet;
    ITreasuryPremium public treasury;
    IPermanentLiquidityVaultPremium public liquidityVault;
    IPoolManager public poolManager;
    PoolId public poolId;
    bool public tokenIsCurrency0;
    uint40 public lastExecuteAt;
    uint40 public nextExecuteAt;

    event PremiumSellerInitialized(address indexed token, PoolId indexed poolId, address indexed treasury);
    event PremiumSold(address indexed caller, uint256 tokenSold, uint256 usdgOutRaw, uint256 twap);

    constructor() {
        initialized = true;
    }

    function initialize(
        address token_,
        address usdg_,
        address hook_,
        address burnNet_,
        address treasury_,
        address liquidityVault_,
        address poolManager_,
        PoolId poolId_,
        uint40 listTime_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            token_.code.length == 0 || usdg_.code.length == 0 || hook_.code.length == 0 || burnNet_.code.length == 0
                || treasury_.code.length == 0 || liquidityVault_.code.length == 0 || poolManager_.code.length == 0
                || PoolId.unwrap(poolId_) == bytes32(0) || listTime_ != block.timestamp
        ) revert InvalidInitialization();
        initialized = true;
        token = IERC20(token_);
        usdg = IERC20(usdg_);
        hook = IHookPremium(hook_);
        burnNet = IBurnNetPremium(burnNet_);
        treasury = ITreasuryPremium(treasury_);
        liquidityVault = IPermanentLiquidityVaultPremium(liquidityVault_);
        poolManager = IPoolManager(poolManager_);
        poolId = poolId_;
        tokenIsCurrency0 = token_ < usdg_;
        nextExecuteAt = listTime_ + MIN_INTERVAL;
        if (PoolId.unwrap(_poolKey().toId()) != PoolId.unwrap(poolId_)) revert InvalidInitialization();
        emit PremiumSellerInitialized(token_, poolId_, treasury_);
    }

    function clipSize() public view returns (uint256) {
        return Math.mulDiv(liquidityVault.polTokenInventory(), CLIP_BPS, BPS);
    }

    function active() external view returns (bool) {
        if (block.timestamp < nextExecuteAt || clipSize() == 0) return false;
        try burnNet.mintingAvailable() returns (bool available) {
            if (!available) return false;
        } catch {
            return false;
        }
        try hook.validTWAP(poolId) returns (uint256 twap) {
            return twap > 2 * burnNet.anchor();
        } catch {
            return false;
        }
    }

    function execute(uint256 minUsdgOutRaw) external nonReentrant returns (uint256 tokenSold, uint256 usdgOutRaw) {
        if (block.timestamp < nextExecuteAt) revert IntervalNotElapsed(nextExecuteAt);
        if (!burnNet.mintingAvailable()) revert NotActive();
        uint256 twap = hook.validTWAP(poolId);
        if (twap <= 2 * burnNet.anchor()) revert NotActive();
        tokenSold = clipSize();
        if (tokenSold == 0) revert NotActive();

        uint256 expectedRaw = Math.mulDiv(tokenSold, twap, 1e30);
        uint256 oracleMinimum = Math.mulDiv(expectedRaw, BPS - MAX_TWAP_DEVIATION_BPS, BPS);
        uint256 minimum = minUsdgOutRaw > oracleMinimum ? minUsdgOutRaw : oracleMinimum;
        treasury.mintByPremium(address(this), tokenSold);
        usdgOutRaw = abi.decode(poolManager.unlock(abi.encode(tokenSold)), (uint256));
        if (usdgOutRaw < minimum) revert SlippageExceeded(usdgOutRaw, minimum);

        usdg.forceApprove(address(hook), usdgOutRaw);
        if (hook.addPendingUSDG(poolId, usdgOutRaw) != usdgOutRaw) revert UnexpectedPoolDelta();
        lastExecuteAt = uint40(block.timestamp);
        nextExecuteAt = uint40(block.timestamp) + MIN_INTERVAL;
        emit PremiumSold(msg.sender, tokenSold, usdgOutRaw, twap);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        PoolKey memory key = _poolKey();
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 usdgDelta = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        if (tokenDelta >= 0 || usdgDelta <= 0) revert UnexpectedPoolDelta();
        uint256 tokenIn = uint256(uint128(-tokenDelta));
        uint256 usdgOut = uint256(uint128(usdgDelta));
        if (tokenIn != amount) revert UnexpectedPoolDelta();
        CurrencySettler.settle(
            tokenIsCurrency0 ? key.currency0 : key.currency1, poolManager, address(this), tokenIn, false
        );
        CurrencySettler.take(
            tokenIsCurrency0 ? key.currency1 : key.currency0, poolManager, address(this), usdgOut, false
        );
        return abi.encode(usdgOut);
    }

    function _poolKey() private view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(address(token));
        Currency usdgCurrency = Currency.wrap(address(usdg));
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
    }
}
