// SPDX-License-Identifier: MIT
// Source attribution: see ./stonk/SOURCE_NOTICE.md.
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "./IIndexBrokerNFTRenderer.sol";
import "./stonk/StonkBrokerAccessoryRenderer.sol";
import "./stonk/StonkBrokerBodyRenderer.sol";
import "./stonk/StonkBrokerFaceRenderer.sol";
import "./stonk/StonkBrokerTraits.sol";

/**
 * @title StonkBrokerRenderer
 * @notice Standalone Stonk Broker pixel-art renderer for IndexBrokerNFT.
 * @dev Deploys and permanently binds its own art modules. It does not call the original
 *      Stonk Broker NFT or renderer contracts. A zero seed is the unrevealed-state convention.
 */
contract StonkBrokerRenderer is IIndexBrokerNFTRenderer {
    using Strings for uint256;

    StonkBrokerFaceRenderer public immutable faceRenderer;
    StonkBrokerBodyRenderer public immutable bodyRenderer;
    StonkBrokerAccessoryRenderer public immutable accessoryRenderer;

    constructor() {
        faceRenderer = new StonkBrokerFaceRenderer();
        bodyRenderer = new StonkBrokerBodyRenderer();
        accessoryRenderer = new StonkBrokerAccessoryRenderer();
    }

    function renderSVG(RenderParams calldata params) external view override returns (string memory) {
        return params.seed == 0 ? _unrevealedSVG(params) : _revealedSVG(params);
    }

    function renderTokenURI(RenderParams calldata params) external view override returns (string memory) {
        bool revealed = params.seed != 0;
        string memory image = revealed ? _revealedSVG(params) : _unrevealedSVG(params);
        string memory attributes = revealed
            ? string.concat(_visualAttributes(params.seed), ",", _miningAttributes(params))
            : string.concat('{"trait_type":"Status","value":"Unrevealed"},', _miningAttributes(params));

        string memory json = string.concat(
            '{"name":"',
            params.collectionName,
            " #",
            params.tokenId.toString(),
            revealed ? '"' : ' (Unrevealed)"',
            ',"description":"An onchain pixel broker NFT with community and index-token mining.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image)),
            '","attributes":[',
            attributes,
            "]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function renderContractURI(string calldata collectionName) external pure override returns (string memory) {
        string memory collectionSvg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges" viewBox="0 0 24 24" width="720" height="720">',
            '<rect width="24" height="24" fill="#0a0c10"/>',
            '<rect x="4" y="3" width="16" height="18" fill="#151a24"/>',
            '<rect x="7" y="6" width="10" height="8" fill="#d9ad7c"/>',
            '<rect x="8" y="8" width="2" height="2" fill="#1d3557"/><rect x="14" y="8" width="2" height="2" fill="#1d3557"/>',
            '<rect x="9" y="14" width="6" height="2" fill="#f0f0f0"/><rect x="5" y="16" width="14" height="6" fill="#263c66"/>',
            '<rect x="11" y="17" width="2" height="5" fill="#f0b90b"/></svg>'
        );
        string memory json = string.concat(
            '{"name":"',
            collectionName,
            '","description":"Onchain pixel broker NFTs with community and index-token mining.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(collectionSvg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _revealedSVG(RenderParams calldata params) private view returns (string memory) {
        StonkBrokerTraits.Traits memory t = StonkBrokerTraits.decode(params.seed);
        (string memory body, string memory badge) = bodyRenderer.renderBody(params.seed);
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges" viewBox="0 0 24 24" width="720" height="720"><rect width="24" height="24" fill="#',
                _hex(_pickBackground(t.background)),
                '"/>',
                faceRenderer.renderFace(params.seed),
                body,
                accessoryRenderer.renderAccessory(params.seed),
                badge,
                _indexMiningBadge(params.indexMiningWeight, params.communityTokenUnit),
                "</svg>"
            )
        );
    }

    function _indexMiningBadge(uint256 rawWeight, uint256 tokenUnit) private pure returns (string memory) {
        if (tokenUnit == 0) tokenUnit = 1;
        uint256 weight = rawWeight / tokenUnit;
        uint256 tier;
        uint256 low;
        uint256 high;

        if (weight < 100_000) {
            high = 100_000;
        } else if (weight < 1_000_000) {
            tier = 1;
            low = 100_000;
            high = 1_000_000;
        } else if (weight < 10_000_000) {
            tier = 2;
            low = 1_000_000;
            high = 10_000_000;
        } else {
            tier = 3;
            low = 10_000_000;
            high = 100_000_000;
        }

        uint256 progress = weight >= high ? 10_000 : (weight - low) * 10_000 / (high - low);
        bytes3 color = _badgeColor(progress);
        bytes3 light = _scaleColor(color, 116);
        bytes3 dark = _scaleColor(color, 68);

        return string.concat(
            '<g id="index-mining-badge" data-tier="',
            tier.toString(),
            '" transform="translate(20.6 .35) scale(.0295)" shape-rendering="geometricPrecision">',
            _badgeShape(tier, _hex(color), _hex(light), _hex(dark)),
            "</g>"
        );
    }

    function _badgeShape(uint256 tier, string memory color, string memory light, string memory dark)
        private
        pure
        returns (string memory)
    {
        if (tier == 0) {
            return string.concat(
                '<path d="M31 12H69L88 36 73 82 50 94 27 82 12 36Z" fill="#',
                color,
                '"/><path d="M31 12 50 36 12 36ZM69 12 88 36H50Z" fill="#',
                light,
                '" opacity=".78"/><path d="M12 36H50L27 82ZM88 36 73 82 50 36Z" fill="#',
                dark,
                '" opacity=".52"/><path d="M27 82 50 36 73 82 50 94Z" fill="#',
                dark,
                '" opacity=".22"/>'
            );
        }
        if (tier == 1) {
            return string.concat(
                '<path d="M13 35 29 12H71L87 35 50 94Z" fill="#',
                color,
                '"/><path d="M13 35 29 12 39 35ZM29 12 50 35 39 35ZM29 12H71L50 35Z" fill="#',
                light,
                '" opacity=".82"/><path d="M71 12 87 35H61L50 35Z" fill="#',
                dark,
                '" opacity=".4"/><path d="M13 35H39L50 94ZM61 35H87L50 94Z" fill="#',
                dark,
                '" opacity=".54"/><path d="M39 35H61L50 94Z" fill="#',
                light,
                '" opacity=".26"/>'
            );
        }
        if (tier == 2) {
            return string.concat(
                '<path d="M9 26 29 43 50 8 71 43 91 26 82 82H18Z" fill="#',
                color,
                '"/><path d="M18 68H82V84H18Z" fill="#',
                dark,
                '" opacity=".56"/><circle cx="9" cy="25" r="5" fill="#',
                light,
                '"/><circle cx="50" cy="8" r="5" fill="#',
                light,
                '"/><circle cx="91" cy="25" r="5" fill="#',
                light,
                '"/><path d="M18 68 29 43 42 68ZM58 68 71 43 82 68Z" fill="#',
                light,
                '" opacity=".34"/>'
            );
        }
        return string.concat(
            '<path d="M5 31 19 45 27 18 39 44 50 8 61 44 73 18 81 45 95 31 85 82H15Z" fill="#',
            color,
            '"/><path d="M15 67H85V85H15Z" fill="#',
            dark,
            '" opacity=".56"/><circle cx="5" cy="30" r="4.2" fill="#',
            light,
            '"/><circle cx="27" cy="17" r="4.2" fill="#',
            light,
            '"/><circle cx="50" cy="8" r="4.2" fill="#',
            light,
            '"/><circle cx="73" cy="17" r="4.2" fill="#',
            light,
            '"/><circle cx="95" cy="30" r="4.2" fill="#',
            light,
            '"/><path d="M15 67 19 45 30 67ZM35 67 39 44 46 67ZM54 67 61 44 65 67ZM70 67 81 45 85 67Z" fill="#',
            light,
            '" opacity=".34"/>'
        );
    }

    function _badgeColor(uint256 progress) private pure returns (bytes3) {
        bytes3 bronze = 0x9a5b2e;
        bytes3 brass = 0xc8a03a;
        bytes3 gold = 0xf5d36b;
        return
            progress < 5_000
                ? _mixColor(bronze, brass, progress, 5_000)
                : _mixColor(brass, gold, progress - 5_000, 5_000);
    }

    function _mixColor(bytes3 from, bytes3 to, uint256 amount, uint256 denominator) private pure returns (bytes3) {
        uint24 a = uint24(from);
        uint24 b = uint24(to);
        uint256 red = ((a >> 16) & 0xff) + ((((b >> 16) & 0xff) - ((a >> 16) & 0xff)) * amount / denominator);
        uint256 green = ((a >> 8) & 0xff) + ((((b >> 8) & 0xff) - ((a >> 8) & 0xff)) * amount / denominator);
        uint256 blue = (a & 0xff) + (((b & 0xff) - (a & 0xff)) * amount / denominator);
        return bytes3(uint24((red << 16) | (green << 8) | blue));
    }

    function _scaleColor(bytes3 color, uint256 percent) private pure returns (bytes3) {
        uint24 value = uint24(color);
        uint256 red = _min255(((value >> 16) & 0xff) * percent / 100);
        uint256 green = _min255(((value >> 8) & 0xff) * percent / 100);
        uint256 blue = _min255((value & 0xff) * percent / 100);
        return bytes3(uint24((red << 16) | (green << 8) | blue));
    }

    function _min255(uint256 value) private pure returns (uint256) {
        return value > 255 ? 255 : value;
    }

    function _visualAttributes(uint256 seed) private pure returns (string memory) {
        StonkBrokerTraits.Traits memory t = StonkBrokerTraits.decode(seed);
        return string(
            abi.encodePacked(
                '{"trait_type":"Background","value":"',
                _backgroundName(t.background),
                '"}',
                _attr("Skin", StonkBrokerTraits.skinName(t.skin)),
                _attr("Hair Style", StonkBrokerTraits.hairStyleName(t.hairStyle)),
                _attr("Hair Color", StonkBrokerTraits.hairColorNameForMetadata(t.hairStyle, t.hairColor)),
                _attr("Eyes", StonkBrokerTraits.eyeColorName(t.eyeColor)),
                _attr("Nose", StonkBrokerTraits.noseColorName(t.noseColor)),
                _attr("Mouth", StonkBrokerTraits.mouthName(t.mouth)),
                _attr("Suit", StonkBrokerTraits.suitName(t.suit)),
                _attr("Tie", StonkBrokerTraits.tieName(t.tie)),
                _attr("Neckwear", StonkBrokerTraits.neckwearName(t.neckwear)),
                _attr("Face Accessory", StonkBrokerTraits.faceAccessoryName(t.faceAccessory)),
                _attr("Broker Badge", StonkBrokerTraits.brokerBadgeName(t.brokerBadge)),
                _attr("Pocket Square", StonkBrokerTraits.pocketSquareName(t.pocketSquare))
            )
        );
    }

    function _attr(string memory traitType, string memory value) private pure returns (string memory) {
        if (keccak256(bytes(value)) == keccak256(bytes("None"))) return "";
        return string(abi.encodePacked(',{"trait_type":"', traitType, '","value":"', value, '"}'));
    }

    function _miningAttributes(RenderParams calldata params) private pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Level","value":',
            uint256(params.level).toString(),
            '},{"trait_type":"Referral Count","value":',
            params.referralCount.toString(),
            '},{"trait_type":"Referrer NFT","value":',
            params.referrerTokenId.toString(),
            '},{"trait_type":"Community Mining Weight","value":',
            params.miningWeight.toString(),
            '},{"trait_type":"Community Mining Active","value":',
            params.miningActive ? "true" : "false",
            '},{"trait_type":"Index Mining Weight","value":',
            params.indexMiningWeight.toString(),
            '},{"trait_type":"Index Mining Active","value":',
            params.indexMiningActive ? "true" : "false",
            "}"
        );
    }

    function _unrevealedSVG(RenderParams calldata params) private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges" viewBox="0 0 24 24" width="720" height="720">',
            '<rect width="24" height="24" fill="#0a0c10"/>',
            '<rect x="5" y="4" width="14" height="16" fill="#151a24" stroke="#2a3142"/>',
            '<rect x="10" y="7" width="4" height="2" fill="#f5d36b"/>',
            '<rect x="13" y="9" width="2" height="3" fill="#f5d36b"/>',
            '<rect x="11" y="12" width="3" height="2" fill="#f5d36b"/>',
            '<rect x="11" y="16" width="2" height="2" fill="#f5d36b"/>',
            '<text x="12" y="22.5" font-family="monospace" font-size="1.2" fill="#8b95a8" text-anchor="middle">',
            params.collectionName,
            " #",
            params.tokenId.toString(),
            "</text></svg>"
        );
    }

    function _backgroundName(uint8 idx) private pure returns (string memory) {
        if (idx == 0) return "Sky Blue";
        if (idx == 1) return "Light Blue";
        if (idx == 2) return "Pale Blue";
        if (idx == 3) return "Tan";
        if (idx == 4) return "Slate";
        if (idx == 5) return "Steel";
        if (idx == 6) return "Trading Floor Green";
        return "Bloomberg Orange";
    }

    function _pickBackground(uint8 idx) private pure returns (bytes3) {
        if (idx == 0) return 0x6ca0dc;
        if (idx == 1) return 0x8dbfe8;
        if (idx == 2) return 0xb8d2e8;
        if (idx == 3) return 0xd0b090;
        if (idx == 4) return 0x9bb0c8;
        if (idx == 5) return 0x7f92a8;
        if (idx == 6) return 0x2d6a4f;
        return 0xff6f00;
    }

    function _hex(bytes3 data) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(6);
        for (uint256 i; i < 3; ++i) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
