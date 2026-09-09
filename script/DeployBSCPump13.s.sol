// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

import {Pump} from "../src/pump/Pump.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {TagAIBuybackRouter} from "../src/router/TagAIBuybackRouter.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {BSCNutboxRouterConfig} from "./config/BSCNutboxRouterConfig.sol";

interface IPump13BasketHookDeploy {
    function basketRegistry() external view returns (address);
}

interface IPump13BasketRegistryDeploy {
    function owner() external view returns (address);
    function approvedCreatorForwarders(address forwarder) external view returns (bool);
    function setCreatorForwarderApproval(address forwarder, bool approved) external;
}

interface IPump13BasketRouterDeploy {
    function basketHook() external view returns (address);
    function settlementToken() external view returns (address);
}

/// @notice Deploys canonical Pump/Token V13 and its V4 Hook, then connects Router and Basket V4 permissions when deployer owns them.
contract DeployBSCPump13Script is Script {
    uint16 private constant TARGET_BITMAP = 0x0CC1;
    uint256 private constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() external returns (Pump, TagAISwapHook, TagAIBuybackRouter) {
        require(block.chainid == 56, "BSC mainnet only");
        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        address targetOwner = vm.envOr("PUMP13_OWNER", deployer);

        address ipshare = vm.envAddress("IP_SHARE");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        address poolManager = vm.envAddress("CL_POOL_MANAGER");
        address vault = vm.envAddress("VAULT");
        address communityFactory = vm.envAddress("COMMUNITY_FACTORY");
        address calculator = vm.envAddress("CALCULATOR");
        address erc20StakingFactory = vm.envAddress("ERC20_STAKING_FACTORY");
        address committee = vm.envAddress("COMMITTEE");
        address nutboxRouter = vm.envAddress("NUTBOX_ROUTER");
        address basketHookV4 = vm.envAddress("BASKET_HOOK_V4");
        address pancakeV2Factory = vm.envAddress("PANCAKE_V2_FACTORY");
        address settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        address basketSwapRouter = vm.envAddress("BASKET_SWAP_ROUTER_V4");
        address listingKeeper = vm.envAddress("PUMP13_LISTING_KEEPER");
        address[] memory constituents = BSCNutboxRouterConfig.constituentAssets();
        address create2Deployer = vm.envAddress("CREATE2_DEPLOYER");
        require(erc20StakingFactory.code.length != 0, "ERC20StakingFactory missing");
        require(listingKeeper != address(0) && constituents.length > 0, "Keeper/assets missing");
        require(
            IPump13BasketRouterDeploy(basketSwapRouter).basketHook() == basketHookV4
                && IPump13BasketRouterDeploy(basketSwapRouter).settlementToken() == settlementToken,
            "Basket router mismatch"
        );

        vm.startBroadcast(privateKey);
        Pump pump = new Pump(ipshare, feeReceiver, constituents);
        address tokenImplementation = pump.tokenImplementation();
        pump.adminSetPoolManager(poolManager);
        pump.adminSetVault(vault);
        vm.stopBroadcast();

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode, abi.encode(ICLPoolManager(poolManager), IVault(vault), address(pump))
        );
        (bytes32 hookSalt, address predictedHook,) = _mineSalt(create2Deployer, keccak256(creationCode));

        vm.startBroadcast(privateKey);
        TagAISwapHook hook =
            new TagAISwapHook{salt: hookSalt}(ICLPoolManager(poolManager), IVault(vault), address(pump));
        require(address(hook) == predictedHook && uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook mismatch");

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(calculator);
        pump.adminSetNutbox(communityFactory, calculator, erc20StakingFactory, committee);
        pump.adminSetIndexInfrastructure(nutboxRouter, basketHookV4, pancakeV2Factory, settlementToken);
        TagAIBuybackRouter buyback =
            new TagAIBuybackRouter(address(pump), nutboxRouter, basketSwapRouter, settlementToken);
        pump.adminSetBuybackRouter(address(buyback));
        pump.adminSetListingKeeper(listingKeeper);

        NutboxRouter router = NutboxRouter(payable(nutboxRouter));
        if (router.owner() == deployer && !router.operators(address(pump))) router.addOperator(address(pump));

        address registryAddress = IPump13BasketHookDeploy(basketHookV4).basketRegistry();
        IPump13BasketRegistryDeploy registry = IPump13BasketRegistryDeploy(registryAddress);
        if (registry.owner() == deployer && !registry.approvedCreatorForwarders(address(pump))) {
            registry.setCreatorForwarderApproval(address(pump), true);
        }
        if (targetOwner != deployer) pump.transferOwnership(targetOwner);
        vm.stopBroadcast();

        console2.log("Pump13", address(pump));
        console2.log("Token V13 implementation", tokenImplementation);
        console2.log("TagAISwapHook13", address(hook));
        console2.log("TagAIBuybackRouter", address(buyback));
        if (!ICommittee(committee).verifyContract(erc20StakingFactory)) {
            console2.log("ACTION: Committee owner whitelist ERC20StakingFactory", erc20StakingFactory);
        }
        if (!router.operators(address(pump))) console2.log("ACTION: Router owner add Pump13 operator", address(pump));
        if (!registry.approvedCreatorForwarders(address(pump))) {
            console2.log("ACTION: Basket Registry owner approve Pump13 creator forwarder", address(pump));
        }
        if (targetOwner != deployer) console2.log("ACTION: Pump13 owner accept ownership", targetOwner);
        return (pump, hook, buyback);
    }

    function _mineSalt(address deployer, bytes32 bytecodeHash)
        private
        pure
        returns (bytes32 salt, address predictedAddress, uint256 iterations)
    {
        for (uint256 i; i < MAX_MINING_ITERATIONS; ++i) {
            salt = bytes32(i);
            predictedAddress =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash)))));
            if (uint16(uint160(predictedAddress)) == TARGET_BITMAP) return (salt, predictedAddress, i + 1);
        }
        revert("No valid Hook salt");
    }
}
