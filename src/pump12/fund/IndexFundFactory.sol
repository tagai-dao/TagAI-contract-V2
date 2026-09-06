// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IBasketRegistry} from "../../interfaces/IBasketRegistry.sol";
import {IIndexFund} from "./IIndexFund.sol";

interface IBasketSwapRouterFactory {
    function usdg() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function basketHook() external view returns (address);
}

interface IBasketHookFactory {
    function poolManager() external view returns (IPoolManager);
    function basketRegistry() external view returns (address);
    function routeRegistry() external view returns (address);
    function usdg() external view returns (address);
    function weth() external view returns (address);
}

interface IBasketRouteRegistryFactory {
    function poolManager() external view returns (IPoolManager);
    function hubRoute() external view returns (PoolKey memory);
}

/// @title IndexFundFactory
/// @notice The implementation pointer is mutable only for future listings; every existing clone remains fixed.
contract IndexFundFactory {
    error OnlyPump();
    error OnlyTagAI();
    error InvalidConfiguration();
    error InvalidImplementation();
    error InvalidIndexToken();

    address public immutable pump;
    address public immutable tagAI;
    address public immutable usdg;
    address public immutable poolManager;
    address public immutable weth;
    IBasketRegistry public immutable basketRegistry;
    address public immutable basketRouter;
    address public immutable basketRouteRegistry;
    address public currentImplementation;

    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event IndexFundCreated(
        address indexed fund, address indexed token, address indexed indexToken, address implementation
    );

    constructor(
        address pump_,
        address tagAI_,
        address usdg_,
        address poolManager_,
        address weth_,
        address basketRegistry_,
        address basketRouter_,
        address basketRouteRegistry_,
        address implementation_
    ) {
        if (
            pump_.code.length == 0 || tagAI_ == address(0) || usdg_.code.length == 0 || poolManager_.code.length == 0
                || weth_.code.length == 0 || basketRegistry_.code.length == 0 || basketRouter_.code.length == 0
                || basketRouteRegistry_.code.length == 0 || implementation_.code.length == 0
        ) revert InvalidConfiguration();
        IBasketSwapRouterFactory router = IBasketSwapRouterFactory(basketRouter_);
        address basketHook = router.basketHook();
        if (
            address(router.poolManager()) != poolManager_ || router.usdg() != usdg_ || basketHook.code.length == 0
                || address(IBasketRouteRegistryFactory(basketRouteRegistry_).poolManager()) != poolManager_
        ) revert InvalidConfiguration();
        IBasketHookFactory hook = IBasketHookFactory(basketHook);
        if (
            address(hook.poolManager()) != poolManager_ || hook.basketRegistry() != basketRegistry_
                || hook.routeRegistry() != basketRouteRegistry_ || hook.usdg() != usdg_ || hook.weth() != weth_
        ) revert InvalidConfiguration();
        PoolKey memory hub = IBasketRouteRegistryFactory(basketRouteRegistry_).hubRoute();
        if (
            Currency.unwrap(hub.currency0) != address(0) || Currency.unwrap(hub.currency1) != usdg_
                || address(hub.hooks) != address(0)
        ) revert InvalidConfiguration();

        pump = pump_;
        tagAI = tagAI_;
        usdg = usdg_;
        poolManager = poolManager_;
        weth = weth_;
        basketRegistry = IBasketRegistry(basketRegistry_);
        basketRouter = basketRouter_;
        basketRouteRegistry = basketRouteRegistry_;
        currentImplementation = implementation_;
    }

    function setIndexFundImplementation(address implementation_) external {
        if (msg.sender != tagAI) revert OnlyTagAI();
        if (implementation_.code.length == 0) revert InvalidImplementation();
        address oldImplementation = currentImplementation;
        currentImplementation = implementation_;
        emit ImplementationUpdated(oldImplementation, implementation_);
    }

    function isRegisteredIndex(address indexToken) public view returns (bool) {
        return indexToken.code.length != 0 && basketRegistry.isBasket(indexToken);
    }

    function createFund(
        address token,
        address indexToken,
        address creator,
        address creatorFeeRecipient,
        address desk,
        address burnNet,
        address hook,
        PoolId poolId
    ) external returns (address fund) {
        if (msg.sender != pump) revert OnlyPump();
        if (!isRegisteredIndex(indexToken)) revert InvalidIndexToken();
        address implementation = currentImplementation;
        fund = Clones.clone(implementation);
        IIndexFund.InitParams memory params = IIndexFund.InitParams({
            usdg: usdg,
            indexToken: indexToken,
            creator: creator,
            creatorFeeRecipient: creatorFeeRecipient,
            desk: desk,
            burnNet: burnNet,
            hook: hook,
            poolId: poolId,
            basketRegistry: address(basketRegistry),
            basketRouter: basketRouter,
            basketRouteRegistry: basketRouteRegistry,
            poolManager: poolManager,
            weth: weth
        });
        IIndexFund(fund).initialize(params);
        emit IndexFundCreated(fund, token, indexToken, implementation);
    }
}
