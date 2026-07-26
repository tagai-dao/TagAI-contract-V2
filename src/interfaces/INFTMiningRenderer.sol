// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title INFTMiningRenderer
 * @notice Pluggable raw-SVG renderer used by NFTMiningPool.
 *
 * Implementations must return a complete SVG document. NFTMiningPool wraps the
 * returned bytes as a Base64 `data:image/svg+xml` URI in tokenURI.
 */
interface INFTMiningRenderer {
    struct RenderParams {
        string collectionName;
        uint256 tokenId;
        uint256 seed;
        uint256 referralCount;
        uint256 miningWeight;
        uint32 batchId;
        uint32 level;
        uint8 paletteId;
    }

    function renderSVG(RenderParams calldata params) external view returns (string memory);
}
