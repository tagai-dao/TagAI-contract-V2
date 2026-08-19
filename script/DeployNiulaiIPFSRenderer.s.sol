// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {NiulaiIPFSRenderer} from "../src/nutbox/dapps/index-broker-nft/NiulaiIPFSRenderer.sol";

/**
 * @title DeployNiulaiIPFSRendererScript
 * @notice Deploys the collection-specific Niulai renderer with onchain metadata.
 *
 * Dry run:
 *   forge script script/DeployNiulaiIPFSRenderer.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast and verify:
 *   forge script script/DeployNiulaiIPFSRenderer.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * The pool using this renderer must be created with name="Niulai" and maxSupply=6666.
 * Since its metadata is static, configure rerollEnabled=false and pass the deployed
 * renderer in PoolConfig.
 */
contract DeployNiulaiIPFSRendererScript is Script {
    function run() external returns (NiulaiIPFSRenderer renderer) {
        require(block.chainid == 56, "BSC mainnet only");

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);

        console2.log("=== Niulai IPFS Renderer Deploy ===");
        console2.log("Deployer", deployer);

        vm.startBroadcast(privateKey);
        renderer = new NiulaiIPFSRenderer();
        vm.stopBroadcast();

        require(renderer.MAX_SUPPLY() == 6_666, "Unexpected renderer supply");
        console2.log("NiulaiIPFSRenderer", address(renderer));
    }
}
