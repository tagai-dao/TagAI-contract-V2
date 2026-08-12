// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIndexBrokerNFTRenderer
 * @notice Pluggable metadata and SVG renderer dedicated to IndexBrokerNFT.
 */
interface IIndexBrokerNFTRenderer {
    struct RenderParams {
        string collectionName;
        uint256 tokenId;
        uint256 seed;
        uint256 referralCount;
        uint256 referrerTokenId;
        uint256 miningWeight;
        uint256 indexMiningWeight;
        uint32 level;
        uint8 paletteId;
        bool miningActive;
        bool indexMiningActive;
    }

    function renderSVG(RenderParams calldata params) external view returns (string memory);
    function renderTokenURI(RenderParams calldata params) external view returns (string memory);
    function renderContractURI(string calldata collectionName) external view returns (string memory);
}
