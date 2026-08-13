// SPDX-License-Identifier: MIT
// Derived from StonkBrokerSvgRendererV6Proposal; see SOURCE_NOTICE.md.
pragma solidity ^0.8.24;

import "./StonkBrokerTraits.sol";

/// @notice Renders the Stonk Broker face, hair, eyes, nose and mouth layers.
contract StonkBrokerFaceRenderer {
    function renderFace(uint256 seed) external pure returns (string memory) {
        StonkBrokerTraits.Traits memory t = StonkBrokerTraits.decode(seed);
        return _svgFace(t, _hex(_pickSkin(t.skin)), _hex(_pickHairColor(t.hairColor)), "");
    }

    function _svgFace(
        StonkBrokerTraits.Traits memory t,
        string memory skin,
        string memory hair,
        string memory /* eye */
    )
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                _svgSkinNeck(skin, t.skin, t.hairStyle),
                _svgHair(t.hairStyle, hair),
                _eyeMarkup(t.eyeColor, _noseMarkup(t.noseColor)),
                _renderMouth(t.mouth)
            )
        );
    }

    function _svgSkinNeck(string memory skin, uint8 skinType, uint8 hairStyle) internal pure returns (string memory) {
        string memory glow = "";
        if (skinType == 10) {
            glow = '<rect x="6" y="3" width="12" height="14" fill="#59d37b" opacity="0.15"/>';
        } else if (skinType == 11) {
            glow = '<rect x="7" y="4" width="10" height="12" fill="#ffe08a" opacity="0.25"/>';
        } else if (skinType == 12) {
            glow = '<rect x="7" y="4" width="10" height="12" fill="#1a1a2e"/>';
        }
        string memory ears = hairStyle == 6
            ? string(
                abi.encodePacked(
                    '<rect x="6" y="9" width="1" height="2" fill="#',
                    skin,
                    '"/><rect x="17" y="9" width="1" height="2" fill="#',
                    skin,
                    '"/>'
                )
            )
            : "";
        return string(
            abi.encodePacked(
                glow,
                '<rect x="7" y="4" width="10" height="12" fill="#',
                skin,
                '"/><rect x="9" y="16" width="6" height="3" fill="#',
                skin,
                '"/>',
                ears
            )
        );
    }

    function _svgEyesNose(string memory eye, string memory noseMarkup) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect x="8" y="8" width="3" height="2" fill="#f4f4f4"/><rect x="13" y="8" width="3" height="2" fill="#f4f4f4"/>',
                '<rect x="9" y="8" width="1" height="1" fill="#',
                eye,
                '"/><rect x="14" y="8" width="1" height="1" fill="#',
                eye,
                '"/>',
                noseMarkup
            )
        );
    }

    /// @notice Eye markup keyed off the raw eyeColor idx (0–8) rather than a pre-resolved hex —
    /// needed because Bull Candle (8) swaps the pupil shape entirely rather than just its color,
    /// so it can't be expressed through `_pickEye`'s color table. Every render path that used to
    /// call `_svgEyesNose(_hex(_pickEye(idx)), ...)` now routes through here instead.
    function _eyeMarkup(uint8 eyeColorIdx, string memory noseMarkup) internal pure returns (string memory) {
        if (eyeColorIdx == 8) return _svgBullCandleEyes(noseMarkup);
        return _svgEyesNose(_hex(_pickEye(eyeColorIdx)), noseMarkup);
    }

    /// @notice Bull Candle eyes (~1% super rare) — each pupil becomes a tiny green candlestick
    /// (dark 1px wick over a green 1px body) in place of the flat color dot, within the exact
    /// same sclera footprint every other eye style uses (no extra canvas space needed).
    function _svgBullCandleEyes(string memory noseMarkup) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect x="8" y="8" width="3" height="2" fill="#f4f4f4"/><rect x="13" y="8" width="3" height="2" fill="#f4f4f4"/>',
                '<rect x="9" y="8" width="1" height="1" fill="#1a1a1a"/><rect x="9" y="9" width="1" height="1" fill="#2ee06a"/>',
                '<rect x="14" y="8" width="1" height="1" fill="#1a1a1a"/><rect x="14" y="9" width="1" height="1" fill="#2ee06a"/>',
                noseMarkup
            )
        );
    }

    /// @notice Full nose rect markup for a given idx, or empty string for None (idx 11 — ~10% uncommon).
    /// Each color (0–4) has a Flat (2×1) and Wide (2×2) shape; Clown Red (10) is Wide-only.
    function _noseMarkup(uint8 idx) internal pure returns (string memory) {
        if (idx == 11) return "";
        string memory fill = _hex(_noseHex(idx));
        if (_noseIsFlat(idx)) {
            return string(abi.encodePacked('<rect x="11" y="10" width="2" height="1" fill="#', fill, '"/>'));
        }
        return string(abi.encodePacked('<rect x="11" y="10" width="2" height="2" fill="#', fill, '"/>'));
    }

    /// @notice Even idx (0,2,4,6,8) = Flat shape; odd (1,3,5,7,9) = Wide; Clown Red (10) is always Wide.
    function _noseIsFlat(uint8 idx) internal pure returns (bool) {
        return idx < 10 && idx % 2 == 0;
    }

    function _noseHex(uint8 idx) internal pure returns (bytes3) {
        if (idx == 0 || idx == 1) return 0xba9a95; // Taupe
        if (idx == 2 || idx == 3) return 0xc4a484; // Light Brown
        if (idx == 4 || idx == 5) return 0x8d6e63; // Brown
        if (idx == 6 || idx == 7) return 0x5d4037; // Dark Brown
        if (idx == 8 || idx == 9) return 0xe8a0a8; // Pink
        return 0xe53935; // 10 — Clown Red (Wide-only)
    }

    function _svgHair(uint8 style, string memory hair) internal pure returns (string memory) {
        if (style == 0) {
            // Classic Side — even left/right locks
            return string(
                abi.encodePacked(
                    '<rect x="7" y="3" width="10" height="2" fill="#',
                    hair,
                    '"/><rect x="6" y="4" width="1" height="10" fill="#',
                    hair,
                    '"/><rect x="17" y="4" width="1" height="10" fill="#',
                    hair,
                    '"/><rect x="6" y="10" width="2" height="7" fill="#',
                    hair,
                    '"/><rect x="16" y="10" width="2" height="7" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 1) {
            // Long Side — equal left/right length
            return string(
                abi.encodePacked(
                    '<rect x="7" y="3" width="10" height="2" fill="#',
                    hair,
                    '"/><rect x="6" y="4" width="1" height="11" fill="#',
                    hair,
                    '"/><rect x="17" y="4" width="1" height="11" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 2) {
            return string(
                abi.encodePacked(
                    '<rect x="6" y="3" width="12" height="3" fill="#',
                    hair,
                    '"/><rect x="6" y="4" width="1" height="9" fill="#',
                    hair,
                    '"/><rect x="17" y="4" width="1" height="9" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 3) {
            return string(
                abi.encodePacked(
                    '<rect x="8" y="3" width="8" height="2" fill="#',
                    hair,
                    '"/><rect x="7" y="4" width="1" height="6" fill="#',
                    hair,
                    '"/><rect x="16" y="4" width="1" height="6" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 4) {
            return string(
                abi.encodePacked(
                    '<rect x="7" y="3" width="10" height="2" fill="#',
                    hair,
                    '"/><rect x="6" y="4" width="1" height="10" fill="#',
                    hair,
                    '"/><rect x="17" y="4" width="1" height="10" fill="#',
                    hair,
                    '"/><rect x="8" y="5" width="1" height="2" fill="#',
                    hair,
                    '"/><rect x="14" y="5" width="1" height="2" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 5) {
            return string(
                abi.encodePacked(
                    '<rect x="7" y="2" width="10" height="3" fill="#',
                    hair,
                    '"/><rect x="6" y="4" width="1" height="11" fill="#',
                    hair,
                    '"/><rect x="17" y="4" width="1" height="11" fill="#',
                    hair,
                    '"/>'
                )
            );
        }
        if (style == 6) return ""; // Bald — no hair pixels
        if (style == 7) return _svgRainbowAfroProposal(); // ultra rare flat-top rainbow
        return "";
    }

    function _renderMouth(uint8 style) internal pure returns (string memory) {
        if (style == 0) return '<rect x="10" y="13" width="4" height="1" fill="#101010"/>'; // Neutral
        if (style == 1) {
            // Smirk — original T
            return '<rect x="10" y="13" width="4" height="1" fill="#101010"/><rect x="11" y="14" width="2" height="1" fill="#101010"/>';
        }
        if (style == 2) {
            // Smile — classic U (replaces former Frown)
            return '<rect x="10" y="13" width="1" height="1" fill="#101010"/><rect x="13" y="13" width="1" height="1" fill="#101010"/><rect x="11" y="14" width="2" height="1" fill="#101010"/>';
        }
        if (style == 3) {
            // Beard — chinstrap dark
            return '<rect x="10" y="13" width="4" height="1" fill="#101010"/><rect x="9" y="14" width="1" height="2" fill="#101010"/><rect x="14" y="14" width="1" height="2" fill="#101010"/><rect x="10" y="15" width="4" height="1" fill="#101010"/>';
        }
        if (style == 4) return '<rect x="11" y="13" width="2" height="2" fill="#101010"/>'; // Open
        if (style == 5) {
            // Mustache — chevron. Wings are 2px tall (y11-12) so it stays flush against
            // both Flat (2x1, ends y10) and Wide (2x2, ends y11) noses — a fixed 1px wing
            // would leave a floating gap under the Flat nose.
            return '<rect x="9" y="11" width="1" height="2" fill="#101010"/><rect x="10" y="12" width="1" height="1" fill="#101010"/><rect x="11" y="13" width="2" height="1" fill="#101010"/><rect x="13" y="12" width="1" height="1" fill="#101010"/><rect x="14" y="11" width="1" height="2" fill="#101010"/>';
        }
        if (style == 6) {
            // Blond Beard — rare: black mouth bar + blonde chinstrap (#e8c468)
            return '<rect x="10" y="13" width="4" height="1" fill="#101010"/><rect x="9" y="14" width="1" height="2" fill="#e8c468"/><rect x="14" y="14" width="1" height="2" fill="#e8c468"/><rect x="10" y="15" width="4" height="1" fill="#e8c468"/>';
        }
        if (style == 7) {
            // Blonde Mustache — rare chevron, same taller-wing shape as idx 5. Wings are
            // blonde (#e8c468) but the center mouth-line pixel stays black, matching how
            // Blond Beard/Gray Beard keep a black mouth bar under the colored chinstrap.
            return '<rect x="9" y="11" width="1" height="2" fill="#e8c468"/><rect x="10" y="12" width="1" height="1" fill="#e8c468"/><rect x="11" y="13" width="2" height="1" fill="#101010"/><rect x="13" y="12" width="1" height="1" fill="#e8c468"/><rect x="14" y="11" width="1" height="2" fill="#e8c468"/>';
        }
        if (style == 8) {
            // Gray Beard — rare: black mouth bar + gray chinstrap (#9aa0a6)
            return '<rect x="10" y="13" width="4" height="1" fill="#101010"/><rect x="9" y="14" width="1" height="2" fill="#9aa0a6"/><rect x="14" y="14" width="1" height="2" fill="#9aa0a6"/><rect x="10" y="15" width="4" height="1" fill="#9aa0a6"/>';
        }
        if (style == 9) {
            // Gold Tooth — Smirk T + one gold pixel on the bar (super rare mouth)
            return '<rect x="10" y="13" width="2" height="1" fill="#101010"/><rect x="12" y="13" width="1" height="1" fill="#ffd700"/><rect x="13" y="13" width="1" height="1" fill="#101010"/><rect x="11" y="14" width="2" height="1" fill="#101010"/>';
        }
        return '<rect x="10" y="13" width="4" height="1" fill="#101010"/>'; // Neutral fallback
    }

    function _pickSkin(uint8 idx) internal pure returns (bytes3) {
        if (idx == 0) return 0xf1c27d;
        if (idx == 1) return 0xe0ac69;
        if (idx == 2) return 0xc68642;
        if (idx == 3) return 0x8d5524;
        if (idx == 4) return 0xffdbac;
        if (idx == 5) return 0xd9a066;
        if (idx == 6) return 0xd63f36;
        if (idx == 7) return 0x63b35f;
        if (idx == 8) return 0xa7b0ba;
        if (idx == 9) return 0xfaf8f4;
        if (idx == 10) return 0x7cf08a;
        if (idx == 11) return 0xf5d36b;
        return 0x2b2d42;
    }

    function _pickEye(uint8 idx) internal pure returns (bytes3) {
        if (idx == 0) return 0x2b3fd1;
        if (idx == 1) return 0x4b8f29;
        if (idx == 2) return 0x7d5534;
        if (idx == 3) return 0x5b6678;
        if (idx == 4) return 0x1f7a8c;
        if (idx == 5) return 0x8a4fff;
        if (idx == 6) return 0xb5651d;
        return 0x1d3557;
    }

    function _pickHairColor(uint8 idx) internal pure returns (bytes3) {
        // Distinct palette — no identical or near-identical hexes.
        if (idx == 0) return 0x111111; // Jet Black
        if (idx == 1) return 0x3e2723; // Dark Brown
        if (idx == 2) return 0x5d4037; // Brown
        if (idx == 3) return 0xb08968; // Light Brown
        if (idx == 4) return 0x607d8b; // Charcoal cool slate
        if (idx == 5) return 0x8d7b6a; // Gray Brown
        return 0xe8c468; // Blonde
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

    function _svgRainbowAfroProposal() internal pure returns (string memory) {
        // Flat-top fro: scrambled rainbow pixels (no stripe/flag bands) — bg at y=0..1
        return string(
            abi.encodePacked(
                // y=2
                '<rect x="7" y="2" width="1" height="1" fill="#2196f3"/>',
                '<rect x="8" y="2" width="1" height="1" fill="#e53935"/>',
                '<rect x="9" y="2" width="1" height="1" fill="#9c27b0"/>',
                '<rect x="10" y="2" width="1" height="1" fill="#ffeb3b"/>',
                '<rect x="11" y="2" width="1" height="1" fill="#4caf50"/>',
                '<rect x="12" y="2" width="1" height="1" fill="#ff9800"/>',
                '<rect x="13" y="2" width="1" height="1" fill="#2196f3"/>',
                '<rect x="14" y="2" width="1" height="1" fill="#e53935"/>',
                '<rect x="15" y="2" width="1" height="1" fill="#ffeb3b"/>',
                '<rect x="16" y="2" width="1" height="1" fill="#9c27b0"/>',
                // y=3
                '<rect x="7" y="3" width="1" height="1" fill="#ff9800"/>',
                '<rect x="8" y="3" width="1" height="1" fill="#4caf50"/>',
                '<rect x="9" y="3" width="1" height="1" fill="#ffeb3b"/>',
                '<rect x="10" y="3" width="1" height="1" fill="#e53935"/>',
                '<rect x="11" y="3" width="1" height="1" fill="#9c27b0"/>',
                abi.encodePacked(
                    '<rect x="12" y="3" width="1" height="1" fill="#2196f3"/>',
                    '<rect x="13" y="3" width="1" height="1" fill="#ff9800"/>',
                    '<rect x="14" y="3" width="1" height="1" fill="#4caf50"/>',
                    '<rect x="15" y="3" width="1" height="1" fill="#e53935"/>',
                    '<rect x="16" y="3" width="1" height="1" fill="#ffeb3b"/>',
                    // y=4
                    '<rect x="7" y="4" width="1" height="1" fill="#9c27b0"/>',
                    '<rect x="8" y="4" width="1" height="1" fill="#ffeb3b"/>',
                    '<rect x="9" y="4" width="1" height="1" fill="#2196f3"/>',
                    '<rect x="10" y="4" width="1" height="1" fill="#ff9800"/>',
                    '<rect x="11" y="4" width="1" height="1" fill="#e53935"/>',
                    abi.encodePacked(
                        '<rect x="12" y="4" width="1" height="1" fill="#4caf50"/>',
                        '<rect x="13" y="4" width="1" height="1" fill="#9c27b0"/>',
                        '<rect x="14" y="4" width="1" height="1" fill="#2196f3"/>',
                        '<rect x="15" y="4" width="1" height="1" fill="#ff9800"/>',
                        '<rect x="16" y="4" width="1" height="1" fill="#4caf50"/>',
                        // y=5
                        '<rect x="7" y="5" width="1" height="1" fill="#e53935"/>',
                        '<rect x="8" y="5" width="1" height="1" fill="#2196f3"/>',
                        '<rect x="9" y="5" width="1" height="1" fill="#ff9800"/>',
                        '<rect x="10" y="5" width="1" height="1" fill="#4caf50"/>',
                        '<rect x="11" y="5" width="1" height="1" fill="#ffeb3b"/>',
                        '<rect x="12" y="5" width="1" height="1" fill="#e53935"/>',
                        '<rect x="13" y="5" width="1" height="1" fill="#4caf50"/>',
                        '<rect x="14" y="5" width="1" height="1" fill="#9c27b0"/>',
                        '<rect x="15" y="5" width="1" height="1" fill="#2196f3"/>',
                        '<rect x="16" y="5" width="1" height="1" fill="#ff9800"/>'
                    )
                )
            )
        );
    }
}
