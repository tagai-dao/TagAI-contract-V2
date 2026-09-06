// SPDX-License-Identifier: MIT
// Derived from StonkBrokerSvgRendererV6Proposal; see SOURCE_NOTICE.md.
pragma solidity ^0.8.24;

import "./StonkBrokerTraits.sol";

/// @notice Renders glasses, headsets, horns, crowns and other face-accessory layers.
contract StonkBrokerAccessoryRenderer {
    function renderAccessory(uint256 seed) external pure returns (string memory) {
        StonkBrokerTraits.Traits memory t = StonkBrokerTraits.decode(seed);
        return _renderFaceAccessoryForHair(t.faceAccessory, t.hairStyle);
    }

    function _renderFaceAccessory(uint8 acc) internal pure returns (string memory) {
        if (acc == 0) return "";
        if (acc == 1) {
            // Rimless Glasses — crisp hollow wire frames (no stroke AA) + temple stubs
            return string(
                abi.encodePacked(
                    '<rect x="8" y="7" width="3" height="1" fill="#c5d0dc"/><rect x="8" y="9" width="3" height="1" fill="#c5d0dc"/>',
                    '<rect x="8" y="8" width="1" height="1" fill="#c5d0dc"/><rect x="10" y="8" width="1" height="1" fill="#c5d0dc"/>',
                    '<rect x="13" y="7" width="3" height="1" fill="#c5d0dc"/><rect x="13" y="9" width="3" height="1" fill="#c5d0dc"/>',
                    '<rect x="13" y="8" width="1" height="1" fill="#c5d0dc"/><rect x="15" y="8" width="1" height="1" fill="#c5d0dc"/>',
                    '<rect x="11" y="8" width="2" height="1" fill="#aeb8c4"/>',
                    '<rect x="7" y="8" width="1" height="1" fill="#aeb8c4"/><rect x="16" y="8" width="1" height="1" fill="#aeb8c4"/>'
                )
            );
        }
        if (acc == 2) {
            // Sunglasses — opaque lenses, chrome bridge, temple stubs
            return string(
                abi.encodePacked(
                    '<rect x="8" y="7" width="3" height="2" fill="#0a0c10"/><rect x="13" y="7" width="3" height="2" fill="#0a0c10"/>',
                    '<rect x="8" y="7" width="3" height="1" fill="#1c222a"/><rect x="13" y="7" width="3" height="1" fill="#1c222a"/>',
                    '<rect x="11" y="7" width="2" height="1" fill="#5a6570"/>',
                    '<rect x="7" y="7" width="1" height="1" fill="#2a3038"/><rect x="16" y="7" width="1" height="1" fill="#2a3038"/>'
                )
            );
        }
        if (acc == 3) {
            // 3D Glasses — anaglyph lenses + white bridge + temple stubs
            return string(
                abi.encodePacked(
                    '<rect x="8" y="7" width="3" height="2" fill="#c62828"/><rect x="13" y="7" width="3" height="2" fill="#1565c0"/>',
                    '<rect x="11" y="7" width="2" height="1" fill="#eceff4"/>',
                    '<rect x="7" y="7" width="1" height="1" fill="#cfd3da"/><rect x="16" y="7" width="1" height="1" fill="#cfd3da"/>'
                )
            );
        }
        if (acc == 4) {
            // Halo removed — horns cover that headwear variation
            return "";
        }
        if (acc == 5) {
            // Headset — left cup + left boom (museum dual-cup revert)
            return '<rect x="5" y="8" width="2" height="3" fill="#7f8ea3"/><rect x="5" y="7" width="3" height="1" fill="#cfd8e3"/><rect x="6" y="10" width="1" height="2" fill="#cfd8e3"/><rect x="6" y="11" width="3" height="1" fill="#cfd8e3"/><rect x="9" y="11" width="1" height="1" fill="#7f8ea3"/>';
        }
        if (acc == 6) {
            // Monocle — crisp right-eye wire + brass drop chain
            return string(
                abi.encodePacked(
                    '<rect x="13" y="7" width="3" height="1" fill="#c5d0dc"/><rect x="13" y="9" width="3" height="1" fill="#c5d0dc"/>',
                    '<rect x="13" y="8" width="1" height="1" fill="#c5d0dc"/><rect x="15" y="8" width="1" height="1" fill="#c5d0dc"/>',
                    '<rect x="14" y="8" width="1" height="1" fill="#d8e1ea"/>',
                    '<rect x="16" y="8" width="1" height="1" fill="#c9a227"/>',
                    '<rect x="16" y="9" width="1" height="1" fill="#e9bf52"/><rect x="16" y="10" width="1" height="1" fill="#c9a227"/>'
                )
            );
        }
        if (acc == 7) {
            // Devil Horns — small hooked curl (anchors at hairline, sweeps out, curls back
            // to a point) so the silhouette reads as a curved horn, not a straight sweep
            // like Bull Horns. Blood curl colorway (approved): near-black stalk -> crimson tip.
            return string(
                abi.encodePacked(
                    '<rect x="6" y="4" width="1" height="1" fill="#141010"/>',
                    '<rect x="5" y="3" width="1" height="1" fill="#0c0a0a"/>',
                    '<rect x="5" y="2" width="1" height="1" fill="#080606"/>',
                    '<rect x="6" y="1" width="1" height="1" fill="#4a0a0a"/>',
                    '<rect x="6" y="0" width="1" height="1" fill="#c62828"/>',
                    '<rect x="17" y="4" width="1" height="1" fill="#141010"/>',
                    '<rect x="18" y="3" width="1" height="1" fill="#0c0a0a"/>',
                    '<rect x="18" y="2" width="1" height="1" fill="#080606"/>',
                    '<rect x="17" y="1" width="1" height="1" fill="#4a0a0a"/>',
                    '<rect x="17" y="0" width="1" height="1" fill="#c62828"/>'
                )
            );
        }
        if (acc == 8) {
            // Eye Patch — full left-eye cover (whites are y=8–9) + face-only brow strap
            // Skin is x=7..16; hair columns sit at x=6 / x=17 — strap stays on skin.
            return string(
                abi.encodePacked(
                    '<rect x="7" y="7" width="10" height="1" fill="#1a1e24"/>',
                    '<rect x="8" y="7" width="3" height="3" fill="#0a0c10"/>'
                )
            );
        }
        if (acc == 9) {
            // Crown — Centered Five Ruby (locked): hair-aligned band + ruby @ 11–12
            return _svgCrown(false, false);
        }
        if (acc == 10) {
            // Bull Horns — full ivory curve (approved colorway C)
            return string(
                abi.encodePacked(
                    '<rect x="5" y="4" width="2" height="1" fill="#8d6e63"/>',
                    '<rect x="4" y="3" width="2" height="1" fill="#bcaaa4"/>',
                    '<rect x="3" y="2" width="2" height="1" fill="#e8dcc8"/>',
                    '<rect x="2" y="1" width="1" height="1" fill="#fff8e7"/>',
                    '<rect x="17" y="4" width="2" height="1" fill="#8d6e63"/>',
                    '<rect x="18" y="3" width="2" height="1" fill="#bcaaa4"/>',
                    '<rect x="19" y="2" width="2" height="1" fill="#e8dcc8"/>',
                    '<rect x="21" y="1" width="1" height="1" fill="#fff8e7"/>'
                )
            );
        }
        if (acc == 11) {
            // Bluetooth Headset — navy cups + titanium boom (right); no LED cyan
            return string(
                abi.encodePacked(
                    '<rect x="5" y="8" width="2" height="3" fill="#1a2433"/><rect x="5" y="7" width="3" height="1" fill="#2b3a4d"/>',
                    '<rect x="17" y="8" width="2" height="3" fill="#1a2433"/><rect x="16" y="7" width="3" height="1" fill="#2b3a4d"/>',
                    '<rect x="17" y="10" width="1" height="2" fill="#8a96a5"/><rect x="15" y="11" width="3" height="1" fill="#9aa8b5"/>',
                    '<rect x="14" y="11" width="1" height="1" fill="#b8c0cb"/>'
                )
            );
        }
        if (acc == 12) {
            // Gold Headset — same left-boom silhouette as Headset, gold finish (~1% super rare)
            return '<rect x="5" y="8" width="2" height="3" fill="#c9a227"/><rect x="5" y="7" width="3" height="1" fill="#f5d36b"/><rect x="6" y="10" width="1" height="2" fill="#e9bf52"/><rect x="6" y="11" width="3" height="1" fill="#f5d36b"/><rect x="9" y="11" width="1" height="1" fill="#ffe08a"/>';
        }
        if (acc == 13) {
            // Golden Devil Horns — solid gold stalk (#f5d36b), red tip kept (~1% super rare)
            return string(
                abi.encodePacked(
                    '<rect x="6" y="4" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="5" y="3" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="5" y="2" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="6" y="1" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="6" y="0" width="1" height="1" fill="#c62828"/>',
                    '<rect x="17" y="4" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="18" y="3" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="18" y="2" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="17" y="1" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="17" y="0" width="1" height="1" fill="#c62828"/>'
                )
            );
        }
        if (acc == 14) {
            // Golden Bull Horns — same wide outward curve, gold gradient (matches Gold Headset finish, ~1% super rare)
            return string(
                abi.encodePacked(
                    '<rect x="5" y="4" width="2" height="1" fill="#c9a227"/>',
                    '<rect x="4" y="3" width="2" height="1" fill="#e9bf52"/>',
                    '<rect x="3" y="2" width="2" height="1" fill="#f5d36b"/>',
                    '<rect x="2" y="1" width="1" height="1" fill="#ffe08a"/>',
                    '<rect x="17" y="4" width="2" height="1" fill="#c9a227"/>',
                    '<rect x="18" y="3" width="2" height="1" fill="#e9bf52"/>',
                    '<rect x="19" y="2" width="2" height="1" fill="#f5d36b"/>',
                    '<rect x="21" y="1" width="1" height="1" fill="#ffe08a"/>'
                )
            );
        }
        if (acc == 15) {
            // Blue Boom Headset — single right cup + blue boom (not dual-cup)
            return string(
                abi.encodePacked(
                    '<rect x="17" y="8" width="2" height="3" fill="#1a2433"/><rect x="16" y="7" width="3" height="1" fill="#2b3a4d"/>',
                    '<rect x="17" y="10" width="1" height="2" fill="#1e5fd9"/><rect x="15" y="11" width="3" height="1" fill="#2b76ff"/>',
                    '<rect x="14" y="11" width="1" height="1" fill="#7fb4ff"/>'
                )
            );
        }
        if (acc == 16) {
            // Balding Cap — rejected
            return "";
        }
        if (acc == 17) {
            // Top Hat — rejected
            return "";
        }
        if (acc == 18) {
            // Gold Rims — rimless silhouette in Gold Headset finish (~1%)
            return string(
                abi.encodePacked(
                    '<rect x="8" y="7" width="3" height="1" fill="#f5d36b"/><rect x="8" y="9" width="3" height="1" fill="#e9bf52"/>',
                    '<rect x="8" y="8" width="1" height="1" fill="#f5d36b"/><rect x="10" y="8" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="13" y="7" width="3" height="1" fill="#f5d36b"/><rect x="13" y="9" width="3" height="1" fill="#e9bf52"/>',
                    '<rect x="13" y="8" width="1" height="1" fill="#f5d36b"/><rect x="15" y="8" width="1" height="1" fill="#f5d36b"/>',
                    '<rect x="11" y="8" width="2" height="1" fill="#ffe08a"/>',
                    '<rect x="7" y="8" width="1" height="1" fill="#c9a227"/><rect x="16" y="8" width="1" height="1" fill="#c9a227"/>'
                )
            );
        }
        if (acc == 19) {
            // Banded Frameless — OG stroke rimless + temple bands ending at hair
            // Default (most hairstyles): hair columns sit at x=6 / x=17.
            return _svgBandedFrameless(0, "d8e1ea");
        }
        if (acc == 21) {
            // Gold Banded Frameless — same silhouette, gold finish (~1% super rare)
            return _svgBandedFrameless(0, "f5d36b");
        }
        // 20 Black Monocle — declined
        return "";
    }

    function _svgBandedFrameless(uint8 bandMode, string memory col) internal pure returns (string memory) {
        string memory frames = string(
            abi.encodePacked(
                '<rect x="8" y="7" width="3" height="3" fill="none" stroke="#',
                col,
                '" stroke-width="0.4"/>',
                '<rect x="13" y="7" width="3" height="3" fill="none" stroke="#',
                col,
                '" stroke-width="0.4"/>',
                '<rect x="11" y="8" width="2" height="1" fill="#',
                col,
                '"/>'
            )
        );
        if (bandMode == 2) return frames;
        if (bandMode == 1) {
            // Short Crop — only 1px of skin between lens and hair; band ends flush with hair.
            return string(
                abi.encodePacked(
                    frames,
                    '<rect x="7" y="8" width="1" height="1" fill="#',
                    col,
                    '"/><rect x="16" y="8" width="1" height="1" fill="#',
                    col,
                    '"/>'
                )
            );
        }
        return string(
            abi.encodePacked(
                frames,
                '<rect x="6" y="8" width="2" height="1" fill="#',
                col,
                '"/><rect x="16" y="8" width="2" height="1" fill="#',
                col,
                '"/>'
            )
        );
    }

    function _renderFaceAccessoryForHair(uint8 acc, uint8 hairStyle) internal pure returns (string memory) {
        if (acc == 9 && hairStyle == 6) return _svgCrown(true, false);
        if (acc == 9 && hairStyle == 7) return _svgCrown(false, true);
        if (acc == 19 || acc == 21) {
            string memory col = acc == 21 ? "f5d36b" : "d8e1ea";
            if (hairStyle == 3) return _svgBandedFrameless(1, col); // Short Crop
            if (hairStyle == 6 || hairStyle == 7) return _svgBandedFrameless(2, col); // Bald / Rainbow Afro
        }
        return _renderFaceAccessory(acc);
    }

    function _svgCrown(bool bald, bool afro) internal pure returns (string memory) {
        if (afro) {
            return '<rect x="8" y="0" width="1" height="1" fill="#ffe08a"/><rect x="10" y="0" width="1" height="1" fill="#ffe08a"/><rect x="11" y="0" width="2" height="1" fill="#c62828"/><rect x="13" y="0" width="1" height="1" fill="#ffe08a"/><rect x="15" y="0" width="1" height="1" fill="#ffe08a"/><rect x="7" y="1" width="10" height="1" fill="#f5d36b"/>';
        }
        if (bald) {
            return '<rect x="8" y="1" width="1" height="1" fill="#ffe08a"/><rect x="10" y="1" width="1" height="1" fill="#ffe08a"/><rect x="11" y="1" width="2" height="1" fill="#c62828"/><rect x="13" y="1" width="1" height="1" fill="#ffe08a"/><rect x="15" y="1" width="1" height="1" fill="#ffe08a"/><rect x="7" y="2" width="10" height="1" fill="#f5d36b"/><rect x="8" y="3" width="8" height="1" fill="#e9bf52"/>';
        }
        return '<rect x="8" y="0" width="1" height="1" fill="#ffe08a"/><rect x="10" y="0" width="1" height="1" fill="#ffe08a"/><rect x="11" y="0" width="2" height="1" fill="#c62828"/><rect x="13" y="0" width="1" height="1" fill="#ffe08a"/><rect x="15" y="0" width="1" height="1" fill="#ffe08a"/><rect x="7" y="1" width="10" height="1" fill="#f5d36b"/><rect x="8" y="2" width="8" height="1" fill="#e9bf52"/>';
    }
}
