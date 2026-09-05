// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {HBTCIPFSRenderer} from "../src/nutbox/dapps/index-broker-nft/HBTCIPFSRenderer.sol";

/**
 * @title DeployHBTCIPFSRendererScript
 * @notice Deploys the collection-specific HBTC renderer on Robinhood Chain.
 *
 * Dry run:
 *   forge script script/DeployHBTCIPFSRenderer.s.sol \
 *     --rpc-url $RH_RPC_URL --chain-id 4663 -vv
 *
 * Broadcast:
 *   forge script script/DeployHBTCIPFSRenderer.s.sol \
 *     --rpc-url $RH_RPC_URL --chain-id 4663 --broadcast -vv
 *
 * The pool using this renderer must be created with name="HBTC" and maxSupply=1000.
 * Since its metadata is static, configure rerollEnabled=false and pass the deployed
 * renderer in PoolConfig.
 */
contract DeployHBTCIPFSRendererScript is Script {
    function run() external returns (HBTCIPFSRenderer renderer) {
        require(block.chainid == 4663, "RH mainnet only");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console2.log("=== HBTC IPFS Renderer Deploy ===");
        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", deployer);

        vm.startBroadcast(privateKey);
        renderer = new HBTCIPFSRenderer();
        vm.stopBroadcast();

        require(renderer.MAX_SUPPLY() == 1_000, "Unexpected renderer supply");
        console2.log("HBTCIPFSRenderer", address(renderer));
    }
}
