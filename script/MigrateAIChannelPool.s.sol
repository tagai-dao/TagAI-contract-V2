// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Community} from "../src/nutbox/Community.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {AIChannelPoolFactory} from "../src/nutbox/dapps/ai-channel/AIChannelPoolFactory.sol";

/// @notice Owner-run migration for one existing Community. Existing pool
/// ratios retain their relative weights inside the remaining 50%.
contract MigrateAIChannelPoolScript is Script {
    uint16 private constant AI_CHANNEL_RATIO = 5_000;
    bytes32 private constant POLICY_HASH = keccak256("TAGAI_AI_CHANNEL_POB_V1_REPLY_3VP_WINDOW_3D");

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address communityAddress = vm.envAddress("COMMUNITY");
        address factoryAddress = vm.envAddress("AI_CHANNEL_FACTORY");
        Community community = Community(payable(communityAddress));
        AIChannelPoolFactory factory = AIChannelPoolFactory(factoryAddress);
        bytes32 channelKey = keccak256(abi.encode(block.chainid, communityAddress, "TAGAI_AI_CHANNEL_V1"));

        require(!factory.createdPoolOfChannel(communityAddress, channelKey), "AI Channel pool already exists");

        uint256 count = _activePoolCount(ICommunity(communityAddress));
        require(count > 0, "Community has no active pool");
        uint16[] memory ratios = new uint16[](count + 1);
        uint256 assigned;
        for (uint256 i; i < count; ++i) {
            address pool = community.activedPools(i);
            uint16 scaled = uint16((uint256(community.poolRatios(pool)) * AI_CHANNEL_RATIO) / 10_000);
            ratios[i] = scaled;
            assigned += scaled;
        }
        // Put integer division dust into the first existing pool.
        ratios[0] += uint16(AI_CHANNEL_RATIO - assigned);
        ratios[count] = AI_CHANNEL_RATIO;

        uint256 settingsFee = ICommittee(community.getCommittee()).getCommunitySettingsFee();
        vm.startBroadcast(privateKey);
        community.adminAddPool{value: settingsFee}(
            "TagAgent AI Channel", ratios, factoryAddress, abi.encode(channelKey, POLICY_HASH)
        );
        vm.stopBroadcast();

        console.log("Community:", communityAddress);
        console.log("AIChannelPool:", community.activedPools(count));
    }

    function _activePoolCount(ICommunity community) private view returns (uint256 count) {
        // Community.MAX_ACTIVE_POOLS bounds this loop; a missing public length
        // getter is handled by probing the generated array getter.
        for (uint256 i; i < 32; ++i) {
            try community.activedPools(i) returns (address) {
                ++count;
            } catch {
                break;
            }
        }
    }
}
