// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

import {TradeCurationFactory} from "../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {Pump, IPumpBasketHook} from "../src/pump/Pump.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {TagAIBuybackRouter} from "../src/router/TagAIBuybackRouter.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {BSCNutboxRouterConfig} from "./config/BSCNutboxRouterConfig.sol";

interface ITradeCommitteeOwner {
    function owner() external view returns (address);
}

interface IPump14SocialSigner {
    function claimSigner() external view returns (address);
}

interface IPump14BasketHookDeploy {
    function basketRegistry() external view returns (address);
}

interface IPump14BasketRegistryDeploy {
    function owner() external view returns (address);
    function approvedCreatorForwarders(address forwarder) external view returns (bool);
    function setCreatorForwarderApproval(address forwarder, bool approved) external;
}

interface IPump14BasketRouterDeploy {
    function basketHook() external view returns (address);
    function settlementToken() external view returns (address);
}

/// @notice Deploys Pump V14 with the existing V13 Token template, plus a new Hook and BuybackRouter.
contract DeployBSCPump14Script is Script {
    address public constant PREVIOUS_PUMP = 0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa;
    address public constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    TradeCurationFactory public deployedTradeFactory;
    uint16 private constant TARGET_BITMAP = 0x0CC1;
    uint256 private constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() external returns (Pump, TagAISwapHook, TagAIBuybackRouter) {
        require(block.chainid == 56, "BSC mainnet only");
        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        Pump previous = Pump(payable(PREVIOUS_PUMP));
        address targetOwner = vm.envOr("PUMP14_OWNER", previous.owner());
        require(targetOwner != address(0), "Owner missing");
        address claimSigner =
            vm.envOr("TRADE_CURATION_CLAIM_SIGNER", IPump14SocialSigner(SOCIAL_CURATION_FACTORY).claimSigner());
        require(claimSigner != address(0), "Trade claim signer missing");
        address existingTokenImplementation = vm.envOr("PUMP14_TOKEN_IMPLEMENTATION", previous.tokenImplementation());
        require(existingTokenImplementation.code.length != 0, "Existing Token template missing");

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
        address listingKeeper = vm.envOr("PUMP14_LISTING_KEEPER", previous.listingKeeper());
        address[] memory constituents = BSCNutboxRouterConfig.constituentAssets();
        address create2Deployer = vm.envAddress("CREATE2_DEPLOYER");
        require(erc20StakingFactory.code.length != 0, "ERC20StakingFactory missing");
        require(listingKeeper != address(0) && constituents.length > 0, "Keeper/assets missing");
        // Keep the validation previously performed by adminSetIndexInfrastructure,
        // even though these existing addresses now initialize in Pump's deployment.
        require(
            nutboxRouter.code.length != 0 && basketHookV4.code.length != 0 && pancakeV2Factory.code.length != 0
                && settlementToken.code.length != 0,
            "Index infrastructure missing"
        );
        IPumpBasketHook indexHook = IPumpBasketHook(basketHookV4);
        require(
            indexHook.tokenVersion() == 4 && indexHook.nutboxRouter() == nutboxRouter
                && indexHook.v2Factory() == pancakeV2Factory && indexHook.settlementToken() == settlementToken,
            "Index infrastructure mismatch"
        );
        require(
            IPump14BasketRouterDeploy(basketSwapRouter).basketHook() == basketHookV4
                && IPump14BasketRouterDeploy(basketSwapRouter).settlementToken() == settlementToken,
            "Basket router mismatch"
        );

        vm.startBroadcast(privateKey);
        Pump pump = new Pump(ipshare, feeReceiver, constituents, existingTokenImplementation);
        address tokenImplementation = pump.tokenImplementation();
        vm.stopBroadcast();

        // Views add no broadcast transactions. Reject stale .env overrides instead
        // of silently deploying a Pump whose defaults disagree with its Hook/routers.
        require(pump.getPoolManager() == poolManager && pump.getVault() == vault, "Fixed Pancake config mismatch");
        require(
            pump.nutboxCommunityFactory() == communityFactory && pump.getCalculator() == calculator
                && pump.erc20StakingFactory() == erc20StakingFactory && pump.nutboxCommittee() == committee,
            "Fixed Nutbox config mismatch"
        );
        require(
            pump.nutboxRouter() == nutboxRouter && pump.basketHookV4() == basketHookV4
                && pump.pancakeV2Factory() == pancakeV2Factory && pump.settlementToken() == settlementToken,
            "Fixed index config mismatch"
        );
        require(pump.listingKeeper() == listingKeeper, "Fixed listing keeper mismatch");

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode, abi.encode(ICLPoolManager(poolManager), IVault(vault), address(pump))
        );
        (bytes32 hookSalt, address predictedHook,) = _mineSalt(create2Deployer, keccak256(creationCode));

        vm.startBroadcast(privateKey);
        TagAISwapHook hook =
            new TagAISwapHook{salt: hookSalt}(ICLPoolManager(poolManager), IVault(vault), address(pump));
        require(address(hook) == predictedHook && uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook mismatch");

        pump.adminSetHookAddress(address(hook));
        TagAIBuybackRouter buyback =
            new TagAIBuybackRouter(address(pump), nutboxRouter, basketSwapRouter, settlementToken);
        pump.adminSetBuybackRouter(address(buyback));
        TradeCurationFactory tradeFactory = new TradeCurationFactory(communityFactory, claimSigner);
        deployedTradeFactory = tradeFactory;
        pump.adminSetOptionalPoolFactory(address(tradeFactory), "Trade Curation", 8000, true);
        if (ITradeCommitteeOwner(committee).owner() == deployer) {
            ICommittee(committee).adminAddContract(address(tradeFactory));
        }
        if (targetOwner != deployer) tradeFactory.transferOwnership(targetOwner);

        NutboxRouter router = NutboxRouter(payable(nutboxRouter));
        if (router.owner() == deployer && !router.operators(address(pump))) router.addOperator(address(pump));

        address registryAddress = IPump14BasketHookDeploy(basketHookV4).basketRegistry();
        IPump14BasketRegistryDeploy registry = IPump14BasketRegistryDeploy(registryAddress);
        if (registry.owner() == deployer && !registry.approvedCreatorForwarders(address(pump))) {
            registry.setCreatorForwarderApproval(address(pump), true);
        }
        if (targetOwner != deployer) pump.transferOwnership(targetOwner);
        vm.stopBroadcast();

        console2.log("Pump14", address(pump));
        console2.log("TradeCurationFactory", address(tradeFactory));
        console2.log("TradeCuration implementation", tradeFactory.poolTemplate());
        if (!ICommittee(committee).verifyContract(address(tradeFactory))) {
            console2.log("ACTION: Committee owner whitelist TradeCurationFactory", address(tradeFactory));
        }
        if (targetOwner != deployer) console2.log("ACTION: TradeCurationFactory owner accept ownership", targetOwner);
        console2.log("Reused Token V13 implementation", tokenImplementation);
        console2.log("TagAISwapHook14", address(hook));
        console2.log("TagAIBuybackRouter", address(buyback));
        if (!ICommittee(committee).verifyContract(erc20StakingFactory)) {
            console2.log("ACTION: Committee owner whitelist ERC20StakingFactory", erc20StakingFactory);
        }
        if (!router.operators(address(pump))) console2.log("ACTION: Router owner add Pump14 operator", address(pump));
        if (!registry.approvedCreatorForwarders(address(pump))) {
            console2.log("ACTION: Basket Registry owner approve Pump14 creator forwarder", address(pump));
        }
        if (targetOwner != deployer) console2.log("ACTION: Pump14 owner accept ownership", targetOwner);
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
