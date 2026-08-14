// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {IndexBrokerNFTAMM} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTFactory} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {IndexBrokerNFTPriceOracle} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTPriceOracle.sol";
import {StonkBrokerRenderer} from "../src/nutbox/dapps/index-broker-nft/StonkBrokerRenderer.sol";

interface IDeployBasketRegistry {
    function isBasket(address candidate) external view returns (bool);
}

interface IDeployBasketSwapRouter {
    function settlementToken() external view returns (address);
}

interface IDeployPancakeV3Router {
    function WETH9() external view returns (address);
    function factory() external view returns (address);
}

interface IDeployPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/**
 * @title DeployBSCIndexBrokerNFT
 * @notice Deploys the complete Index Broker NFT stack against the live BSC Basket protocol.
 *
 * Deployment order:
 *   1. StonkBrokerRenderer (and its three art modules)
 *   2. IndexBrokerNFTAMM implementation template
 *   3. Shared IndexBrokerNFTPriceOracle
 *   4. IndexBrokerNFTFactory (deploys its IndexBrokerNFT template internally)
 *
 * Dry run:
 *   forge script script/DeployBSCIndexBrokerNFT.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast and append the new addresses to deployments/56/version11.json only after success:
 *   WRITE_DEPLOYMENTS=true forge script script/DeployBSCIndexBrokerNFT.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * The V11 Pump deployment must be recorded first. Set INDEX_BROKER_OWNER to
 * initiate Ownable2Step handover. A successful write advances the V11 status
 * from `pump-deployed` to `contracts-deployed`; post-deploy ownership and
 * Committee actions are recorded separately before the release becomes complete.
 */
