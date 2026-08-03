// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IPool.sol";

interface INFTMiningPool is IERC721Enumerable, IPool {
    struct NFTInfo {
        address owner;
        uint32 level;
        uint32 batchId;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 miningWeight;
        uint256 seed;
    }

    function mint(uint256 referrerTokenId) external payable returns (uint256 tokenId);

    function createBatch(uint256 maxSupply, address paymentAsset, uint256 mintPrice, uint16 referralBps)
        external
        returns (uint256 batchId);

    function setCurrentBatchPaused(bool paused) external;

    function closeCurrentBatch() external;

    function setFundsReceiver(address newReceiver) external;

    function getNFTInfo(uint256 tokenId) external view returns (NFTInfo memory);

    function tokensOfOwner(address account, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds);

    function miningWeightOf(uint256 tokenId) external view returns (uint256);

    function platformFeeReceiver() external view returns (address);

    function platformFeeBps() external view returns (uint16);

    function renderer() external view returns (address);

    function tokenSVG(uint256 tokenId) external view returns (string memory);

    function contractURI() external view returns (string memory);
}
