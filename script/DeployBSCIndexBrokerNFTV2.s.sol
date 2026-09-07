// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {IndexBrokerNFTAMM} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTBurn, IndexBrokerNFTStake} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTFactory} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {StonkBrokerRenderer} from "../src/nutbox/dapps/index-broker-nft/StonkBrokerRenderer.sol";
import {BSCNutboxRouterConfig} from "./config/BSCNutboxRouterConfig.sol";

interface IIndexBrokerV2BasketRegistry {
    function isBasket(address candidate) external view returns (bool);
    function basketVersion(address basket) external view returns (uint32);
}

interface IIndexBrokerV2BasketSwapRouter {
    function basketHook() external view returns (address);
    function settlementToken() external view returns (address);
}

interface IIndexBrokerV2BasketHook {
    function basketRegistry() external view returns (address);
    function settlementToken() external view returns (address);
    function tokenVersion() external view returns (uint32);
}

interface IIndexBrokerV2BasketToken {
    function engine() external view returns (address);
    function registry() external view returns (address);
    function settlementToken() external view returns (address);
    function protocolVersion() external view returns (uint32);
    function wbnb() external view returns (address);
}

interface IIndexBrokerV2PancakeV3Router {
    function WETH9() external view returns (address);
    function factory() external view returns (address);
}

interface IIndexBrokerV2PancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/**
 * @title DeployBSCIndexBrokerNFTV2
 * @notice Deploys Index Broker V2 for Pump13, the V13 NutboxRouter and Basket V2/V3/V4.
 *
 * Dry run:
 *   forge script script/DeployBSCIndexBrokerNFTV2.s.sol:DeployBSCIndexBrokerNFTV2Script \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast, verify and record in deployments/56/version13.json:
 *   WRITE_DEPLOYMENTS=true forge script \
 *     script/DeployBSCIndexBrokerNFTV2.s.sol:DeployBSCIndexBrokerNFTV2Script \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * INDEX_BROKER_V2_OWNER must be set explicitly. When it differs from the deployer,
 * the deployment starts an Ownable2Step handover. The Committee multisig must also
 * whitelist the new Factory after deployment.
 */