contract DeployBSCIndexBrokerNFTScript is Script {
    string internal constant VERSION11_PATH = "deployments/56/version11.json";

    address internal committee;
    address internal communityFactory;
    address internal clPoolManager;
    address internal wbnb;
    address internal usdt;
    address internal pancakeV2Factory;
    address internal pancakeV3Factory;
    address internal pancakeV3SmartRouter;
    address internal basketRegistry;
    address internal basketSwapRouter;
    address internal defaultIndexToken;
    uint24 internal bnbUsdtV3Fee;
    address internal recordedPump;
    string internal version11Status;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        _loadVersion11();

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        bool pumpOverridden = vm.envExists("BSC_PUMP");
        address pump = vm.envOr("BSC_PUMP", recordedPump);
        address targetOwner = vm.envOr("INDEX_BROKER_OWNER", deployer);
        bool writeDeployments = vm.envOr("WRITE_DEPLOYMENTS", false);
        bool isBroadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        bool shouldWrite = writeDeployments && isBroadcast;
        if (_sameString(version11Status, "preparing")) {
            require(pumpOverridden, "Record the V11 Pump first or set BSC_PUMP for dry run");
        }
        if (shouldWrite) {
            require(_sameString(version11Status, "pump-deployed"), "V11 Pump must be recorded first");
            require(pump == recordedPump, "Write requires the Pump recorded in V11");
        }

        _validateDependencies(pump);

        console2.log("=== BSC Index Broker NFT Deploy ===");
        console2.log("V11 deployment record", VERSION11_PATH);
        console2.log("Deployer", deployer);
        console2.log("Pump", pump);
        console2.log("Default index token", defaultIndexToken);
        console2.log("Target Factory owner", targetOwner);

        vm.startBroadcast(privateKey);

        StonkBrokerRenderer renderer = new StonkBrokerRenderer();
        IndexBrokerNFTAMM ammTemplate = new IndexBrokerNFTAMM();

        address[] memory v2Factories = new address[](1);
        v2Factories[0] = pancakeV2Factory;
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = pancakeV3Factory;
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = clPoolManager;
        IndexBrokerNFTPriceOracle oracle =
            new IndexBrokerNFTPriceOracle(wbnb, v2Factories, v3Factories, new address[](0), pancakeV4Managers);

        IndexBrokerNFTFactory factory = new IndexBrokerNFTFactory(
            communityFactory,
            pump,
            address(renderer),
            address(ammTemplate),
            address(oracle),
            basketRegistry,
            basketSwapRouter,
            pancakeV3SmartRouter,
            bnbUsdtV3Fee,
            defaultIndexToken
        );

        if (targetOwner != deployer) factory.transferOwnership(targetOwner);

        address committeeOwner = Ownable(committee).owner();
        bool committeeWhitelisted = ICommittee(committee).verifyContract(address(factory));
        if (!committeeWhitelisted && committeeOwner == deployer) {
            ICommittee(committee).adminAddContract(address(factory));
            committeeWhitelisted = true;
        }

        vm.stopBroadcast();

        _validateDeployment(factory, renderer, ammTemplate, oracle, pump, targetOwner);

        console2.log("StonkBrokerRenderer", address(renderer));
        console2.log("StonkBrokerFaceRenderer", address(renderer.faceRenderer()));
        console2.log("StonkBrokerBodyRenderer", address(renderer.bodyRenderer()));
        console2.log("StonkBrokerAccessoryRenderer", address(renderer.accessoryRenderer()));
        console2.log("IndexBrokerNFTAMMTemplate", address(ammTemplate));
        console2.log("IndexBrokerNFTPriceOracle", address(oracle));
        console2.log("IndexBrokerNFTFactory", address(factory));
        console2.log("IndexBrokerNFTPoolTemplate", factory.poolTemplate());

        if (!committeeWhitelisted) {
            console2.log("ACTION REQUIRED: Committee owner must whitelist Factory", committeeOwner);
        }
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept Factory ownership", targetOwner);
        }

        if (shouldWrite) {
            _writeDeployment(factory, renderer, ammTemplate, oracle, pump, deployer, targetOwner, committeeWhitelisted);
            console2.log("V11 Index Broker deployment recorded", VERSION11_PATH);
        } else if (writeDeployments) {
            console2.log("Dry run: WRITE_DEPLOYMENTS ignored outside broadcast/resume context");
        } else {
            console2.log("Dry run: deployment record not written");
        }
    }

    function _loadVersion11() internal {
        require(vm.exists(VERSION11_PATH), "deployments/56/version11.json missing");
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");

        version11Status = vm.parseJsonString(json, ".status");
        require(
            _sameString(version11Status, "preparing") || _sameString(version11Status, "pump-deployed"),
            "V11 Index Broker already recorded"
        );
        committee = vm.parseJsonAddress(json, ".Committee");
        communityFactory = vm.parseJsonAddress(json, ".CommunityFactory");
        clPoolManager = vm.parseJsonAddress(json, ".CLPoolManager");
        wbnb = vm.parseJsonAddress(json, ".WBNB");
        usdt = vm.parseJsonAddress(json, ".USDT");
        pancakeV2Factory = vm.parseJsonAddress(json, ".PancakeV2Factory");
        pancakeV3Factory = vm.parseJsonAddress(json, ".PancakeV3Factory");
        pancakeV3SmartRouter = vm.parseJsonAddress(json, ".PancakeV3SmartRouter");
        basketRegistry = vm.parseJsonAddress(json, ".BasketRegistry");
        basketSwapRouter = vm.parseJsonAddress(json, ".BasketSwapRouter");
        defaultIndexToken = vm.parseJsonAddress(json, ".DefaultIndexToken");
        uint256 configuredFee = vm.parseJsonUint(json, ".BnbUsdtV3Fee");
        require(configuredFee <= type(uint24).max, "Invalid BNB/USDT V3 fee");
        bnbUsdtV3Fee = uint24(configuredFee);
        recordedPump = vm.parseJsonAddress(json, ".Pump");
    }

    function _validateDependencies(address pump) internal view {
        require(pump.code.length > 0, "Pump missing");
        require(committee.code.length > 0, "Committee missing");
        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(clPoolManager.code.length > 0, "CLPoolManager missing");
        require(pancakeV2Factory.code.length > 0, "Pancake V2 factory missing");
        require(pancakeV3Factory.code.length > 0, "Pancake V3 factory missing");
        require(pancakeV3SmartRouter.code.length > 0, "Pancake V3 router missing");
        require(basketRegistry.code.length > 0, "BasketRegistry missing");
        require(basketSwapRouter.code.length > 0, "BasketSwapRouter missing");
        require(IDeployBasketRegistry(basketRegistry).isBasket(defaultIndexToken), "Invalid default index token");
        require(IDeployBasketSwapRouter(basketSwapRouter).settlementToken() == usdt, "Unexpected settlement token");
        require(IDeployPancakeV3Router(pancakeV3SmartRouter).WETH9() == wbnb, "Unexpected wrapped native");
        require(IDeployPancakeV3Router(pancakeV3SmartRouter).factory() == pancakeV3Factory, "Unexpected V3 factory");
        address bnbUsdtPool = IDeployPancakeV3Factory(pancakeV3Factory).getPool(wbnb, usdt, bnbUsdtV3Fee);
        require(bnbUsdtPool.code.length > 0, "BNB/USDT V3 pool missing");
    }

    function _validateDeployment(
        IndexBrokerNFTFactory factory,
        StonkBrokerRenderer renderer,
        IndexBrokerNFTAMM ammTemplate,
        IndexBrokerNFTPriceOracle oracle,
        address pump,
        address targetOwner
    ) internal view {
        require(address(factory).code.length > 0, "Factory deployment failed");
        require(address(renderer).code.length > 0, "Renderer deployment failed");
        require(address(ammTemplate).code.length > 0, "AMM template deployment failed");
        require(address(oracle).code.length > 0, "Oracle deployment failed");
        require(factory.poolTemplate().code.length > 0, "NFT template deployment failed");
        require(factory.pump() == pump, "Factory Pump mismatch");
        require(factory.defaultRenderer() == address(renderer), "Factory Renderer mismatch");
        require(factory.ammTemplate() == address(ammTemplate), "Factory AMM mismatch");
        require(factory.priceOracle() == address(oracle), "Factory Oracle mismatch");
        require(factory.defaultIndexToken() == defaultIndexToken, "Factory index mismatch");
        require(oracle.allowedPancakeV4CLManager(clPoolManager), "Oracle V4 manager missing");
        require(oracle.allowedV2Factory(pancakeV2Factory), "Oracle V2 factory missing");
        require(oracle.allowedV3Factory(pancakeV3Factory), "Oracle V3 factory missing");
        if (targetOwner != factory.owner()) {
            require(factory.pendingOwner() == targetOwner, "Factory owner handover missing");
        }
    }

    function _writeDeployment(
        IndexBrokerNFTFactory factory,
        StonkBrokerRenderer renderer,
        IndexBrokerNFTAMM ammTemplate,
        IndexBrokerNFTPriceOracle oracle,
        address pump,
        address deployer,
        address targetOwner,
        bool committeeWhitelisted
    ) internal {
        _requireVersion11Status("pump-deployed");
        require(pump == vm.parseJsonAddress(vm.readFile(VERSION11_PATH), ".Pump"), "V11 Pump changed before write");
        _writeAddress(".IndexBrokerDeployer", deployer);
        _writeAddress(".IndexBrokerTargetOwner", targetOwner);
        _writeBool(".IndexBrokerOwnershipAccepted", targetOwner == deployer);
        _writeBool(".IndexBrokerFactoryWhitelisted", committeeWhitelisted);
        _writeAddress(".IndexBrokerNFTFactory", address(factory));
        _writeAddress(".IndexBrokerNFTPoolTemplate", factory.poolTemplate());
        _writeAddress(".IndexBrokerNFTAMMTemplate", address(ammTemplate));
        _writeAddress(".IndexBrokerNFTPriceOracle", address(oracle));
        _writeAddress(".StonkBrokerRenderer", address(renderer));
        _writeAddress(".StonkBrokerFaceRenderer", address(renderer.faceRenderer()));
        _writeAddress(".StonkBrokerBodyRenderer", address(renderer.bodyRenderer()));
        _writeAddress(".StonkBrokerAccessoryRenderer", address(renderer.accessoryRenderer()));
        _writeString(".status", "contracts-deployed");
    }

    function _requireVersion11Status(string memory expected) internal view {
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");
        require(_sameString(vm.parseJsonString(json, ".status"), expected), "Unexpected V11 deployment status");
    }

    function _writeAddress(string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), VERSION11_PATH, key);
    }

    function _writeBool(string memory key, bool value) internal {
        vm.writeJson(value ? "true" : "false", VERSION11_PATH, key);
    }

    function _writeString(string memory key, string memory value) internal {
        vm.writeJson(string.concat('"', value, '"'), VERSION11_PATH, key);
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
