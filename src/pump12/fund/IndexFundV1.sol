// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

import {IBasketRegistry} from "../../interfaces/IBasketRegistry.sol";
import {IBasketToken} from "../../interfaces/IBasketToken.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {CurrencySettler} from "../../utils/CurrencySettler.sol";
import {IIndexFund} from "./IIndexFund.sol";

interface IHookIndexFund {
    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256 received);
}

interface IBasketSwapRouterIndexFund {
    function usdg() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function basketHook() external view returns (address);
    function buyExactUsdg(
        address basket,
        uint256 usdgIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);
    function sellExactBasket(
        address basket,
        uint256 basketIn,
        uint256 minUsdgOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 usdgOut);
}

interface IBasketHookIndexFund {
    function poolManager() external view returns (IPoolManager);
    function basketRegistry() external view returns (address);
    function routeRegistry() external view returns (address);
    function usdg() external view returns (address);
    function weth() external view returns (address);
}

interface IBasketRouteRegistryIndexFund {
    function poolManager() external view returns (IPoolManager);
    function hubRoute() external view returns (PoolKey memory);
}

/// @title IndexFundV1
/// @notice Immutable per-listing Basket holder. It exposes actions, never arbitrary asset withdrawals.
contract IndexFundV1 is IIndexFund, IUnlockCallback, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_EXECUTION_LOSS_BPS = 1_000;
    uint16 public constant CREATOR_REALIZATION_BPS = 100;
    uint128 public constant MIN_HUB_LIQUIDITY = 1e12;

    error AlreadyInitialized();
    error InvalidInitialization();
    error OnlyDesk();
    error OnlyCreator();
    error OnlyPoolManager();
    error InvalidAmount();
    error InvalidRoute();
    error InsufficientLiquidity();
    error UnsupportedTransfer();
    error UnexpectedPoolDelta();
    error MinOutputNotMet(uint256 actual, uint256 minimum);
    error NativeTransferRejected();

    bool public initialized;
    bool private _nativeSwapActive;
    IERC20 public usdg;
    IERC20 public indexToken;
    address public creator;
    address public creatorFeeRecipient;
    address public desk;
    address public burnNet;
    IHookIndexFund public hook;
    PoolId public poolId;
    IBasketRegistry public basketRegistry;
    IBasketSwapRouterIndexFund public basketRouter;
    IPoolManager public poolManager;
    IWETH public weth;
    PoolKey private _hubPool;

    event IndexFundInitialized(address indexed indexToken, address indexed creator, address indexed desk);
    event DeskProceedsInvested(uint256 usdgInRaw, uint256 indexOut);
    event IndexSold(uint256 indexIn, uint256 usdgOutRaw, uint256 creatorRaw, uint256 burnNetRaw);
    event HolderFeesClaimed(uint256 wethClaimed, uint256 usdgOutRaw, uint256 creatorRaw, uint256 burnNetRaw);

    constructor() {
        initialized = true;
    }

    function initialize(InitParams calldata params) external override {
        if (initialized) revert AlreadyInitialized();
        if (
            params.usdg.code.length == 0 || params.indexToken.code.length == 0 || params.creator == address(0)
                || params.creatorFeeRecipient == address(0) || params.desk.code.length == 0
                || params.burnNet.code.length == 0 || params.hook.code.length == 0
                || PoolId.unwrap(params.poolId) == bytes32(0) || params.basketRegistry.code.length == 0
                || params.basketRouter.code.length == 0 || params.basketRouteRegistry.code.length == 0
                || params.poolManager.code.length == 0 || params.weth.code.length == 0
        ) revert InvalidInitialization();
        if (!IBasketRegistry(params.basketRegistry).isBasket(params.indexToken)) revert InvalidInitialization();
        IBasketSwapRouterIndexFund router = IBasketSwapRouterIndexFund(params.basketRouter);
        if (router.usdg() != params.usdg || address(router.poolManager()) != params.poolManager) {
            revert InvalidInitialization();
        }
        address basketHook = router.basketHook();
        if (basketHook.code.length == 0) revert InvalidInitialization();
        IBasketHookIndexFund basketHookConfig = IBasketHookIndexFund(basketHook);
        if (
            address(basketHookConfig.poolManager()) != params.poolManager
                || basketHookConfig.basketRegistry() != params.basketRegistry
                || basketHookConfig.routeRegistry() != params.basketRouteRegistry
                || basketHookConfig.usdg() != params.usdg || basketHookConfig.weth() != params.weth
        ) revert InvalidInitialization();
        if (IBasketToken(params.indexToken).weth() != params.weth) revert InvalidInitialization();

        PoolKey memory hub = IBasketRouteRegistryIndexFund(params.basketRouteRegistry).hubRoute();
        if (
            address(IBasketRouteRegistryIndexFund(params.basketRouteRegistry).poolManager()) != params.poolManager
                || Currency.unwrap(hub.currency0) != address(0) || Currency.unwrap(hub.currency1) != params.usdg
                || address(hub.hooks) != address(0)
        ) revert InvalidInitialization();

        initialized = true;
        usdg = IERC20(params.usdg);
        indexToken = IERC20(params.indexToken);
        creator = params.creator;
        creatorFeeRecipient = params.creatorFeeRecipient;
        desk = params.desk;
        burnNet = params.burnNet;
        hook = IHookIndexFund(params.hook);
        poolId = params.poolId;
        basketRegistry = IBasketRegistry(params.basketRegistry);
        basketRouter = router;
        poolManager = IPoolManager(params.poolManager);
        weth = IWETH(params.weth);
        _hubPool = hub;

        usdg.forceApprove(params.basketRouter, type(uint256).max);
        indexToken.forceApprove(params.basketRouter, type(uint256).max);
        usdg.forceApprove(params.hook, type(uint256).max);
        emit IndexFundInitialized(params.indexToken, params.creator, params.desk);
    }

    function onDeskProceeds(uint256 usdgRaw) external override nonReentrant returns (uint256 indexOut) {
        if (msg.sender != desk) revert OnlyDesk();
        if (usdgRaw == 0 || usdg.balanceOf(address(this)) < usdgRaw) revert InvalidAmount();
        // BasketHook treats zero as "derive the protected minimum from every registered constituent route".
        indexOut = basketRouter.buyExactUsdg(address(indexToken), usdgRaw, 0, bytes(""), address(this));
        if (indexOut == 0) revert InvalidAmount();
        emit DeskProceedsInvested(usdgRaw, indexOut);
    }

    function sellIndex(uint256 indexAmount, uint256 minUsdgOut) external nonReentrant returns (uint256 usdgOut) {
        if (msg.sender != creator) revert OnlyCreator();
        if (indexAmount == 0 || minUsdgOut == 0 || indexAmount > indexToken.balanceOf(address(this))) {
            revert InvalidAmount();
        }
        usdgOut = basketRouter.sellExactBasket(address(indexToken), indexAmount, minUsdgOut, bytes(""), address(this));
        (uint256 creatorRaw, uint256 burnNetRaw) = _routeRealizedUSDG(usdgOut);
        emit IndexSold(indexAmount, usdgOut, creatorRaw, burnNetRaw);
    }

    function claimHolderFees(uint256 minUsdgOut) external nonReentrant returns (uint256 wethClaimed, uint256 usdgOut) {
        if (msg.sender != creator) revert OnlyCreator();
        if (minUsdgOut == 0) revert InvalidAmount();
        IBasketToken(address(indexToken)).claimHolderFeesFor(address(this));
        // Realize the complete balance so direct transfers cannot leave permanently stranded WETH dust.
        wethClaimed = IERC20(address(weth)).balanceOf(address(this));
        if (wethClaimed == 0) revert InvalidAmount();
        weth.withdraw(wethClaimed);

        uint256 internalMinimum = _minimumHubOutput(wethClaimed);
        uint256 minimum = minUsdgOut > internalMinimum ? minUsdgOut : internalMinimum;
        usdgOut = _swapNativeToUsdG(wethClaimed, minimum);
        (uint256 creatorRaw, uint256 burnNetRaw) = _routeRealizedUSDG(usdgOut);
        emit HolderFeesClaimed(wethClaimed, usdgOut, creatorRaw, burnNetRaw);
    }

    function hubPool() external view returns (PoolKey memory) {
        return _hubPool;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_nativeSwapActive) revert InvalidRoute();
        (uint256 nativeIn, uint256 minimum) = abi.decode(data, (uint256, uint256));
        BalanceDelta delta = poolManager.swap(
            _hubPool,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -SafeCast.toInt256(nativeIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            bytes("")
        );
        if (delta.amount0() != -SafeCast.toInt128(nativeIn) || delta.amount1() <= 0) revert UnexpectedPoolDelta();
        uint256 usdgOut = uint256(uint128(delta.amount1()));
        if (usdgOut < minimum) revert MinOutputNotMet(usdgOut, minimum);
        Currency.wrap(address(0)).settle(poolManager, address(this), nativeIn, false);
        Currency.wrap(address(usdg)).take(poolManager, address(this), usdgOut, false);
        return abi.encode(usdgOut);
    }

    function _swapNativeToUsdG(uint256 nativeIn, uint256 minimum) private returns (uint256 usdgOut) {
        _nativeSwapActive = true;
        usdgOut = abi.decode(poolManager.unlock(abi.encode(nativeIn, minimum)), (uint256));
        _nativeSwapActive = false;
    }

    function _minimumHubOutput(uint256 nativeIn) private view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_hubPool.toId());
        if (sqrtPriceX96 == 0 || poolManager.getLiquidity(_hubPool.toId()) < MIN_HUB_LIQUIDITY) {
            revert InsufficientLiquidity();
        }
        uint256 spotOut = _quoteAtSqrtPrice(nativeIn, sqrtPriceX96, true);
        return Math.mulDiv(spotOut, BPS - MAX_EXECUTION_LOSS_BPS, BPS);
    }

    function _quoteAtSqrtPrice(uint256 amountIn, uint160 sqrtPriceX96, bool zeroForOne)
        private
        pure
        returns (uint256 amountOut)
    {
        if (zeroForOne) {
            uint256 forwardIntermediate = FullMath.mulDiv(amountIn, sqrtPriceX96, Q96);
            return FullMath.mulDiv(forwardIntermediate, sqrtPriceX96, Q96);
        }
        uint256 reverseIntermediate = FullMath.mulDiv(amountIn, Q96, sqrtPriceX96);
        return FullMath.mulDiv(reverseIntermediate, Q96, sqrtPriceX96);
    }

    function _routeRealizedUSDG(uint256 amount) private returns (uint256 creatorRaw, uint256 burnNetRaw) {
        creatorRaw = Math.mulDiv(amount, CREATOR_REALIZATION_BPS, BPS);
        burnNetRaw = amount - creatorRaw;
        if (creatorRaw != 0) usdg.safeTransfer(creatorFeeRecipient, creatorRaw);
        if (hook.addPendingUSDG(poolId, burnNetRaw) != burnNetRaw) revert UnsupportedTransfer();
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert NativeTransferRejected();
    }
}
