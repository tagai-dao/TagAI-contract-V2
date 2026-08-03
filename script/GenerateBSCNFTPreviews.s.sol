// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {INFTMiningRenderer} from "../src/interfaces/INFTMiningRenderer.sol";
import {BSCNFTMiningRenderer} from "../src/nutbox/dapps/nft-mining/BSCNFTMiningRenderer.sol";

/**
 * @title GenerateBSCNFTPreviewsScript
 * @notice Generates deterministic SVG previews for all 16 supported NFT levels.
 */
contract GenerateBSCNFTPreviewsScript is Script {
    string internal constant OUTPUT_DIR = "previews/bsc-nft-mining";

    function run() external {
        vm.createDir(OUTPUT_DIR, true);
        BSCNFTMiningRenderer renderer = new BSCNFTMiningRenderer();

        for (uint32 level = 1; level <= 16; ++level) {
            INFTMiningRenderer.RenderParams memory params = INFTMiningRenderer.RenderParams({
                collectionName: "TAGAI BSC MINING",
                tokenId: 8_888 + level,
                seed: uint256(keccak256(abi.encodePacked("level-preview", level))),
                referralCount: uint256(level - 1) * 5,
                miningWeight: uint256(level) * 10_000,
                batchId: 1,
                level: level,
                paletteId: 1
            });

            string memory prefix = level < 10 ? "0" : "";
            string memory path = string.concat(OUTPUT_DIR, "/level-", prefix, vm.toString(level), ".svg");
            vm.writeFile(path, renderer.renderSVG(params));
            console.log("Generated:", path);
        }

        for (uint32 sample = 1; sample <= 12; ++sample) {
            INFTMiningRenderer.RenderParams memory params = INFTMiningRenderer.RenderParams({
                collectionName: "TAGAI RANDOM NETWORK",
                tokenId: 9_000 + sample,
                seed: uint256(keccak256(abi.encodePacked("random-layout", sample))),
                referralCount: 35,
                miningWeight: 80_000,
                batchId: 1,
                level: 8,
                paletteId: 1
            });

            string memory prefix = sample < 10 ? "0" : "";
            string memory path =
                string.concat(OUTPUT_DIR, "/random-level-08-sample-", prefix, vm.toString(sample), ".svg");
            vm.writeFile(path, renderer.renderSVG(params));
            console.log("Generated:", path);
        }
    }
}
