// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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
 * Broadcast and write deployments/56/index-broker-nft.json only after success:
 *   WRITE_DEPLOYMENTS=true forge script script/DeployBSCIndexBrokerNFT.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * Set BSC_PUMP to the newly deployed Pump address when it has not yet been written to
 * deployments/56/addresses.json. Set INDEX_BROKER_OWNER to initiate Ownable2Step handover.
 */
contract DeployBSCIndexBrokerNFTScript is Script {
    string internal constant BSC_DEPLOYMENTS = "deployments/56/addresses.json";
    string internal constant OUTPUT_PATH = "deployments/56/index-broker-nft.json";

    address internal constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address internal constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant BASKET_REGISTRY = 0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe;
    address internal constant BASKET_SWAP_ROUTER = 0x4c3a94f166d3046F10D002FDDe426E9C0b6C703e;
    address internal constant DEFAULT_INDEX_TOKEN = 0xcF99DeC9439630ccf7Efe392F0fc2aF98EF99a61;
    uint24 internal constant BNB_USDT_V3_FEE = 100;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        require(vm.exists(BSC_DEPLOYMENTS), "BSC deployment record missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        string memory currentDeployments = vm.readFile(BSC_DEPLOYMENTS);
        address recordedPump = vm.parseJsonAddress(currentDeployments, ".Pump");
        address pump = vm.envOr("BSC_PUMP", recordedPump);
        address targetOwner = vm.envOr("INDEX_BROKER_OWNER", deployer);
        bool writeDeployments = vm.envOr("WRITE_DEPLOYMENTS", false);

        _validateDependencies(pump);

        console2.log("=== BSC Index Broker NFT Deploy ===");
        console2.log("Deployer", deployer);
        console2.log("Pump", pump);
        console2.log("Default index token", DEFAULT_INDEX_TOKEN);
        console2.log("Target Factory owner", targetOwner);

        vm.startBroadcast(privateKey);

        StonkBrokerRenderer renderer = new StonkBrokerRenderer();
        IndexBrokerNFTAMM ammTemplate = new IndexBrokerNFTAMM();

        address[] memory v2Factories = new address[](1);
        v2Factories[0] = PANCAKE_V2_FACTORY;
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = PANCAKE_V3_FACTORY;
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = CL_POOL_MANAGER;
        IndexBrokerNFTPriceOracle oracle =
            new IndexBrokerNFTPriceOracle(WBNB, v2Factories, v3Factories, new address[](0), pancakeV4Managers);

        IndexBrokerNFTFactory factory = new IndexBrokerNFTFactory(
            COMMUNITY_FACTORY,
            pump,
            address(renderer),
            address(ammTemplate),
            address(oracle),
            BASKET_REGISTRY,
            BASKET_SWAP_ROUTER,
            PANCAKE_V3_SMART_ROUTER,
            BNB_USDT_V3_FEE,
            DEFAULT_INDEX_TOKEN
        );

        if (targetOwner != deployer) factory.transferOwnership(targetOwner);

        address committeeOwner = Ownable(COMMITTEE).owner();
        bool committeeWhitelisted = ICommittee(COMMITTEE).verifyContract(address(factory));
        if (!committeeWhitelisted && committeeOwner == deployer) {
            ICommittee(COMMITTEE).adminAddContract(address(factory));
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

        if (writeDeployments) {
            _writeDeployment(factory, renderer, ammTemplate, oracle, pump, deployer, targetOwner, committeeWhitelisted);
            console2.log("Deployment record written", OUTPUT_PATH);
        } else {
            console2.log("Dry run: deployment record not written");
        }
    }

    function _validateDependencies(address pump) internal view {
        require(pump.code.length > 0, "Pump missing");
        require(COMMITTEE.code.length > 0, "Committee missing");
        require(COMMUNITY_FACTORY.code.length > 0, "CommunityFactory missing");
        require(CL_POOL_MANAGER.code.length > 0, "CLPoolManager missing");
        require(PANCAKE_V2_FACTORY.code.length > 0, "Pancake V2 factory missing");
        require(PANCAKE_V3_FACTORY.code.length > 0, "Pancake V3 factory missing");
        require(PANCAKE_V3_SMART_ROUTER.code.length > 0, "Pancake V3 router missing");
        require(BASKET_REGISTRY.code.length > 0, "BasketRegistry missing");
        require(BASKET_SWAP_ROUTER.code.length > 0, "BasketSwapRouter missing");
        require(IDeployBasketRegistry(BASKET_REGISTRY).isBasket(DEFAULT_INDEX_TOKEN), "Invalid default index token");
        require(IDeployBasketSwapRouter(BASKET_SWAP_ROUTER).settlementToken() == USDT, "Unexpected settlement token");
        require(IDeployPancakeV3Router(PANCAKE_V3_SMART_ROUTER).WETH9() == WBNB, "Unexpected wrapped native");
        require(
            IDeployPancakeV3Router(PANCAKE_V3_SMART_ROUTER).factory() == PANCAKE_V3_FACTORY, "Unexpected V3 factory"
        );
        address bnbUsdtPool = IDeployPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(WBNB, USDT, BNB_USDT_V3_FEE);
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
        require(factory.defaultIndexToken() == DEFAULT_INDEX_TOKEN, "Factory index mismatch");
        require(oracle.allowedPancakeV4CLManager(CL_POOL_MANAGER), "Oracle V4 manager missing");
        require(oracle.allowedV2Factory(PANCAKE_V2_FACTORY), "Oracle V2 factory missing");
        require(oracle.allowedV3Factory(PANCAKE_V3_FACTORY), "Oracle V3 factory missing");
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
        string memory objectKey = "indexBrokerNFT";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "targetOwner", targetOwner);
        vm.serializeBool(objectKey, "committeeWhitelisted", committeeWhitelisted);
        vm.serializeAddress(objectKey, "Pump", pump);
        vm.serializeAddress(objectKey, "IndexBrokerNFTFactory", address(factory));
        vm.serializeAddress(objectKey, "IndexBrokerNFTPoolTemplate", factory.poolTemplate());
        vm.serializeAddress(objectKey, "IndexBrokerNFTAMMTemplate", address(ammTemplate));
        vm.serializeAddress(objectKey, "IndexBrokerNFTPriceOracle", address(oracle));
        vm.serializeAddress(objectKey, "StonkBrokerRenderer", address(renderer));
        vm.serializeAddress(objectKey, "StonkBrokerFaceRenderer", address(renderer.faceRenderer()));
        vm.serializeAddress(objectKey, "StonkBrokerBodyRenderer", address(renderer.bodyRenderer()));
        vm.serializeAddress(objectKey, "StonkBrokerAccessoryRenderer", address(renderer.accessoryRenderer()));
        vm.serializeAddress(objectKey, "CommunityFactory", COMMUNITY_FACTORY);
        vm.serializeAddress(objectKey, "Committee", COMMITTEE);
        vm.serializeAddress(objectKey, "BasketRegistry", BASKET_REGISTRY);
        vm.serializeAddress(objectKey, "BasketSwapRouter", BASKET_SWAP_ROUTER);
        vm.serializeAddress(objectKey, "PancakeV3SmartRouter", PANCAKE_V3_SMART_ROUTER);
        vm.serializeUint(objectKey, "BnbUsdtV3Fee", BNB_USDT_V3_FEE);
        string memory json = vm.serializeAddress(objectKey, "DefaultIndexToken", DEFAULT_INDEX_TOKEN);
        vm.writeJson(json, OUTPUT_PATH);
    }
}
