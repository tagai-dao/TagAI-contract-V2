// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "./IIndexBrokerNFTRenderer.sol";

/**
 * @title HBTCIPFSRenderer
 * @notice Fixed-supply IPFS image renderer for the 1,000-token HBTC collection.
 * @dev Metadata is generated onchain and points directly at the collection's fixed
 *      IPFS image directory. The auxiliary SVG endpoint uses an HTTPS gateway because
 *      ordinary browsers do not resolve ipfs:// URLs embedded in SVG.
 */
contract HBTCIPFSRenderer is IIndexBrokerNFTRenderer {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 1_000;

    string public constant IMAGE_CID = "bafybeid5mf357emmvvhw7gm2k44k3li2ayure7zkh6zpl7hptqbx5ih6vy";
    string public constant IMAGE_BASE_URI = "ipfs://bafybeid5mf357emmvvhw7gm2k44k3li2ayure7zkh6zpl7hptqbx5ih6vy/";
    string public constant IMAGE_GATEWAY_BASE_URI =
        "https://gateway.pinata.cloud/ipfs/bafybeid5mf357emmvvhw7gm2k44k3li2ayure7zkh6zpl7hptqbx5ih6vy/";
    string public constant DESCRIPTION = "HBTC NFT Collection";

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

    /// @notice Maps token IDs 1..1000 to 0001.png..1000.png.
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
