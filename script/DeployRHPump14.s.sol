// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {RHPumpV14 as Pump} from "../src/v14/RHPumpV14.sol";
import {RHTokenV14 as Token} from "../src/v14/RHTokenV14.sol";
import {RHSwapHookV14 as SwapHook} from "../src/v14/RHSwapHookV14.sol";
import {TradeCurationFactory} from "../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {TagAITradeRouter} from "../src/router/TagAITradeRouter.sol";
import {TagAILiquidityRouter} from "../src/router/TagAILiquidityRouter.sol";
import {TagAIBuybackRouter} from "../src/router/TagAIBuybackRouter.sol";
import {RHNutboxRouterConfig} from "./config/RHNutboxRouterConfig.sol";
import {RHVersion14StockConfig} from "./config/RHVersion14StockConfig.sol";
import {INutboxRouter} from "../src/router/INutboxRouter.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IRH14Owner {
    function owner() external view returns (address);
}

interface IRH14Signer {
    function claimSigner() external view returns (address);
}

interface IRH14BasketRegistry {
    function setRegistrarApproval(address, bool) external;
    function setCreatorForwarderApproval(address, bool) external;
}

interface IRH14Committee {
    function adminAddContract(address) external;
}

/// @notice New RH V14 launch stack. Existing V11 and Basket V3 contracts remain untouched.
/// @dev Rebuild ../robinhood-basket-contract artifacts before use. Basket business logic is unchanged.
/// run() never edits version11.json or writes a predicted address as a confirmed deployment.
contract DeployRHPump14Script is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Config {
        address owner;
        address signer;
        address feeReceiver;
        address ipshare;
        address communityFactory;
        address calculator;
        address stakingFactory;
        address committee;
        address registry;
        address routes;
        address auction;
        address basketDeployer;
        address launcher;
    }

    // ABI layout must match the unchanged RH BasketHook.FactoryConfig.
    struct BasketFactoryConfig {
        address launcher;
        address feeAuction;
        address tokenDeployer;
        address v3Factory;
        address v3Router;
        address executor;
    }

    struct Stack {
        Pump pump;
        SwapHook hook;
        NutboxRouter router;
        TradeCurationFactory tradeFactory;
        TagAITradeRouter tradeRouter;
        TagAILiquidityRouter liquidityRouter;
        TagAIBuybackRouter buybackRouter;
        address basketExecutor;
        address basketHook;
        address basketRouter;
    }

    function loadConfig() public view returns (Config memory c) {
        string memory j = vm.readFile("deployments/4663/version11.json");
        string memory b = vm.readFile("../robinhood-basket-contract/deployments/4663/version3.json");
        c.committee = vm.parseJsonAddress(j, ".Committee");
        c.communityFactory = vm.parseJsonAddress(j, ".CommunityFactory");
        c.calculator = vm.parseJsonAddress(j, ".HourlyTickCalculator");
        c.stakingFactory = vm.parseJsonAddress(j, ".ERC20StakingFactory");
        c.ipshare = vm.parseJsonAddress(j, ".IPShare");
        c.feeReceiver = vm.parseJsonAddress(j, ".feeAddress");
        c.owner = IRH14Owner(vm.parseJsonAddress(j, ".Pump")).owner();
        c.signer = IRH14Signer(vm.parseJsonAddress(j, ".SocialCurationFactory")).claimSigner();
        c.registry = vm.parseJsonAddress(b, ".BasketRegistry");
        c.routes = vm.parseJsonAddress(b, ".BasketRouteRegistry");
        c.auction = vm.parseJsonAddress(b, ".BasketFeeAuction");
        c.basketDeployer = vm.parseJsonAddress(b, ".BasketTokenDeployerV3");
        c.launcher = vm.parseJsonAddress(b, ".launcher");
    }

    function run() external virtual returns (Stack memory s) {
        require(block.chainid == 4663, "RH_MAINNET_ONLY");
        require(block.timestamp <= RHVersion14StockConfig.SNAPSHOT_TIMESTAMP + 1 days, "REFRESH_STOCK_SNAPSHOT");
        Config memory c = loadConfig();
        address deployer = vm.envAddress("RH14_DEPLOYER");
        vm.startBroadcast(deployer);
        s = deployStack(c, CREATE2_DEPLOYER);
        _handover(c, s);
        vm.stopBroadcast();
        _report(c, s);
    }

    function _handover(Config memory c, Stack memory s) internal {
        s.pump.transferOwnership(c.owner);
        s.router.transferOwnership(c.owner);
        s.tradeFactory.transferOwnership(c.owner);
        s.tradeRouter.transferOwnership(c.owner);
    }

    function _report(Config memory c, Stack memory s) internal view {
        console2.log("Pump", address(s.pump));
        console2.log("ListingKeeper", s.pump.listingKeeper());
        console2.log("ApprovedConstituents", RHVersion14StockConfig.constituentAssets().length);
        console2.log("TokenImplementation", s.pump.tokenImplementation());
        console2.log("Hook", address(s.hook));
        console2.log("NutboxRouter", address(s.router));
        console2.log("NutboxPriceReader", address(s.router.priceReader()));
        console2.log("TradeRouter", address(s.tradeRouter));
        console2.log("LiquidityRouter", address(s.liquidityRouter));
        console2.log("BuybackRouter", address(s.buybackRouter));
        console2.log("TradeCurationFactory", address(s.tradeFactory));
        console2.log("BasketExecutor", s.basketExecutor);
        console2.log("BasketHook", s.basketHook);
        console2.log("BasketSwapRouter", s.basketRouter);
        console2.log(
            "Pending governance: Committee whitelist, Basket registrar/forwarders and four acceptOwnership calls."
        );
        _printCall(c.committee, abi.encodeCall(IRH14Committee.adminAddContract, (address(s.tradeFactory))));
        _printCall(c.registry, abi.encodeCall(IRH14BasketRegistry.setRegistrarApproval, (s.basketHook, true)));
        _printCall(c.registry, abi.encodeCall(IRH14BasketRegistry.setCreatorForwarderApproval, (address(s.pump), true)));
        _printCall(c.registry, abi.encodeCall(IRH14BasketRegistry.setCreatorForwarderApproval, (s.basketRouter, true)));
        _printCall(address(s.pump), abi.encodeWithSignature("acceptOwnership()"));
        _printCall(address(s.router), abi.encodeWithSignature("acceptOwnership()"));
        _printCall(address(s.tradeRouter), abi.encodeWithSignature("acceptOwnership()"));
        _printCall(address(s.tradeFactory), abi.encodeWithSignature("acceptOwnership()"));
    }

    function _printCall(address target, bytes memory data) private pure {
        console2.log("Governance target", target);
        console2.logBytes(data);
    }

    function deployStack(Config memory c, address saltDeployer) public returns (Stack memory s) {
        require(block.chainid == 4663, "RH_MAINNET_ONLY");
        require(c.owner != address(0) && c.signer != address(0), "ROLES_REQUIRED");
        require(
            c.ipshare.code.length > 0 && c.communityFactory.code.length > 0 && c.calculator.code.length > 0
                && c.stakingFactory.code.length > 0 && c.committee.code.length > 0 && c.registry.code.length > 0
                && c.routes.code.length > 0 && c.auction.code.length > 0 && c.basketDeployer.code.length > 0,
            "MISSING_INFRASTRUCTURE"
        );
        address[] memory v2 = new address[](1);
        v2[0] = RHNutboxRouterConfig.v2Factory();
        address[] memory v2r = new address[](1);
        v2r[0] = RHNutboxRouterConfig.v2Router();
        address[] memory v3 = new address[](1);
        v3[0] = RHNutboxRouterConfig.v3Factory();
        address[] memory pm = new address[](1);
        pm[0] = RHNutboxRouterConfig.poolManager();
        s.router = new NutboxRouter(
            RHNutboxRouterConfig.wrappedNative(),
            RHNutboxRouterConfig.v3Router(),
            v2r,
            v2,
            v3,
            pm,
            new address[](0),
            bytes("")
        );
        _initializeStockRouter(s.router);
        return _deployRemaining(c, saltDeployer, s.router);
    }

    /// @dev Keep each administrative transaction below a modest gas budget, without constructor payload bloat.
    function _initializeStockRouter(NutboxRouter router) internal {
        uint256 batchSize = 16;
        INutboxRouter.InitialPricePool[] memory pools = RHVersion14StockConfig.initialPricePools();
        for (uint256 start; start < pools.length; start += batchSize) {
            uint256 count = pools.length - start;
            if (count > batchSize) count = batchSize;
            INutboxRouter.InitialPricePool[] memory batch = new INutboxRouter.InitialPricePool[](count);
            for (uint256 i; i < count; ++i) {
                batch[i] = pools[start + i];
            }
            router.addPricePools(batch);
        }
        INutboxRouter.InitialRoute[] memory routes = RHVersion14StockConfig.initialRoutes();
        for (uint256 start; start < routes.length; start += batchSize) {
            uint256 count = routes.length - start;
            if (count > batchSize) count = batchSize;
            INutboxRouter.InitialRoute[] memory batch = new INutboxRouter.InitialRoute[](count);
            for (uint256 i; i < count; ++i) {
                batch[i] = routes[start + i];
            }
            router.addRoutes(batch);
        }
    }

    function _deployRemaining(Config memory c, address saltDeployer, NutboxRouter router)
        internal
        returns (Stack memory s)
    {
        s.router = router;
        _deployBasket(c, saltDeployer, s);
        _deployPump(c, saltDeployer, s);
        _deployBusinessRouters(c, s);
    }

    function _deployBasket(Config memory c, address saltDeployer, Stack memory s) internal {
        // Rebind the unchanged Basket V3 implementation to the new extensible Router.
        s.basketExecutor = _deployArtifact(
            "BasketRebalanceExecutor.sol/BasketRebalanceExecutor.json",
            abi.encode(
                RHNutboxRouterConfig.poolManager(),
                c.registry,
                c.routes,
                RHNutboxRouterConfig.usdg(),
                address(0),
                RHNutboxRouterConfig.wrappedNative(),
                RHNutboxRouterConfig.v3Factory(),
                RHNutboxRouterConfig.v2Factory(),
                RHNutboxRouterConfig.v3Router(),
                address(s.router)
            )
        );
        BasketFactoryConfig memory bc = BasketFactoryConfig(
            c.launcher,
            c.auction,
            c.basketDeployer,
            RHNutboxRouterConfig.v3Factory(),
            RHNutboxRouterConfig.v3Router(),
            s.basketExecutor
        );
        bytes memory basketArgs = abi.encode(
            RHNutboxRouterConfig.poolManager(),
            c.registry,
            c.routes,
            RHNutboxRouterConfig.usdg(),
            RHNutboxRouterConfig.wrappedNative(),
            bc
        );
        bytes memory basketCode = vm.getCode("../robinhood-basket-contract/out/BasketHook.sol/BasketHook.json");
        (address expected, bytes32 salt) = HookMiner.find(saltDeployer, 0x2a88, basketCode, basketArgs);
        bytes memory init = abi.encodePacked(basketCode, basketArgs);
        address bh;
        assembly ("memory-safe") { bh := create2(0, add(init, 32), mload(init), salt) }
        require(bh == expected && bh.code.length > 0, "BASKET_HOOK_DEPLOY_FAILED");
        s.basketHook = bh;
        s.basketRouter = _deployArtifact(
            "BasketSwapRouter.sol/BasketSwapRouter.json",
            abi.encode(RHNutboxRouterConfig.poolManager(), bh, RHNutboxRouterConfig.usdg())
        );
    }

    function _deployPump(Config memory c, address saltDeployer, Stack memory s) internal {
        address[] memory constituents = RHVersion14StockConfig.constituentAssets();
        require(
            type(Pump).creationCode.length + abi.encode(c.ipshare, c.feeReceiver, constituents, address(0)).length
                <= 49152,
            "PUMP_INITCODE_TOO_LARGE"
        );
        s.pump = new Pump(c.ipshare, c.feeReceiver, constituents, address(0));
        for (uint256 i; i < constituents.length; ++i) {
            // Fail the deployment simulation if a configured stock has no usable quote route.
            s.router.validateRoute(address(0), constituents[i]);
            s.router.validateRoute(RHNutboxRouterConfig.usdg(), constituents[i]);
        }
        s.pump.adminSetPoolManager(RHNutboxRouterConfig.poolManager());
        s.pump.adminSetNutbox(c.communityFactory, c.calculator, c.stakingFactory, c.committee);
        s.pump
            .adminSetIndexInfrastructure(
                address(s.router), s.basketHook, RHNutboxRouterConfig.v2Factory(), RHNutboxRouterConfig.usdg()
            );
        (address expected, bytes32 salt) = HookMiner.find(
            saltDeployer,
            0x20cc,
            type(SwapHook).creationCode,
            abi.encode(IPoolManager(RHNutboxRouterConfig.poolManager()), address(s.pump))
        );
        s.hook = new SwapHook{salt: salt}(IPoolManager(RHNutboxRouterConfig.poolManager()), address(s.pump));
        require(address(s.hook) == expected, "PUMP_HOOK_DEPLOY_FAILED");
        s.pump.adminSetHookAddress(address(s.hook));
    }

    function _deployBusinessRouters(Config memory c, Stack memory s) internal {
        s.buybackRouter =
            new TagAIBuybackRouter(address(s.pump), address(s.router), s.basketRouter, RHNutboxRouterConfig.usdg());
        s.pump.adminSetBuybackRouter(address(s.buybackRouter));
        s.tradeFactory = new TradeCurationFactory(c.communityFactory, c.signer);
        s.pump.adminSetOptionalPoolFactory(address(s.tradeFactory), "Trade Curation", 8000, true);
        s.router.addOperator(address(s.pump));
        s.tradeRouter = new TagAITradeRouter(address(s.pump), address(s.router), RHNutboxRouterConfig.v2Factory());
        s.liquidityRouter = new TagAILiquidityRouter(s.tradeRouter);
    }

    function _deployArtifact(string memory name, bytes memory args) internal returns (address deployed) {
        bytes memory init = abi.encodePacked(vm.getCode(string.concat("../robinhood-basket-contract/out/", name)), args);
        assembly ("memory-safe") { deployed := create(0, add(init, 32), mload(init)) }
        require(deployed.code.length > 0, "BASKET_ARTIFACT_DEPLOY_FAILED");
    }
}
