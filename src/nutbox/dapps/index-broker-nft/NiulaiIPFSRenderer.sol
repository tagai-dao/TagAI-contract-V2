// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "./IIndexBrokerNFTRenderer.sol";

/**
 * @title NiulaiIPFSRenderer
 * @notice Fixed-supply IPFS image renderer for the 6,666-token Niulai collection.
 * @dev Metadata is generated onchain and points directly at the collection's fixed
 *      IPFS image directory. The auxiliary SVG endpoint uses the collection's HTTPS
 *      gateway because ordinary browsers do not resolve ipfs:// URLs embedded in SVG.
 */
contract NiulaiIPFSRenderer is IIndexBrokerNFTRenderer {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 6_666;

    string public constant IMAGE_CID = "bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4";
    string public constant IMAGE_BASE_URI = "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/";
    string public constant IMAGE_GATEWAY_BASE_URI =
        "https://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4.ipfs.4everland.io/";
    string public constant DESCRIPTION = "Niulai NFT Collection";

    error InvalidTokenId(uint256 tokenId);

    function renderSVG(RenderParams calldata params) external pure override returns (string memory) {
        string memory image = gatewayImageURI(params.tokenId);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">',
            '<image width="1000" height="1000" preserveAspectRatio="xMidYMid meet" href="',
            image,
            '"/></svg>'
        );
    }

    function renderTokenURI(RenderParams calldata params) external pure override returns (string memory) {
        _validateTokenId(params.tokenId);
        string memory json = string.concat(
            '{"name":"',
            params.collectionName,
            " #",
            params.tokenId.toString(),
            '","description":"',
            DESCRIPTION,
            '","image":"',
            imageURI(params.tokenId),
            '","attributes":[]}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function renderContractURI(string calldata collectionName) external pure override returns (string memory) {
        string memory json = string.concat(
            '{"name":"', collectionName, '","description":"', DESCRIPTION, '","image":"', imageURI(1), '"}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Returns the canonical, gateway-independent image URI for a token.
    function imageURI(uint256 tokenId) public pure returns (string memory) {
        return string.concat(IMAGE_BASE_URI, fileName(tokenId));
    }

    /// @notice Returns the browser-compatible image URI used only by renderSVG.
    function gatewayImageURI(uint256 tokenId) public pure returns (string memory) {
        return string.concat(IMAGE_GATEWAY_BASE_URI, fileName(tokenId));
    }

    /// @notice Maps token IDs 1..6666 to 0001.png..6666.png.
    function fileName(uint256 tokenId) public pure returns (string memory) {
        _validateTokenId(tokenId);

        string memory id = tokenId.toString();
        if (tokenId < 10) return string.concat("000", id, ".png");
        if (tokenId < 100) return string.concat("00", id, ".png");
        if (tokenId < 1_000) return string.concat("0", id, ".png");
        return string.concat(id, ".png");
    }

    function _validateTokenId(uint256 tokenId) private pure {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert InvalidTokenId(tokenId);
    }
}
