// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIndexBrokerNFTRenderer
 * @notice Pluggable raw-SVG renderer dedicated to IndexBrokerNFT.
 */
interface IIndexBrokerNFTRenderer {
    struct RenderParams {
        string collectionName;
        uint256 tokenId;
        uint256 seed;
        uint256 referralCount;
        uint256 miningWeight;
        uint32 level;
        uint8 paletteId;
    }

    function renderSVG(RenderParams calldata params) external view returns (string memory);
}
