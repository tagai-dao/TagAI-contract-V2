// SPDX-License-Identifier: MIT
// Derived from StonkBrokerSvgRendererV6Proposal; see SOURCE_NOTICE.md.
pragma solidity ^0.8.24;

import "./StonkBrokerTraits.sol";

/// @notice Renders the Stonk Broker suit, neckwear, pocket-square and badge layers.
contract StonkBrokerBodyRenderer {
    function renderBody(uint256 seed) external pure returns (string memory body, string memory badge) {
        StonkBrokerTraits.Traits memory t = StonkBrokerTraits.decode(seed);
        body = string(
            abi.encodePacked(
                _bodyForSuit(t.suit, _hex(_pickTie(t.tie)), t.neckwear), _renderPocketSquare(t.pocketSquare)
            )
        );
        badge = _renderBrokerBadge(t.brokerBadge);
    }

    function _svgBody(string memory suit, string memory tie, uint8 neckwear) internal pure returns (string memory) {
        return _svgBodyWithCollar(suit, tie, neckwear, "f0f0f0");
    }

    function _svgBodyWithCollar(string memory suit, string memory tie, uint8 neckwear, string memory collar)
        internal
        pure
        returns (string memory)
    {
        // Museum pass: bow wing flare · long-tie knot · collar V-notch
        string memory neck = neckwear == 1
            ? string(
                abi.encodePacked(
                    '<rect x="9" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="10" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="13" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="14" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="11" y="19" width="2" height="2" fill="#',
                    tie,
                    '"/>'
                )
            )
            : string(
                abi.encodePacked(
                    '<rect x="10" y="19" width="4" height="1" fill="#',
                    tie,
                    '"/><rect x="11" y="20" width="2" height="4" fill="#',
                    tie,
                    '"/>'
                )
            );

        return string(
            abi.encodePacked(
                '<rect x="4" y="18" width="16" height="6" fill="#',
                suit,
                '"/><rect x="8" y="18" width="8" height="4" fill="#',
                suit,
                '"/>',
                '<rect x="10" y="18" width="1" height="2" fill="#',
                collar,
                '"/><rect x="13" y="18" width="1" height="2" fill="#',
                collar,
                '"/><rect x="11" y="18" width="2" height="1" fill="#',
                collar,
                '"/>',
                neck,
                '<rect x="3" y="19" width="1" height="5" fill="#',
                suit,
                '"/><rect x="20" y="19" width="1" height="5" fill="#',
                suit,
                '"/>'
            )
        );
    }

    /// @dev 6 Rainbow (~1%), 7 Pink (~0.5%), 8 Red solid (~1% rare). Idx 9 strips rejected / unused.
    function _bodyForSuit(uint8 suitIdx, string memory tie, uint8 neckwear) internal pure returns (string memory) {
        if (suitIdx == 6) return _svgBodyRainbow(tie, neckwear);
        if (suitIdx == 7) return _svgBodyWithCollar("ff4d94", tie, neckwear, "ffe0ec");
        // 8 — solid crimson (same cut as commons); 9 unused
        return _svgBody(_hex(_pickSuit(suitIdx)), tie, neckwear);
    }

    function _svgBodyRainbow(string memory tie, uint8 neckwear) internal pure returns (string memory) {
        string memory neck = neckwear == 1
            ? string(
                abi.encodePacked(
                    '<rect x="9" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="10" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="13" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="14" y="19" width="1" height="1" fill="#',
                    tie,
                    '"/><rect x="11" y="19" width="2" height="2" fill="#',
                    tie,
                    '"/>'
                )
            )
            : string(
                abi.encodePacked(
                    '<rect x="10" y="19" width="4" height="1" fill="#',
                    tie,
                    '"/><rect x="11" y="20" width="2" height="4" fill="#',
                    tie,
                    '"/>'
                )
            );

        return string(
            abi.encodePacked(
                '<rect x="4" y="18" width="2" height="6" fill="#e53935"/><rect x="6" y="18" width="2" height="6" fill="#fb8c00"/>',
                '<rect x="8" y="18" width="2" height="6" fill="#fdd835"/><rect x="10" y="18" width="2" height="6" fill="#43a047"/>',
                '<rect x="12" y="18" width="2" height="6" fill="#1e88e5"/><rect x="14" y="18" width="2" height="6" fill="#3949ab"/>',
                '<rect x="16" y="18" width="2" height="6" fill="#8e24aa"/><rect x="18" y="18" width="2" height="6" fill="#d81b60"/>',
                '<rect x="10" y="18" width="1" height="2" fill="#f0f0f0"/><rect x="13" y="18" width="1" height="2" fill="#f0f0f0"/>',
                '<rect x="11" y="18" width="2" height="1" fill="#f0f0f0"/>',
                neck,
                '<rect x="3" y="19" width="1" height="5" fill="#e53935"/><rect x="20" y="19" width="1" height="5" fill="#d81b60"/>'
            )
        );
    }

    function _renderBrokerBadge(uint8 badge) internal pure returns (string memory) {
        if (badge == 0) return "";
        // Lapel pin — outer chest, clear of the tie knot (was x=14 next to tie)
        if (badge == 1) {
            return '<rect x="16" y="20" width="2" height="2" fill="#24a148"/><rect x="16" y="20" width="2" height="1" fill="#86efac"/>';
        }
        if (badge == 2) {
            return '<rect x="16" y="20" width="2" height="2" fill="#2b3fd1"/><rect x="17" y="20" width="1" height="1" fill="#8fb8ff"/>';
        }
        // Diamond Hands — facet highlight
        return '<rect x="16" y="20" width="1" height="1" fill="#a8f7ff"/><rect x="17" y="20" width="1" height="1" fill="#00e5ff"/><rect x="16" y="21" width="2" height="1" fill="#00b8cc"/>';
    }

    function _renderPocketSquare(uint8 sq) internal pure returns (string memory) {
        if (sq == 0) return "";
        string memory tip;
        string memory fold;
        if (sq == 1) {
            tip = "f5f0e6";
            fold = "e8dcc8";
        } else if (sq == 2) {
            tip = "ffffff";
            fold = "d8dce3";
        } else {
            tip = "f5d36b";
            fold = "e9bf52";
        }
        // Complete 2×2 breast pocket — mid-jacket (y=21–22), tip + fold row
        return string(
            abi.encodePacked(
                '<rect x="6" y="21" width="2" height="1" fill="#',
                tip,
                '"/><rect x="6" y="22" width="2" height="1" fill="#',
                fold,
                '"/>'
            )
        );
    }

    function _pickSuit(uint8 idx) internal pure returns (bytes3) {
        if (idx == 0) return 0x1f2328;
        if (idx == 1) return 0x1a3352; // Navy — clearer blue
        if (idx == 2) return 0x3a4a52; // Slate — cooler gray
        if (idx == 3) return 0x4a5568; // Steel — lighter separation
        if (idx == 4) return 0x4a235a;
        if (idx == 5) return 0x1f6b3a; // Forest green (replaces Dark Teal)
        if (idx == 6) return 0xe53935; // Rainbow swatch
        if (idx == 7) return 0xff4d94; // Pink
        if (idx == 8) return 0xc62828; // Red solid ~1% rare
        return 0xc62828; // unused idx 9
    }

    function _pickTie(uint8 idx) internal pure returns (bytes3) {
        if (idx == 0) return 0x4f8cff;
        if (idx == 1) return 0x24a148;
        if (idx == 2) return 0xe53935;
        if (idx == 3) return 0xf4b400;
        if (idx == 4) return 0x6f42c1;
        return 0x00a3a3;
    }

    function _hex(bytes3 data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(6);
        for (uint256 i = 0; i < 3; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
