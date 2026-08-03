// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {NFTMiningPoolFactory} from "../src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol";
import {BasketTVLMiningPoolFactory} from "../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPoolFactory.sol";

/**
 * @title DeployBSCMiningFactories
 * @notice Adds NFT mining and Basket TVL mining to the existing BSC Nutbox stack.
 * @dev Committee whitelisting is intentionally left to the multisig operator.
 *
 * Dry-run:
 *   FOUNDRY_PROFILE=bsc_mainnet forge script \
 *     script/DeployBSCMiningFactories.s.sol:DeployBSCMiningFactoriesScript \
 *     --rpc-url $BSC_RPC_URL -vvv
 *
 * Broadcast:
 *   FOUNDRY_PROFILE=bsc_mainnet forge script \
 *     script/DeployBSCMiningFactories.s.sol:DeployBSCMiningFactoriesScript \
 *     --rpc-url $BSC_RPC_URL --broadcast --slow --legacy \
 *     --gas-price 50000000 --gas-estimate-multiplier 150 -vvv
 *
 * A successful broadcast writes all six newly deployed addresses plus the
 * resolved dependencies to deployments/56/addresses.json.
 */
contract DeployBSCMiningFactoriesScript is Script {
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    string internal constant BSC_MAINNET_DEPLOYMENTS = "deployments/56/addresses.json";

    function run() external {
        require(block.chainid == BSC_MAINNET_CHAIN_ID, "expected BSC mainnet chain 56");
        require(vm.exists(BSC_MAINNET_DEPLOYMENTS), "deployments/56/addresses.json missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        string memory deploymentsJson = vm.readFile(BSC_MAINNET_DEPLOYMENTS);
        address communityFactory =
            vm.envOr("BSC_COMMUNITY_FACTORY", vm.parseJsonAddress(deploymentsJson, ".CommunityFactory"));
        address basketRegistry =
            vm.envOr("BSC_BASKET_REGISTRY", vm.parseJsonAddress(deploymentsJson, ".BasketRegistry"));

        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(basketRegistry.code.length > 0, "BasketRegistry missing");

        console.log("=== Deploy BSC Mining Factories ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("CommunityFactory:", communityFactory);
        console.log("BasketRegistry:", basketRegistry);

        vm.startBroadcast(privateKey);
        NFTMiningPoolFactory nftFactory = new NFTMiningPoolFactory(communityFactory);
        BasketTVLMiningPoolFactory basketFactory =
            new BasketTVLMiningPoolFactory(communityFactory, basketRegistry, address(nftFactory));
        vm.stopBroadcast();

        address nftTemplate = nftFactory.poolTemplate();
        address nftRenderer = nftFactory.defaultRenderer();
        address basketTemplate = basketFactory.poolTemplate();
        address basketStakeTemplate = basketFactory.childPoolTemplate();

        require(nftTemplate.code.length > 0, "NFTMiningPool template missing");
        require(nftRenderer.code.length > 0, "BSCNFTMiningRenderer missing");
        require(basketTemplate.code.length > 0, "BasketTVLMiningPool template missing");
        require(basketStakeTemplate.code.length > 0, "BasketStakePool template missing");
        require(basketFactory.nftMiningPoolFactory() == address(nftFactory), "NFT factory mismatch");

        console.log("NFTMiningPoolFactory:", address(nftFactory));
        console.log("NFTMiningPoolTemplate:", nftTemplate);
        console.log("BSCNFTMiningRenderer:", nftRenderer);
        console.log("BasketTVLMiningPoolFactory:", address(basketFactory));
        console.log("BasketTVLMiningPoolTemplate:", basketTemplate);
        console.log("BasketStakePoolTemplate:", basketStakeTemplate);

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            _writeAddresses(
                communityFactory,
                basketRegistry,
                address(nftFactory),
                nftTemplate,
                nftRenderer,
                address(basketFactory),
                basketTemplate,
                basketStakeTemplate
            );
        } else {
            console.log("Dry-run: deployments/56/addresses.json was not changed");
        }

        console.log("Whitelist was NOT applied. Committee multisig must add both factory addresses.");
        console.log("=== Done ===");
    }

    function _writeAddresses(
        address communityFactory,
        address basketRegistry,
        address nftFactory,
        address nftTemplate,
        address nftRenderer,
        address basketFactory,
        address basketTemplate,
        address basketStakeTemplate
    ) internal {
        _writeAddress(".CommunityFactory", communityFactory);
        _writeAddress(".BasketRegistry", basketRegistry);
        _writeAddress(".NFTMiningPoolFactory", nftFactory);
        _writeAddress(".NFTMiningPoolTemplate", nftTemplate);
        _writeAddress(".BSCNFTMiningRenderer", nftRenderer);
        _writeAddress(".BasketTVLMiningPoolFactory", basketFactory);
        _writeAddress(".BasketTVLMiningPoolTemplate", basketTemplate);
        _writeAddress(".BasketStakePoolTemplate", basketStakeTemplate);
        console.log("Addresses added to:", BSC_MAINNET_DEPLOYMENTS);
    }

    function _writeAddress(string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), BSC_MAINNET_DEPLOYMENTS, key);
    }
}
