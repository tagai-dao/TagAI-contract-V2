// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Committee} from "../src/nutbox/Committee.sol";
import {AIChannelPoolFactory} from "../src/nutbox/dapps/ai-channel/AIChannelPoolFactory.sol";

/// @notice Chain-agnostic deployment for adding AI Channel pools to an
/// existing Nutbox stack. The broadcaster must own Committee to whitelist it.
contract DeployAIChannelPoolFactoryScript is Script {
    function run() external returns (AIChannelPoolFactory factory) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address communityFactory = vm.envAddress("COMMUNITY_FACTORY");
        address committee = vm.envAddress("NUTBOX_COMMITTEE");
        address claimSigner = vm.envAddress("AI_CHANNEL_CLAIM_SIGNER");

        vm.startBroadcast(privateKey);
        factory = new AIChannelPoolFactory(communityFactory, claimSigner);
        Committee(payable(committee)).adminAddContract(address(factory));
        vm.stopBroadcast();

        console.log("AIChannelPoolFactory:", address(factory));
        console.log("AIChannelPoolTemplate:", factory.poolTemplate());
    }
}
