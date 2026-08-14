// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

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
 * The production V9 snapshot is immutable. This historical script reads its
 * dependencies from version9.json but never overwrites that file.
 */
contract DeployBSCMiningFactoriesScript is Script {
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    string internal constant BSC_MAINNET_DEPLOYMENTS = "deployments/56/version9.json";

    function run() external {
        require(block.chainid == BSC_MAINNET_CHAIN_ID, "expected BSC mainnet chain 56");
        require(vm.exists(BSC_MAINNET_DEPLOYMENTS), "deployments/56/version9.json missing");

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

        console.log("Immutable deployment snapshot was not changed:", BSC_MAINNET_DEPLOYMENTS);

        console.log("Whitelist was NOT applied. Committee multisig must add both factory addresses.");
        console.log("=== Done ===");
    }
}
