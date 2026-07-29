// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {BasketTVLMiningPoolFactory} from
    "../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPoolFactory.sol";

/**
 * @title DeployBasketTVLMiningFactory
 * @notice Deploys only BasketTVLMiningPoolFactory and its two implementation templates.
 * @dev Committee whitelisting is intentionally left to the operator.
 *
 * Mainnet:
 *   FOUNDRY_PROFILE=rh_mainnet forge script \
 *     script/DeployBasketTVLMiningFactory.s.sol:DeployBasketTVLMiningFactoryScript \
 *     --broadcast --slow --gas-estimate-multiplier 300 -vvv
 *
 * When run with --broadcast, the dependency and deployment addresses are added
 * to deployments/4663/addresses.json. A dry-run never changes that file.
 */
contract DeployBasketTVLMiningFactoryScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    string internal constant RH_MAINNET_DEPLOYMENTS = "deployments/4663/addresses.json";

    function run() external {
        require(block.chainid == RH_MAINNET_CHAIN_ID, "expected RH mainnet 4663");
        require(vm.exists(RH_MAINNET_DEPLOYMENTS), "deployments/4663/addresses.json missing");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory deploymentsJson = vm.readFile(RH_MAINNET_DEPLOYMENTS);
        address communityFactory =
            vm.envOr("RH_COMMUNITY_FACTORY", vm.parseJsonAddress(deploymentsJson, ".CommunityFactory"));
        address basketRegistry =
            vm.envOr("RH_BASKET_REGISTRY", vm.parseJsonAddress(deploymentsJson, ".BasketRegistry"));
        address nftMiningPoolFactory = vm.envOr(
            "RH_NFT_MINING_POOL_FACTORY", vm.parseJsonAddress(deploymentsJson, ".NFTMiningPoolFactory")
        );

        console.log("=== Deploy Basket TVL Mining Factory ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("CommunityFactory:", communityFactory);
        console.log("BasketRegistry:", basketRegistry);
        console.log("NFTMiningPoolFactory:", nftMiningPoolFactory);

        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(basketRegistry.code.length > 0, "BasketRegistry missing");
        require(nftMiningPoolFactory.code.length > 0, "NFTMiningPoolFactory missing");

        vm.startBroadcast(pk);
        BasketTVLMiningPoolFactory factory =
            new BasketTVLMiningPoolFactory(communityFactory, basketRegistry, nftMiningPoolFactory);
        vm.stopBroadcast();

        address poolTemplate = factory.poolTemplate();
        address childPoolTemplate = factory.childPoolTemplate();

        require(poolTemplate.code.length > 0, "BasketTVLMiningPool template missing");
        require(childPoolTemplate.code.length > 0, "BasketStakePool template missing");

        console.log("BasketTVLMiningPoolFactory:", address(factory));
        console.log("BasketTVLMiningPoolTemplate:", poolTemplate);
        console.log("BasketStakePoolTemplate:", childPoolTemplate);

        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            _writeAddresses(
                communityFactory,
                basketRegistry,
                nftMiningPoolFactory,
                address(factory),
                poolTemplate,
                childPoolTemplate
            );
        } else {
            console.log("Dry-run: deployments/4663/addresses.json was not changed");
        }

        console.log("Whitelist was NOT applied; add the factory to Committee manually");
        console.log("=== Done ===");
    }

    function _writeAddresses(
        address communityFactory,
        address basketRegistry,
        address nftMiningPoolFactory,
        address factory,
        address poolTemplate,
        address childPoolTemplate
    ) internal {
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".CommunityFactory", communityFactory);
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".BasketRegistry", basketRegistry);
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".NFTMiningPoolFactory", nftMiningPoolFactory);
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".BasketTVLMiningPoolFactory", factory);
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".BasketTVLMiningPoolTemplate", poolTemplate);
        _writeAddress(RH_MAINNET_DEPLOYMENTS, ".BasketStakePoolTemplate", childPoolTemplate);

        console.log("Addresses added to:", RH_MAINNET_DEPLOYMENTS);
    }

    function _writeAddress(string memory path, string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), path, key);
    }
}