contract DeployBSCIndexBrokerNFTV2Script is Script {
    string internal constant VERSION13_PATH = "deployments/56/version13.json";
    string internal constant LEGACY_PATH = "deployments/56/version11.json";

    address internal committee;
    address internal communityFactory;
    address internal clPoolManager;
    address internal wbnb;
    address internal usdt;
    address internal pancakeV2Factory;
    address internal pancakeV3Factory;
    address internal pancakeV3SmartRouter;
    address internal basketRegistry;
    address internal basketSwapRouterV2;
    address internal basketSwapRouterV3;
    address internal basketSwapRouterV4;
    address internal defaultIndexToken;
    address internal nutboxRouter;
    address internal renderer;
    address internal faceRenderer;
    address internal bodyRenderer;
    address internal accessoryRenderer;
    address internal pump13;
    uint24 internal bnbUsdtV3Fee;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        _loadDeployments();

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        require(vm.envExists("INDEX_BROKER_V2_OWNER"), "INDEX_BROKER_V2_OWNER must be explicit");
        address targetOwner = vm.envAddress("INDEX_BROKER_V2_OWNER");
        require(targetOwner != address(0), "Index Broker V2 owner missing");

        bool writeDeployments = vm.envOr("WRITE_DEPLOYMENTS", false);
        bool isBroadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        bool shouldWrite = writeDeployments && isBroadcast;

        _validateDependencies();

        console2.log("=== BSC Index Broker NFT V2 Deploy ===");
        console2.log("V13 deployment record", VERSION13_PATH);
        console2.log("Deployer", deployer);
        console2.log("Pump13", pump13);
        console2.log("NutboxRouter", nutboxRouter);
        console2.log("BasketSwapRouterV2", basketSwapRouterV2);
        console2.log("BasketSwapRouterV3", basketSwapRouterV3);
        console2.log("BasketSwapRouterV4", basketSwapRouterV4);
        console2.log("Default index token", defaultIndexToken);
        console2.log("Target Factory owner", targetOwner);

        vm.startBroadcast(privateKey);

        IndexBrokerNFTBurn burnTemplate = new IndexBrokerNFTBurn();
        IndexBrokerNFTStake stakeTemplate = new IndexBrokerNFTStake();
        IndexBrokerNFTAMM ammTemplate = new IndexBrokerNFTAMM();

        uint32[] memory basketVersions = new uint32[](3);
        basketVersions[0] = 2;
        basketVersions[1] = 3;
        basketVersions[2] = 4;
        address[] memory basketSwapRouters = new address[](3);
        basketSwapRouters[0] = basketSwapRouterV2;
        basketSwapRouters[1] = basketSwapRouterV3;
        basketSwapRouters[2] = basketSwapRouterV4;

        IndexBrokerNFTFactory factory = new IndexBrokerNFTFactory(
            communityFactory,
            pump13,
            renderer,
            address(ammTemplate),
            nutboxRouter,
            basketRegistry,
            basketVersions,
            basketSwapRouters,
            pancakeV3SmartRouter,
            bnbUsdtV3Fee,
            defaultIndexToken
        );
        factory.addNFTTemplate(address(burnTemplate));
        factory.addNFTTemplate(address(stakeTemplate));

        if (targetOwner != deployer) factory.transferOwnership(targetOwner);

        address committeeOwner = Ownable(committee).owner();
        bool committeeWhitelisted = ICommittee(committee).verifyContract(address(factory));
        if (!committeeWhitelisted && committeeOwner == deployer) {
            ICommittee(committee).adminAddContract(address(factory));
            committeeWhitelisted = true;
        }

        vm.stopBroadcast();

        _validateDeployment(factory, burnTemplate, stakeTemplate, ammTemplate, targetOwner);

        console2.log("IndexBrokerV2BurnTemplate", address(burnTemplate));
        console2.log("IndexBrokerV2StakeTemplate", address(stakeTemplate));
        console2.log("IndexBrokerV2AMMTemplate", address(ammTemplate));
        console2.log("IndexBrokerV2Factory", address(factory));
        if (!committeeWhitelisted) {
            console2.log("ACTION REQUIRED: Committee owner must whitelist Factory", committeeOwner);
        }
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept Factory ownership", targetOwner);
        }

        if (shouldWrite) {
            _writeDeployment(
                factory, burnTemplate, stakeTemplate, ammTemplate, deployer, targetOwner, committeeWhitelisted
            );
            console2.log("Index Broker V2 deployment recorded", VERSION13_PATH);
        } else if (writeDeployments) {
            console2.log("Dry run: WRITE_DEPLOYMENTS ignored outside broadcast/resume context");
        } else {
            console2.log("Dry run: deployment record not written");
        }
    }

    function _loadDeployments() internal {
        require(vm.exists(VERSION13_PATH), "version13.json missing");
        require(vm.exists(LEGACY_PATH), "version11.json missing");
        string memory v13 = vm.readFile(VERSION13_PATH);
        string memory legacy = vm.readFile(LEGACY_PATH);
        require(vm.parseJsonUint(v13, ".version") == 13, "Expected deployment version 13");
        require(vm.parseJsonUint(v13, ".chainId") == 56, "V13 chain mismatch");
        require(vm.parseJsonUint(legacy, ".version") == 11, "Expected deployment version 11");

        committee = vm.parseJsonAddress(v13, ".Committee");
        communityFactory = vm.parseJsonAddress(v13, ".CommunityFactory");
        clPoolManager = vm.parseJsonAddress(v13, ".CLPoolManager");
        usdt = vm.parseJsonAddress(v13, ".SettlementToken");
        pancakeV2Factory = vm.parseJsonAddress(v13, ".PancakeV2Factory");
        basketRegistry = vm.parseJsonAddress(v13, ".BasketRegistry");
        basketSwapRouterV4 = vm.parseJsonAddress(v13, ".BasketSwapRouterV4");
        nutboxRouter = vm.parseJsonAddress(v13, ".NutboxRouter");
        pump13 = vm.parseJsonAddress(v13, ".Pump");

        wbnb = vm.parseJsonAddress(legacy, ".WBNB");
        pancakeV3Factory = vm.parseJsonAddress(legacy, ".PancakeV3Factory");
        pancakeV3SmartRouter = vm.parseJsonAddress(legacy, ".PancakeV3SmartRouter");
        basketSwapRouterV2 = vm.parseJsonAddress(legacy, ".BasketSwapRouterV2");
        basketSwapRouterV3 = vm.parseJsonAddress(legacy, ".BasketSwapRouterV3");
        defaultIndexToken = vm.parseJsonAddress(legacy, ".DefaultIndexToken");
        renderer = vm.parseJsonAddress(legacy, ".StonkBrokerRenderer");
        faceRenderer = vm.parseJsonAddress(legacy, ".StonkBrokerFaceRenderer");
        bodyRenderer = vm.parseJsonAddress(legacy, ".StonkBrokerBodyRenderer");
        accessoryRenderer = vm.parseJsonAddress(legacy, ".StonkBrokerAccessoryRenderer");
        uint256 configuredFee = vm.parseJsonUint(legacy, ".BnbUsdtV3Fee");
        require(configuredFee <= type(uint24).max, "Invalid BNB/USDT V3 fee");
        bnbUsdtV3Fee = uint24(configuredFee);

        require(committee == vm.parseJsonAddress(legacy, ".Committee"), "Committee changed");
        require(communityFactory == vm.parseJsonAddress(legacy, ".CommunityFactory"), "CommunityFactory changed");
        require(clPoolManager == vm.parseJsonAddress(legacy, ".CLPoolManager"), "CLPoolManager changed");
        require(usdt == vm.parseJsonAddress(legacy, ".USDT"), "Settlement token changed");
        require(pancakeV2Factory == vm.parseJsonAddress(legacy, ".PancakeV2Factory"), "V2 Factory changed");
        require(basketRegistry == vm.parseJsonAddress(legacy, ".BasketRegistry"), "Basket Registry changed");
    }

    function _validateDependencies() internal view {
        require(pump13.code.length > 0, "Pump13 missing");
        require(committee.code.length > 0, "Committee missing");
        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(clPoolManager.code.length > 0, "CLPoolManager missing");
        require(pancakeV2Factory.code.length > 0, "Pancake V2 factory missing");
        require(BSCNutboxRouterConfig.pancakeV2Router().code.length > 0, "Pancake V2 router missing");
        require(pancakeV3Factory.code.length > 0, "Pancake V3 factory missing");
        require(pancakeV3SmartRouter.code.length > 0, "Pancake V3 router missing");

        StonkBrokerRenderer deployedRenderer = StonkBrokerRenderer(renderer);
        require(renderer.code.length > 0, "StonkBrokerRenderer missing");
        require(address(deployedRenderer.faceRenderer()) == faceRenderer, "Face Renderer mismatch");
        require(address(deployedRenderer.bodyRenderer()) == bodyRenderer, "Body Renderer mismatch");
        require(address(deployedRenderer.accessoryRenderer()) == accessoryRenderer, "Accessory Renderer mismatch");
        require(faceRenderer.code.length > 0, "Face Renderer missing");
        require(bodyRenderer.code.length > 0, "Body Renderer missing");
        require(accessoryRenderer.code.length > 0, "Accessory Renderer missing");

        require(basketRegistry.code.length > 0, "BasketRegistry missing");
        require(IIndexBrokerV2BasketRegistry(basketRegistry).isBasket(defaultIndexToken), "Invalid default index token");
        require(
            IIndexBrokerV2BasketRegistry(basketRegistry).basketVersion(defaultIndexToken) == 2,
            "Unexpected default index version"
        );
        address basketHookV2 = _validateBasketRouter(basketSwapRouterV2, 2);
        _validateBasketRouter(basketSwapRouterV3, 3);
        _validateBasketRouter(basketSwapRouterV4, 4);

        IIndexBrokerV2BasketToken defaultBasket = IIndexBrokerV2BasketToken(defaultIndexToken);
        require(defaultBasket.protocolVersion() == 2, "Default index protocol version mismatch");
        require(defaultBasket.registry() == basketRegistry, "Default index Registry mismatch");
        require(defaultBasket.engine() == basketHookV2, "Default index Hook mismatch");
        require(defaultBasket.settlementToken() == usdt, "Default index settlement mismatch");
        require(defaultBasket.wbnb() == wbnb, "Default index WBNB mismatch");

        require(IIndexBrokerV2PancakeV3Router(pancakeV3SmartRouter).WETH9() == wbnb, "Unexpected wrapped native");
        require(
            IIndexBrokerV2PancakeV3Router(pancakeV3SmartRouter).factory() == pancakeV3Factory, "Unexpected V3 factory"
        );
        address bnbUsdtPool = IIndexBrokerV2PancakeV3Factory(pancakeV3Factory).getPool(wbnb, usdt, bnbUsdtV3Fee);
        require(bnbUsdtPool.code.length > 0, "BNB/USDT V3 pool missing");

        NutboxRouter router = NutboxRouter(payable(nutboxRouter));
        require(nutboxRouter.code.length > 0, "NutboxRouter missing");
        require(router.wrappedNative() == wbnb, "Router WBNB mismatch");
        require(router.allowedPancakeV4CLManager(clPoolManager), "Router V4 manager missing");
        require(router.allowedV2Factory(pancakeV2Factory), "Router V2 factory missing");
        require(
            router.v2RouterForFactory(pancakeV2Factory) == BSCNutboxRouterConfig.pancakeV2Router(),
            "Router V2 executor mismatch"
        );
        require(router.allowedV3Factory(pancakeV3Factory), "Router V3 factory missing");
        require(router.pancakeV3Router() == pancakeV3SmartRouter, "Router V3 executor mismatch");
        require(router.pancakeV3Factory() == pancakeV3Factory, "Router V3 executor factory mismatch");
        require(router.hasRoute(usdt, wbnb), "Router BNB/USDT route missing");
        require(router.routePoolCount(usdt, wbnb) == 1, "Router BNB/USDT route invalid");

        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            BSCNutboxRouterConfig.AssetConfig memory asset = assets[i];
            require(router.hasRoute(asset.token, wbnb), "Router asset/BNB route missing");
            require(router.hasRoute(asset.token, usdt), "Router asset/USDT route missing");
        }
    }

    function _validateBasketRouter(address routerAddress, uint32 version) internal view returns (address hookAddress) {
        require(routerAddress.code.length > 0, "BasketSwapRouter missing");
        IIndexBrokerV2BasketSwapRouter basketRouter = IIndexBrokerV2BasketSwapRouter(routerAddress);
        require(basketRouter.settlementToken() == usdt, "Unexpected Basket settlement token");
        hookAddress = basketRouter.basketHook();
        require(hookAddress.code.length > 0, "Basket Hook missing");
        IIndexBrokerV2BasketHook basketHook = IIndexBrokerV2BasketHook(hookAddress);
        require(basketHook.tokenVersion() == version, "Basket Hook version mismatch");
        require(basketHook.basketRegistry() == basketRegistry, "Basket Hook Registry mismatch");
        require(basketHook.settlementToken() == usdt, "Basket Hook settlement mismatch");
    }

    function _validateDeployment(
        IndexBrokerNFTFactory factory,
        IndexBrokerNFTBurn burnTemplate,
        IndexBrokerNFTStake stakeTemplate,
        IndexBrokerNFTAMM ammTemplate,
        address targetOwner
    ) internal view {
        require(address(factory).code.length > 0, "Factory deployment failed");
        require(address(ammTemplate).code.length > 0, "AMM template deployment failed");
        require(factory.supportedNFTTemplate(address(burnTemplate)), "Burn template registration failed");
        require(factory.supportedNFTTemplate(address(stakeTemplate)), "Stake template registration failed");
        require(factory.nftTemplateCount() == 2, "Unexpected NFT template count");
        require(factory.pump() == pump13, "Factory Pump mismatch");
        require(factory.supportedPump(pump13), "Factory Pump13 unsupported");
        require(factory.defaultRenderer() == renderer, "Factory Renderer mismatch");
        require(factory.ammTemplate() == address(ammTemplate), "Factory AMM mismatch");
        require(factory.nutboxRouter() == nutboxRouter, "Factory Router mismatch");
        require(factory.basketSwapRouterForVersion(2) == basketSwapRouterV2, "Factory Basket V2 mismatch");
        require(factory.basketSwapRouterForVersion(3) == basketSwapRouterV3, "Factory Basket V3 mismatch");
        require(factory.basketSwapRouterForVersion(4) == basketSwapRouterV4, "Factory Basket V4 mismatch");
        require(factory.basketSwapRouter() == basketSwapRouterV2, "Factory default Basket Router mismatch");
        require(factory.defaultIndexToken() == defaultIndexToken, "Factory index mismatch");
        if (targetOwner != factory.owner()) require(factory.pendingOwner() == targetOwner, "Owner handover missing");
    }

    function _writeDeployment(
        IndexBrokerNFTFactory factory,
        IndexBrokerNFTBurn burnTemplate,
        IndexBrokerNFTStake stakeTemplate,
        IndexBrokerNFTAMM ammTemplate,
        address deployer,
        address targetOwner,
        bool committeeWhitelisted
    ) internal {
        string memory json = vm.readFile(VERSION13_PATH);
        require(vm.parseJsonUint(json, ".version") == 13, "V13 changed before write");
        require(vm.parseJsonAddress(json, ".Pump") == pump13, "Pump13 changed before write");
        require(vm.parseJsonAddress(json, ".NutboxRouter") == nutboxRouter, "NutboxRouter changed before write");
        require(
            vm.parseJsonAddress(json, ".BasketSwapRouterV4") == basketSwapRouterV4,
            "BasketSwapRouterV4 changed before write"
        );

        _writeAddress(".IndexBrokerV2Deployer", deployer);
        _writeAddress(".IndexBrokerV2TargetOwner", targetOwner);
        _writeBool(".IndexBrokerV2OwnershipAccepted", targetOwner == deployer);
        _writeBool(".IndexBrokerV2FactoryWhitelisted", committeeWhitelisted);
        _writeAddress(".IndexBrokerV2Factory", address(factory));
        _writeAddress(".IndexBrokerV2BurnTemplate", address(burnTemplate));
        _writeAddress(".IndexBrokerV2StakeTemplate", address(stakeTemplate));
        _writeAddress(".IndexBrokerV2AMMTemplate", address(ammTemplate));
        _writeAddress(".IndexBrokerV2Renderer", renderer);
        _writeAddress(".IndexBrokerV2NutboxRouter", nutboxRouter);
        _writeAddress(".IndexBrokerV2Pump", pump13);
        _writeAddress(".IndexBrokerV2BasketSwapRouterV2", basketSwapRouterV2);
        _writeAddress(".IndexBrokerV2BasketSwapRouterV3", basketSwapRouterV3);
        _writeAddress(".IndexBrokerV2BasketSwapRouterV4", basketSwapRouterV4);
    }

    function _writeAddress(string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), VERSION13_PATH, key);
    }

    function _writeBool(string memory key, bool value) internal {
        vm.writeJson(value ? "true" : "false", VERSION13_PATH, key);
    }
}
