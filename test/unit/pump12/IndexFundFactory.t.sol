// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IndexFundFactory} from "../../../src/pump12/fund/IndexFundFactory.sol";
import {IndexFundV1} from "../../../src/pump12/fund/IndexFundV1.sol";
import {IIndexFund} from "../../../src/pump12/fund/IIndexFund.sol";
import {
    Pump12TestBasketRegistry,
    Pump12TestWETH,
    Pump12TestBasket,
    Pump12TestBasketHookConfig,
    Pump12TestBasketRouter,
    Pump12TestRouteRegistry
} from "./Pump12IndexTestHelpers.sol";

contract IndexFundV2TestImplementation is IIndexFund {
    bool public initialized;
    address public indexToken;

    constructor() {
        initialized = true;
    }

    function initialize(InitParams calldata params) external {
        require(!initialized);
        initialized = true;
        indexToken = params.indexToken;
    }

    function onDeskProceeds(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract IndexFundFactoryTest is Test {
    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));

    IPoolManager internal manager;
    Pump12TestWETH internal usdg;
    Pump12TestWETH internal weth;
    Pump12TestBasket internal basket;
    Pump12TestBasketRegistry internal registry;
    IndexFundFactory internal factory;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        usdg = new Pump12TestWETH();
        weth = new Pump12TestWETH();
        basket = new Pump12TestBasket(address(weth));
        registry = new Pump12TestBasketRegistry();
        registry.setBasket(address(basket), true);
        Pump12TestRouteRegistry routes = new Pump12TestRouteRegistry(manager, address(usdg));
        Pump12TestBasketHookConfig basketHookConfig =
            new Pump12TestBasketHookConfig(manager, address(registry), address(routes), address(usdg), address(weth));
        Pump12TestBasketRouter router = new Pump12TestBasketRouter(manager, address(usdg), address(basketHookConfig));
        factory = new IndexFundFactory(
            address(this),
            tagAI,
            address(usdg),
            address(manager),
            address(weth),
            address(registry),
            address(router),
            address(routes),
            address(new IndexFundV1())
        );
    }

    function test_factoryRejectsUnregisteredIndexAndNonPumpCaller() public {
        Pump12TestBasket unknown = new Pump12TestBasket(address(weth));
        vm.expectRevert(IndexFundFactory.InvalidIndexToken.selector);
        _create(address(unknown));

        vm.expectRevert(IndexFundFactory.OnlyPump.selector);
        vm.prank(makeAddr("attacker"));
        factory.createFund(
            address(this),
            address(basket),
            creator,
            creatorFeeRecipient,
            address(this),
            address(this),
            address(this),
            POOL_ID
        );
    }

    function test_upgradeChangesOnlyFutureClones() public {
        address first = _create(address(basket));
        bytes32 firstCodeHash = first.codehash;
        assertEq(address(IndexFundV1(payable(first)).indexToken()), address(basket));

        IndexFundV2TestImplementation v2 = new IndexFundV2TestImplementation();
        vm.prank(tagAI);
        factory.setIndexFundImplementation(address(v2));
        address second = _create(address(basket));

        assertEq(IndexFundV2TestImplementation(second).version(), 2);
        assertEq(IndexFundV2TestImplementation(second).indexToken(), address(basket));
        assertEq(first.codehash, firstCodeHash);
        assertNotEq(first.codehash, second.codehash);
    }

    function test_onlyTagAICanChangeImplementation() public {
        IndexFundV2TestImplementation v2 = new IndexFundV2TestImplementation();
        vm.expectRevert(IndexFundFactory.OnlyTagAI.selector);
        factory.setIndexFundImplementation(address(v2));
    }

    function test_factoryRejectsRouterWhoseHookBelongsToAnotherRegistry() public {
        Pump12TestBasketRegistry otherRegistry = new Pump12TestBasketRegistry();
        Pump12TestRouteRegistry routes = new Pump12TestRouteRegistry(manager, address(usdg));
        Pump12TestBasketHookConfig wrongHook = new Pump12TestBasketHookConfig(
            manager, address(otherRegistry), address(routes), address(usdg), address(weth)
        );
        Pump12TestBasketRouter wrongRouter = new Pump12TestBasketRouter(manager, address(usdg), address(wrongHook));
        IndexFundV1 implementation = new IndexFundV1();

        vm.expectRevert(IndexFundFactory.InvalidConfiguration.selector);
        new IndexFundFactory(
            address(this),
            tagAI,
            address(usdg),
            address(manager),
            address(weth),
            address(registry),
            address(wrongRouter),
            address(routes),
            address(implementation)
        );
    }

    function _create(address selectedIndex) private returns (address) {
        return factory.createFund(
            address(this),
            selectedIndex,
            creator,
            creatorFeeRecipient,
            address(this),
            address(this),
            address(this),
            POOL_ID
        );
    }
}
