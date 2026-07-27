// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NFTMiningPoolFactory} from "../src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol";

/**
 * @title DeployNFTMiningFactory
 * @notice Scenario B: deploy NFTMiningPoolFactory onto an existing Nutbox stack.
 *
 * Does NOT call Committee.adminAddContract — whitelist is left to the operator.
 *
 * Env:
 *   PRIVATE_KEY              — deployer key (factory Ownable owner)
 *   RH_COMMUNITY_FACTORY     — optional override; else uses known RH addresses by chainId
 *
 * Usage:
 *   FOUNDRY_PROFILE=rh_mainnet forge script script/DeployNFTMiningFactory.s.sol:DeployNFTMiningFactoryScript -vvv
 *   FOUNDRY_PROFILE=rh_mainnet forge script script/DeployNFTMiningFactory.s.sol:DeployNFTMiningFactoryScript \
 *     --broadcast --slow --gas-estimate-multiplier 300 -vvv
 */
contract DeployNFTMiningFactoryScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;

    address internal constant RH_MAINNET_COMMUNITY_FACTORY = 0x24328DccA1bA54EeE82e2993F021802e64290486;
    address internal constant RH_TESTNET_COMMUNITY_FACTORY = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address communityFactory = _resolveCommunityFactory();

        console.log("=== Deploy NFTMiningPoolFactory (additive) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("CommunityFactory:", communityFactory);
        require(communityFactory.code.length > 0, "CommunityFactory missing on this chain");

        vm.startBroadcast(pk);
        NFTMiningPoolFactory factory = new NFTMiningPoolFactory(communityFactory);
        vm.stopBroadcast();

        address template = factory.poolTemplate();
        address renderer = factory.defaultRenderer();

        console.log("NFTMiningPoolFactory:", address(factory));
        console.log("NFTMiningPoolTemplate:", template);
        console.log("NFTMiningRenderer:", renderer);
        console.log("platformFeeBps:", factory.platformFeeBps());
        console.log("factory.owner():", factory.owner());
        console.log("---");
        console.log("Next (manual): Committee.adminAddContract(", address(factory), ")");
        console.log("=== Done (whitelist NOT applied) ===");
    }

    function _resolveCommunityFactory() internal view returns (address) {
        address overrideCf = vm.envOr("RH_COMMUNITY_FACTORY", address(0));
        if (overrideCf != address(0)) return overrideCf;
        if (block.chainid == RH_MAINNET_CHAIN_ID) return RH_MAINNET_COMMUNITY_FACTORY;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return RH_TESTNET_COMMUNITY_FACTORY;
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_mainnet|rh_testnet or set RH_COMMUNITY_FACTORY");
    }
}
