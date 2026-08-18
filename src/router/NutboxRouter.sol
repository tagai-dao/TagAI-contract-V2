// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import {IPoolManager as IUniswapV4PoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks as IUniswapV4Hooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey as UniswapV4PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency as UniswapV4Currency} from "v4-core/types/Currency.sol";
import {
    BalanceDelta as UniswapV4BalanceDelta,
    BalanceDeltaLibrary as UniswapV4BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {TickMath as UniswapV4TickMath} from "v4-core/libraries/TickMath.sol";

import {ICLPoolManager as IPancakeV4CLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IPoolManager as IPancakeV4PoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IVault as IPancakeV4Vault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks as IPancakeV4Hooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey as PancakeV4PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency as PancakeV4Currency} from "infinity-core/src/types/Currency.sol";
import {
    BalanceDelta as PancakeV4BalanceDelta,
    BalanceDeltaLibrary as PancakeV4BalanceDeltaLibrary
} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath as PancakeV4TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import "./INutboxRouter.sol";
import "./NutboxSpotPrice.sol";

interface INutboxV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface INutboxPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface INutboxWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title NutboxRouter
 * @notice Platform-managed token routes for permissionless spot quotes and exact-input swaps.
 * @dev The owner registers one authenticated current DEX pool per normalized token pair and selects
 *      shared routes made of those stable pair IDs. Replacing a pair's pool immediately updates every
 *      dependent route without changing the route itself.
 *      Any contract or externally owned account can quote or trade over the current route, which
 *      can be traversed in either direction over at most five pools. Route replacement immediately
 *      affects all future quotes and swaps without requiring callers to update their configuration.
 *      Mixed routes can execute through constructor-approved V2 Router02 factories, the configured
 *      PancakeSwap V3 SmartRouter, Uniswap V4 PoolManagers and PancakeSwap Infinity CL PoolManagers.
 */
contract NutboxRouter is INutboxRouter, Ownable2Step, ReentrancyGuard, IUnlockCallback, ILockCallback {
    using Address for address payable;
    using PancakeV4BalanceDeltaLibrary for PancakeV4BalanceDelta;
    using SafeERC20 for IERC20;
    using UniswapV4BalanceDeltaLibrary for UniswapV4BalanceDelta;

    uint256 public constant MAX_ROUTE_HOPS = 5;

    address public immutable override wrappedNative;
    address public immutable override pancakeV3Router;
    address public immutable override pancakeV3Factory;

    mapping(address => address) public override v2RouterForFactory;
    mapping(address => bool) public override allowedV2Factory;
    mapping(address => bool) public override allowedV3Factory;
    mapping(address => bool) public override allowedUniswapV4Manager;
    mapping(address => bool) public override allowedPancakeV4CLManager;
    mapping(address => bool) public allowedPancakeV4Vault;

    struct StoredPricePool {
        bool enabled;
        uint32 routeReferences;
        address token0;
        address token1;
        SourceType sourceType;
        bytes sourceData;
    }

    struct StoredRoute {
        bool enabled;
        bytes32[] poolIds;
    }

    mapping(bytes32 => StoredPricePool) private _pricePools;
    mapping(bytes32 => StoredRoute) private _routes;
    address private _activeCallback;

    event PricePoolAdded(
        bytes32 indexed poolId, address indexed token0, address indexed token1, SourceType sourceType, bytes sourceData
    );
    event PricePoolReplaced(
        bytes32 indexed poolId,
        address indexed token0,
        address indexed token1,
        SourceType previousSourceType,
        SourceType newSourceType,
        bytes sourceData
    );
    event PricePoolRemoved(bytes32 indexed poolId);
    event RouteAdded(address indexed token0, address indexed token1, bytes32 indexed routeHash, bytes32[] poolIds);
    event RouteReplaced(address indexed token0, address indexed token1, bytes32 indexed routeHash, bytes32[] poolIds);
    event RouteRemoved(address indexed token0, address indexed token1);
    event SwapExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    error InvalidAddress();
    error InvalidSource();
    error UnsupportedSource();
    error InvalidPair();
    error PoolNotInitialized();
    error PriceUnavailable();
    error InvalidRoute();
    error PricePoolAlreadyExists();
    error PricePoolNotFound();
    error PricePoolInUse();
    error RouteAlreadyExists();
    error RouteNotFound();
    error InvalidAmount();
    error InvalidNativeValue();
    error InvalidRecipient();
    error DeadlineExpired();
    error UnsupportedSwapSource();
    error UnsupportedInputToken();
    error InvalidSwapOutput();
    error InvalidNativeSender();
    error InvalidCallback();

    constructor(
        address wrappedNative_,
        address pancakeV3Router_,
        address[] memory v2Routers_,
        address[] memory v2Factories_,
        address[] memory v3Factories_,
        address[] memory uniswapV4Managers_,
        address[] memory pancakeV4CLManagers_,
        bytes memory initialConfig_
    ) {
        if (wrappedNative_.code.length == 0 || pancakeV3Router_.code.length == 0) {
            revert InvalidAddress();
        }
        wrappedNative = wrappedNative_;
        pancakeV3Router = pancakeV3Router_;
        _allow(v2Factories_, allowedV2Factory);
        _allow(v3Factories_, allowedV3Factory);
        _allow(uniswapV4Managers_, allowedUniswapV4Manager);
        _allow(pancakeV4CLManagers_, allowedPancakeV4CLManager);
        _configurePancakeV4Vaults(pancakeV4CLManagers_);
        _configureV2Routers(v2Routers_);

        INutboxPancakeV3Router router = INutboxPancakeV3Router(pancakeV3Router_);
        address factory = router.factory();
        if (router.WETH9() != wrappedNative_ || factory.code.length == 0 || !allowedV3Factory[factory]) {
            revert InvalidSource();
        }
        pancakeV3Factory = factory;

        if (initialConfig_.length != 0) {
            (InitialPricePool[] memory initialPricePools, InitialRoute[] memory initialRoutes) =
                abi.decode(initialConfig_, (InitialPricePool[], InitialRoute[]));
            for (uint256 i; i < initialPricePools.length; ++i) {
                _bootstrapPricePool(initialPricePools[i]);
            }
            for (uint256 i; i < initialRoutes.length; ++i) {
                _bootstrapRoute(initialRoutes[i]);
            }
        }
    }

    /// @dev Constructor-only trusted storage path. Deployment tooling validates the source off-chain.
    function _bootstrapPricePool(InitialPricePool memory config) private {
        bytes32 poolId = _uncheckedPricePoolId(config.token0, config.token1);
        StoredPricePool storage pool = _pricePools[poolId];
        pool.enabled = true;
        pool.token0 = config.token0;
        pool.token1 = config.token1;
        pool.sourceType = config.sourceType;
        pool.sourceData = config.sourceData;
        emit PricePoolAdded(poolId, config.token0, config.token1, config.sourceType, config.sourceData);
    }

    /// @dev Constructor-only trusted storage path. It deliberately skips route validation.
    function _bootstrapRoute(InitialRoute memory config) private {
        address normalizedIn = _normalized(config.tokenIn);
        address normalizedOut = _normalized(config.tokenOut);
        bool forward = uint160(normalizedIn) < uint160(normalizedOut);
        address canonicalToken0 = forward ? normalizedIn : normalizedOut;
        address canonicalToken1 = forward ? normalizedOut : normalizedIn;
        bytes32 routeKey = keccak256(abi.encode(canonicalToken0, canonicalToken1));

        StoredRoute storage route = _routes[routeKey];
        route.enabled = true;
        uint256 length = config.poolIds.length;
        bytes32[] memory canonicalPoolIds = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 poolId = forward ? config.poolIds[i] : config.poolIds[length - 1 - i];
            route.poolIds.push(poolId);
            canonicalPoolIds[i] = poolId;
            ++_pricePools[poolId].routeReferences;
        }
        emit RouteAdded(canonicalToken0, canonicalToken1, keccak256(abi.encode(canonicalPoolIds)), canonicalPoolIds);
    }

    function _uncheckedPricePoolId(address tokenA, address tokenB) private view returns (bytes32 poolId) {
        address normalizedA = _normalized(tokenA);
        address normalizedB = _normalized(tokenB);
        (address canonicalToken0, address canonicalToken1) =
            uint160(normalizedA) < uint160(normalizedB) ? (normalizedA, normalizedB) : (normalizedB, normalizedA);
        poolId = keccak256(abi.encode(canonicalToken0, canonicalToken1));
    }

    receive() external payable {
        if (
            msg.sender != wrappedNative && !allowedUniswapV4Manager[msg.sender] && !_isAllowedPancakeV4Vault(msg.sender)
        ) revert InvalidNativeSender();
    }

    function hasPricePool(bytes32 poolId) external view override returns (bool) {
        return _pricePools[poolId].enabled;
    }

    function pricePoolId(address tokenA, address tokenB) external view override returns (bytes32 poolId) {
        return _pricePoolId(tokenA, tokenB);
    }

    function pricePool(bytes32 poolId)
        external
        view
        override
        returns (
            bool enabled,
            uint32 routeReferences,
            address token0,
            address token1,
            SourceType sourceType,
            bytes memory sourceData
        )
    {
        StoredPricePool storage pool = _pricePools[poolId];
        return (pool.enabled, pool.routeReferences, pool.token0, pool.token1, pool.sourceType, pool.sourceData);
    }

    function addPricePool(SourceType sourceType, bytes calldata sourceData)
        external
        override
        onlyOwner
        returns (bytes32 poolId)
    {
        (address token0, address token1, bytes32 resolvedPoolId) = _validatePricePool(sourceType, sourceData);
        poolId = resolvedPoolId;
        if (_pricePools[poolId].enabled) revert PricePoolAlreadyExists();

        StoredPricePool storage pool = _pricePools[poolId];
        pool.enabled = true;
        pool.token0 = token0;
        pool.token1 = token1;
        pool.sourceType = sourceType;
        pool.sourceData = sourceData;
        emit PricePoolAdded(poolId, token0, token1, sourceType, sourceData);
    }

    function replacePricePool(SourceType sourceType, bytes calldata sourceData)
        external
        override
        onlyOwner
        returns (bytes32 poolId)
    {
        (address token0, address token1, bytes32 resolvedPoolId) = _validatePricePool(sourceType, sourceData);
        poolId = resolvedPoolId;
        StoredPricePool storage pool = _pricePools[poolId];
        if (!pool.enabled) revert PricePoolNotFound();

        SourceType previousSourceType = pool.sourceType;
        pool.token0 = token0;
        pool.token1 = token1;
        pool.sourceType = sourceType;
        pool.sourceData = sourceData;
        emit PricePoolReplaced(poolId, token0, token1, previousSourceType, sourceType, sourceData);
    }

    function removePricePool(bytes32 poolId) external override onlyOwner {
        StoredPricePool storage pool = _pricePools[poolId];
        if (!pool.enabled) revert PricePoolNotFound();
        if (pool.routeReferences != 0) revert PricePoolInUse();
        delete _pricePools[poolId];
        emit PricePoolRemoved(poolId);
    }

    function hasRoute(address tokenIn, address tokenOut) external view override returns (bool) {
        (bytes32 routeKey,,) = _routeKey(tokenIn, tokenOut);
        return _routes[routeKey].enabled;
    }

    function routePoolCount(address tokenIn, address tokenOut) external view override returns (uint256) {
        (bytes32 routeKey,,) = _routeKey(tokenIn, tokenOut);
        return _routes[routeKey].poolIds.length;
    }

    function routePoolAt(address tokenIn, address tokenOut, uint256 index)
        external
        view
        override
        returns (bytes32 poolId)
    {
        (bytes32 routeKey, bool forward,) = _routeKey(tokenIn, tokenOut);
        StoredRoute storage route = _routes[routeKey];
        if (!route.enabled) revert RouteNotFound();
        uint256 length = route.poolIds.length;
        return forward ? route.poolIds[index] : route.poolIds[length - 1 - index];
    }

    function addRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external override onlyOwner {
        (bytes32 routeKey, bool forward, address canonicalToken0) = _routeKey(tokenIn, tokenOut);
        if (_routes[routeKey].enabled) revert RouteAlreadyExists();
        address canonicalToken1 = _otherEndpoint(tokenIn, tokenOut, canonicalToken0);
        _setRoute(routeKey, canonicalToken0, canonicalToken1, forward, poolIds);
        bytes32[] memory canonicalPoolIds = _copyRoutePoolIds(_routes[routeKey]);
        emit RouteAdded(canonicalToken0, canonicalToken1, keccak256(abi.encode(canonicalPoolIds)), canonicalPoolIds);
    }

    function replaceRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external override onlyOwner {
        (bytes32 routeKey, bool forward, address canonicalToken0) = _routeKey(tokenIn, tokenOut);
        StoredRoute storage route = _routes[routeKey];
        if (!route.enabled) revert RouteNotFound();

        _validateRoute(canonicalToken0, _otherEndpoint(tokenIn, tokenOut, canonicalToken0), forward, poolIds);
        _releaseRoutePools(route);
        _storeRoute(route, forward, poolIds);

        bytes32[] memory canonicalPoolIds = _copyRoutePoolIds(route);
        emit RouteReplaced(
            canonicalToken0,
            _otherEndpoint(tokenIn, tokenOut, canonicalToken0),
            keccak256(abi.encode(canonicalPoolIds)),
            canonicalPoolIds
        );
    }

    function removeRoute(address tokenIn, address tokenOut) external override onlyOwner {
        (bytes32 routeKey,, address canonicalToken0) = _routeKey(tokenIn, tokenOut);
        StoredRoute storage route = _routes[routeKey];
        if (!route.enabled) revert RouteNotFound();
        _releaseRoutePools(route);
        delete _routes[routeKey];
        emit RouteRemoved(canonicalToken0, _otherEndpoint(tokenIn, tokenOut, canonicalToken0));
    }

    function validateRoute(address tokenIn, address tokenOut) external view override {
        address normalizedIn = _normalized(tokenIn);
        address normalizedOut = _normalized(tokenOut);
        if (!_validEndpoint(normalizedIn) || !_validEndpoint(normalizedOut)) revert InvalidRoute();
        if (normalizedIn == normalizedOut) return;
        _quote(tokenIn, tokenOut, 0);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut)
    {
        address normalizedIn = _normalized(tokenIn);
        address normalizedOut = _normalized(tokenOut);
        if (!_validEndpoint(normalizedIn) || !_validEndpoint(normalizedOut)) revert InvalidRoute();
        if (normalizedIn == normalizedOut) return amountIn;
        amountOut = _quote(tokenIn, tokenOut, amountIn);
        if (amountIn != 0 && amountOut == 0) revert NutboxSpotPrice.PriceUnavailable();
    }

    function quoteNative(address token, uint256 tokenAmount) external view override returns (uint256 nativeAmount) {
        address normalizedToken = _normalized(token);
        if (normalizedToken == wrappedNative) return tokenAmount;
        nativeAmount = _quote(normalizedToken, wrappedNative, tokenAmount);
        if (tokenAmount != 0 && nativeAmount == 0) revert NutboxSpotPrice.PriceUnavailable();
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable override nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();

        address normalizedIn = _normalized(tokenIn);
        address normalizedOut = _normalized(tokenOut);
        if (normalizedIn == normalizedOut) {
            if (tokenIn == tokenOut) revert InvalidRoute();
            return _swapWrappedNative(tokenIn, amountIn, amountOutMinimum, recipient);
        }

        _receiveInput(tokenIn, amountIn);
        amountOut = _executeRoute(tokenIn, tokenOut, amountIn, deadline);
        if (amountOut == 0 || amountOut < amountOutMinimum) revert PriceUnavailable();
        _deliverOutput(tokenOut, amountOut, recipient);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeCallback || !allowedUniswapV4Manager[msg.sender]) revert InvalidCallback();
        (UniswapV4Source memory source, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (UniswapV4Source, bool, uint256));
        if (source.poolManager != msg.sender) revert InvalidCallback();

        UniswapV4PoolKey memory key = UniswapV4PoolKey({
            currency0: UniswapV4Currency.wrap(source.currency0),
            currency1: UniswapV4Currency.wrap(source.currency1),
            fee: source.fee,
            tickSpacing: source.tickSpacing,
            hooks: IUniswapV4Hooks(source.hooks)
        });
        IUniswapV4PoolManager manager = IUniswapV4PoolManager(msg.sender);
        UniswapV4BalanceDelta delta = manager.swap(
            key,
            IUniswapV4PoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? UniswapV4TickMath.MIN_SQRT_PRICE + 1
                    : UniswapV4TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        uint256 amountOut = _validateUniswapV4Delta(delta, zeroForOne, amountIn);
        UniswapV4Currency input = zeroForOne ? key.currency0 : key.currency1;
        UniswapV4Currency output = zeroForOne ? key.currency1 : key.currency0;
        _settleUniswapV4(manager, input, amountIn);
        manager.take(output, address(this), amountOut);
        return abi.encode(amountOut);
    }

    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeCallback || !_isAllowedPancakeV4Vault(msg.sender)) revert InvalidCallback();
        (PancakeV4CLSource memory source, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (PancakeV4CLSource, bool, uint256));
        if (!allowedPancakeV4CLManager[source.poolManager]) revert InvalidCallback();

        IPancakeV4CLPoolManager manager = IPancakeV4CLPoolManager(source.poolManager);
        IPancakeV4Vault vault = manager.vault();
        if (address(vault) != msg.sender) revert InvalidCallback();
        return abi.encode(_executePancakeV4Swap(source, zeroForOne, amountIn, manager, vault));
    }

    function _executePancakeV4Swap(
        PancakeV4CLSource memory source,
        bool zeroForOne,
        uint256 amountIn,
        IPancakeV4CLPoolManager manager,
        IPancakeV4Vault vault
    ) internal returns (uint256 amountOut) {
        PancakeV4PoolKey memory key = PancakeV4PoolKey({
            currency0: PancakeV4Currency.wrap(source.currency0),
            currency1: PancakeV4Currency.wrap(source.currency1),
            hooks: IPancakeV4Hooks(source.hooks),
            poolManager: IPancakeV4PoolManager(source.poolManager),
            fee: source.fee,
            parameters: source.parameters
        });
        PancakeV4BalanceDelta delta = manager.swap(
            key,
            IPancakeV4CLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? PancakeV4TickMath.MIN_SQRT_RATIO + 1
                    : PancakeV4TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );

        amountOut = _validatePancakeV4Delta(delta, zeroForOne, amountIn);
        PancakeV4Currency input = zeroForOne ? key.currency0 : key.currency1;
        PancakeV4Currency output = zeroForOne ? key.currency1 : key.currency0;
        _settlePancakeV4(vault, input, amountIn);
        vault.take(output, address(this), amountOut);
    }

    function _receiveInput(address tokenIn, uint256 amountIn) internal {
        IERC20 inputToken = IERC20(_normalized(tokenIn));
        uint256 balanceBefore = inputToken.balanceOf(address(this));
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert InvalidNativeValue();
            INutboxWrappedNative(wrappedNative).deposit{value: amountIn}();
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            inputToken.safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (inputToken.balanceOf(address(this)) - balanceBefore != amountIn) revert UnsupportedInputToken();
    }

    function _executeRoute(address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline)
        internal
        returns (uint256 amountOut)
    {
        (bytes32 routeKey, bool forward,) = _routeKey(tokenIn, tokenOut);
        StoredRoute storage route = _routes[routeKey];
        if (!route.enabled) revert RouteNotFound();

        address currentToken = _normalized(tokenIn);
        uint256 length = route.poolIds.length;
        amountOut = amountIn;
        for (uint256 i; i < length; ++i) {
            bytes32 poolId = forward ? route.poolIds[i] : route.poolIds[length - 1 - i];
            StoredPricePool storage pool = _pricePools[poolId];
            if (!pool.enabled) revert PricePoolNotFound();
            (address actualTokenIn, address actualTokenOut) = _actualPoolDirection(currentToken, pool);
            amountOut = _executePool(pool, actualTokenIn, actualTokenOut, amountOut, deadline);
            currentToken = _normalized(actualTokenOut);
        }
        if (currentToken != _normalized(tokenOut)) revert InvalidRoute();
    }

    function _executePool(
        StoredPricePool storage pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (pool.sourceType == SourceType.V2_PAIR) {
            return _swapV2(tokenIn, tokenOut, amountIn, deadline, pool.sourceData);
        }
        if (pool.sourceType == SourceType.V3_POOL) {
            return _swapV3(tokenIn, tokenOut, amountIn, pool.sourceData);
        }
        if (pool.sourceType == SourceType.UNISWAP_V4) {
            return _swapUniswapV4(tokenIn, tokenOut, amountIn, pool.sourceData);
        }
        if (pool.sourceType == SourceType.PANCAKE_V4_CL) {
            return _swapPancakeV4(tokenIn, tokenOut, amountIn, pool.sourceData);
        }
        revert UnsupportedSwapSource();
    }

    function _swapV2(address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert UnsupportedSwapSource();
        (address factory, address pair) = abi.decode(sourceData, (address, address));
        address dexRouter = v2RouterForFactory[factory];
        if (
            dexRouter == address(0) || INutboxV2Factory(factory).getPair(tokenIn, tokenOut) != pair
                || INutboxV2Pair(pair).factory() != factory
        ) revert InvalidSource();

        IERC20 outputToken = IERC20(tokenOut);
        uint256 balanceBefore = outputToken.balanceOf(address(this));
        IERC20(tokenIn).forceApprove(dexRouter, amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts =
            INutboxV2Router(dexRouter).swapExactTokensForTokens(amountIn, 0, path, address(this), deadline);
        IERC20(tokenIn).forceApprove(dexRouter, 0);
        if (amounts.length != 2 || amounts[0] != amountIn) revert InvalidSwapOutput();
        amountOut = amounts[1];
        if (amountOut == 0 || outputToken.balanceOf(address(this)) - balanceBefore != amountOut) {
            revert InvalidSwapOutput();
        }
    }

    function _swapV3(address tokenIn, address tokenOut, uint256 amountIn, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert UnsupportedSwapSource();
        (address factory, address v3Pool) = abi.decode(sourceData, (address, address));
        if (factory != pancakeV3Factory) revert UnsupportedSwapSource();
        INutboxV3Pool pool = INutboxV3Pool(v3Pool);
        uint24 fee = pool.fee();
        if (pool.factory() != factory || INutboxV3Factory(factory).getPool(tokenIn, tokenOut, fee) != v3Pool) {
            revert InvalidSource();
        }

        IERC20 outputToken = IERC20(tokenOut);
        uint256 balanceBefore = outputToken.balanceOf(address(this));
        IERC20(tokenIn).forceApprove(pancakeV3Router, amountIn);
        amountOut = INutboxPancakeV3Router(pancakeV3Router)
            .exactInputSingle(
                INutboxPancakeV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        IERC20(tokenIn).forceApprove(pancakeV3Router, 0);
        if (amountOut == 0 || outputToken.balanceOf(address(this)) - balanceBefore != amountOut) {
            revert InvalidSwapOutput();
        }
    }

    function _swapUniswapV4(address tokenIn, address tokenOut, uint256 amountIn, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        UniswapV4Source memory source = abi.decode(sourceData, (UniswapV4Source));
        if (!allowedUniswapV4Manager[source.poolManager]) revert InvalidSource();
        bool zeroForOne = _validateV4Direction(tokenIn, tokenOut, source.currency0, source.currency1);
        _prepareV4NativeInput(tokenIn, amountIn);
        uint256 balanceBefore = _assetBalance(tokenOut);
        _activeCallback = source.poolManager;
        amountOut = abi.decode(
            IUniswapV4PoolManager(source.poolManager).unlock(abi.encode(source, zeroForOne, amountIn)), (uint256)
        );
        _activeCallback = address(0);
        _verifyAndWrapV4Output(tokenOut, amountOut, balanceBefore);
    }

    function _swapPancakeV4(address tokenIn, address tokenOut, uint256 amountIn, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        PancakeV4CLSource memory source = abi.decode(sourceData, (PancakeV4CLSource));
        if (!allowedPancakeV4CLManager[source.poolManager]) revert InvalidSource();
        bool zeroForOne = _validateV4Direction(tokenIn, tokenOut, source.currency0, source.currency1);
        IPancakeV4CLPoolManager manager = IPancakeV4CLPoolManager(source.poolManager);
        IPancakeV4Vault vault = manager.vault();
        if (!_isAllowedPancakeV4Vault(address(vault))) revert InvalidSource();
        _prepareV4NativeInput(tokenIn, amountIn);
        uint256 balanceBefore = _assetBalance(tokenOut);
        if (vault.getLocker() == address(0)) {
            _activeCallback = address(vault);
            amountOut = abi.decode(vault.lock(abi.encode(source, zeroForOne, amountIn)), (uint256));
            _activeCallback = address(0);
        } else {
            amountOut = _executePancakeV4Swap(source, zeroForOne, amountIn, manager, vault);
        }
        _verifyAndWrapV4Output(tokenOut, amountOut, balanceBefore);
    }

    function _deliverOutput(address tokenOut, uint256 amountOut, address recipient) internal {
        if (tokenOut == address(0)) {
            INutboxWrappedNative(wrappedNative).withdraw(amountOut);
            payable(recipient).sendValue(amountOut);
        } else {
            IERC20 outputToken = IERC20(tokenOut);
            uint256 balanceBefore = outputToken.balanceOf(recipient);
            outputToken.safeTransfer(recipient, amountOut);
            if (outputToken.balanceOf(recipient) - balanceBefore != amountOut) revert InvalidSwapOutput();
        }
    }

    function _swapWrappedNative(address tokenIn, uint256 amountIn, uint256 amountOutMinimum, address recipient)
        internal
        returns (uint256 amountOut)
    {
        amountOut = amountIn;
        if (amountOut < amountOutMinimum) revert PriceUnavailable();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert InvalidNativeValue();
            INutboxWrappedNative(wrappedNative).deposit{value: amountIn}();
            IERC20(wrappedNative).safeTransfer(recipient, amountOut);
        } else {
            if (msg.value != 0 || tokenIn != wrappedNative) revert InvalidNativeValue();
            IERC20 token = IERC20(wrappedNative);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amountIn);
            if (token.balanceOf(address(this)) - balanceBefore != amountIn) revert UnsupportedInputToken();
            INutboxWrappedNative(wrappedNative).withdraw(amountOut);
            payable(recipient).sendValue(amountOut);
        }

        emit SwapExecuted(
            msg.sender, tokenIn, tokenIn == address(0) ? wrappedNative : address(0), amountIn, amountOut, recipient
        );
    }

    function _setRoute(
        bytes32 routeKey,
        address canonicalToken0,
        address canonicalToken1,
        bool forward,
        bytes32[] calldata poolIds
    ) internal {
        _validateRoute(canonicalToken0, canonicalToken1, forward, poolIds);
        StoredRoute storage route = _routes[routeKey];
        route.enabled = true;
        _storeRoute(route, forward, poolIds);
    }

    function _storeRoute(StoredRoute storage route, bool forward, bytes32[] calldata poolIds) internal {
        uint256 length = poolIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 poolId = forward ? poolIds[i] : poolIds[length - 1 - i];
            route.poolIds.push(poolId);
            ++_pricePools[poolId].routeReferences;
        }
    }

    function _validateRoute(address tokenIn, address tokenOut, bool forward, bytes32[] calldata poolIds) internal view {
        uint256 length = poolIds.length;
        if (length == 0 || length > MAX_ROUTE_HOPS) revert InvalidRoute();

        address currentToken = forward ? tokenIn : tokenOut;
        address expectedToken = forward ? tokenOut : tokenIn;
        address[6] memory visited;
        visited[0] = currentToken;

        for (uint256 i; i < length; ++i) {
            bytes32 poolId = poolIds[i];
            StoredPricePool storage pool = _pricePools[poolId];
            if (!pool.enabled) revert PricePoolNotFound();

            address nextToken = _nextToken(currentToken, pool);
            for (uint256 j; j <= i; ++j) {
                if (visited[j] == nextToken) revert InvalidRoute();
            }
            visited[i + 1] = nextToken;

            (address actualTokenIn, address actualTokenOut) = _actualPoolDirection(currentToken, pool);
            NutboxSpotPrice.quote(
                INutboxRouter(address(this)), actualTokenIn, actualTokenOut, 0, pool.sourceType, pool.sourceData
            );
            currentToken = nextToken;
        }
        if (currentToken != expectedToken) revert InvalidRoute();
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256 amountOut) {
        (bytes32 routeKey, bool forward,) = _routeKey(tokenIn, tokenOut);
        StoredRoute storage route = _routes[routeKey];
        if (!route.enabled) revert RouteNotFound();

        address currentToken = _normalized(tokenIn);
        address expectedToken = _normalized(tokenOut);
        uint256 currentAmount = amountIn;
        uint256 length = route.poolIds.length;

        for (uint256 i; i < length; ++i) {
            bytes32 poolId = forward ? route.poolIds[i] : route.poolIds[length - 1 - i];
            StoredPricePool storage pool = _pricePools[poolId];
            if (!pool.enabled) revert PricePoolNotFound();
            (address actualTokenIn, address actualTokenOut) = _actualPoolDirection(currentToken, pool);
            currentAmount = NutboxSpotPrice.quote(
                INutboxRouter(address(this)),
                actualTokenIn,
                actualTokenOut,
                currentAmount,
                pool.sourceType,
                pool.sourceData
            );
            currentToken = _normalized(actualTokenOut);
        }
        if (currentToken != expectedToken) revert InvalidRoute();
        return currentAmount;
    }

    function _validateV4Direction(address tokenIn, address tokenOut, address currency0, address currency1)
        internal
        pure
        returns (bool zeroForOne)
    {
        if (tokenIn == currency0 && tokenOut == currency1) return true;
        if (tokenIn == currency1 && tokenOut == currency0) return false;
        revert InvalidPair();
    }

    function _validateUniswapV4Delta(UniswapV4BalanceDelta delta, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint256 amountOut)
    {
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0 || uint256(-int256(inputDelta)) != amountIn) {
            revert InvalidSwapOutput();
        }
        amountOut = uint256(uint128(outputDelta));
    }

    function _validatePancakeV4Delta(PancakeV4BalanceDelta delta, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint256 amountOut)
    {
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0 || uint256(-int256(inputDelta)) != amountIn) {
            revert InvalidSwapOutput();
        }
        amountOut = uint256(uint128(outputDelta));
    }

    function _settleUniswapV4(IUniswapV4PoolManager manager, UniswapV4Currency currency, uint256 amount) internal {
        address token = UniswapV4Currency.unwrap(currency);
        if (token == address(0)) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            IERC20(token).safeTransfer(address(manager), amount);
            manager.settle();
        }
    }

    function _settlePancakeV4(IPancakeV4Vault vault, PancakeV4Currency currency, uint256 amount) internal {
        address token = PancakeV4Currency.unwrap(currency);
        if (token == address(0)) {
            vault.settle{value: amount}();
        } else {
            vault.sync(currency);
            IERC20(token).safeTransfer(address(vault), amount);
            vault.settle();
        }
    }

    function _prepareV4NativeInput(address tokenIn, uint256 amountIn) internal {
        if (tokenIn == address(0)) INutboxWrappedNative(wrappedNative).withdraw(amountIn);
    }

    function _verifyAndWrapV4Output(address tokenOut, uint256 amountOut, uint256 balanceBefore) internal {
        if (amountOut == 0 || _assetBalance(tokenOut) - balanceBefore != amountOut) revert InvalidSwapOutput();
        if (tokenOut == address(0)) {
            uint256 wrappedBalanceBefore = IERC20(wrappedNative).balanceOf(address(this));
            INutboxWrappedNative(wrappedNative).deposit{value: amountOut}();
            if (IERC20(wrappedNative).balanceOf(address(this)) - wrappedBalanceBefore != amountOut) {
                revert InvalidSwapOutput();
            }
        }
    }

    function _assetBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _routeKey(address tokenIn, address tokenOut)
        internal
        view
        returns (bytes32 routeKey, bool forward, address canonicalToken0)
    {
        address normalizedIn = _normalized(tokenIn);
        address normalizedOut = _normalized(tokenOut);
        if (!_validEndpoint(normalizedIn) || !_validEndpoint(normalizedOut) || normalizedIn == normalizedOut) {
            revert InvalidRoute();
        }
        forward = uint160(normalizedIn) < uint160(normalizedOut);
        canonicalToken0 = forward ? normalizedIn : normalizedOut;
        address canonicalToken1 = forward ? normalizedOut : normalizedIn;
        routeKey = keccak256(abi.encode(canonicalToken0, canonicalToken1));
    }

    function _releaseRoutePools(StoredRoute storage route) internal {
        uint256 length = route.poolIds.length;
        for (uint256 i; i < length; ++i) {
            --_pricePools[route.poolIds[i]].routeReferences;
        }
        delete route.poolIds;
    }

    function _copyRoutePoolIds(StoredRoute storage route) internal view returns (bytes32[] memory poolIds) {
        uint256 length = route.poolIds.length;
        poolIds = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            poolIds[i] = route.poolIds[i];
        }
    }

    function _nextToken(address currentToken, StoredPricePool storage pool) internal view returns (address) {
        if (_normalized(pool.token0) == currentToken) return _normalized(pool.token1);
        if (_normalized(pool.token1) == currentToken) return _normalized(pool.token0);
        revert InvalidRoute();
    }

    function _actualPoolDirection(address currentToken, StoredPricePool storage pool)
        internal
        view
        returns (address actualTokenIn, address actualTokenOut)
    {
        if (_normalized(pool.token0) == currentToken) return (pool.token0, pool.token1);
        if (_normalized(pool.token1) == currentToken) return (pool.token1, pool.token0);
        revert InvalidRoute();
    }

    function _otherEndpoint(address tokenIn, address tokenOut, address canonicalToken0)
        internal
        view
        returns (address)
    {
        address normalizedIn = _normalized(tokenIn);
        address normalizedOut = _normalized(tokenOut);
        return normalizedIn == canonicalToken0 ? normalizedOut : normalizedIn;
    }

    function _normalized(address token) internal view returns (address) {
        return token == address(0) ? wrappedNative : token;
    }

    function _validEndpoint(address token) internal view returns (bool) {
        return token != address(0) && token.code.length != 0;
    }

    function _validPoolTokens(address token0, address token1) internal view returns (bool) {
        if (token0 == token1) return false;
        if (token0 == address(0)) return token1.code.length != 0;
        if (token1 == address(0)) return token0.code.length != 0;
        return token0.code.length != 0 && token1.code.length != 0;
    }

    function _validatePricePool(SourceType sourceType, bytes calldata sourceData)
        internal
        view
        returns (address token0, address token1, bytes32 poolId)
    {
        (token0, token1) = NutboxSpotPrice.sourceTokens(sourceType, sourceData);
        if (!_validPoolTokens(token0, token1)) revert InvalidPair();

        address validateIn = token0 == address(0) ? token1 : token0;
        address validateOut = token0 == address(0) ? token0 : token1;
        NutboxSpotPrice.quote(INutboxRouter(address(this)), validateIn, validateOut, 0, sourceType, sourceData);
        poolId = _pricePoolId(token0, token1);
    }

    function _pricePoolId(address tokenA, address tokenB) internal view returns (bytes32 poolId) {
        address normalizedA = _normalized(tokenA);
        address normalizedB = _normalized(tokenB);
        if (!_validEndpoint(normalizedA) || !_validEndpoint(normalizedB) || normalizedA == normalizedB) {
            revert InvalidPair();
        }
        (address canonicalToken0, address canonicalToken1) =
            uint160(normalizedA) < uint160(normalizedB) ? (normalizedA, normalizedB) : (normalizedB, normalizedA);
        poolId = keccak256(abi.encode(canonicalToken0, canonicalToken1));
    }

    function _allow(address[] memory sources, mapping(address => bool) storage allowed) internal {
        for (uint256 i; i < sources.length; ++i) {
            address source = sources[i];
            if (source.code.length == 0) revert InvalidAddress();
            allowed[source] = true;
        }
    }

    function _configureV2Routers(address[] memory routers) internal {
        for (uint256 i; i < routers.length; ++i) {
            address dexRouter = routers[i];
            if (dexRouter.code.length == 0) revert InvalidAddress();
            INutboxV2Router router = INutboxV2Router(dexRouter);
            address factory = router.factory();
            if (
                router.WETH() != wrappedNative || !allowedV2Factory[factory]
                    || v2RouterForFactory[factory] != address(0)
            ) revert InvalidSource();
            v2RouterForFactory[factory] = dexRouter;
        }
    }

    function _configurePancakeV4Vaults(address[] memory managers) internal {
        for (uint256 i; i < managers.length; ++i) {
            address vault = address(IPancakeV4CLPoolManager(managers[i]).vault());
            if (vault.code.length == 0) revert InvalidSource();
            allowedPancakeV4Vault[vault] = true;
        }
    }

    function _isAllowedPancakeV4Vault(address vault) internal view returns (bool) {
        return allowedPancakeV4Vault[vault];
    }
}
