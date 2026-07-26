// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../../../interfaces/INFTMiningRenderer.sol";

/**
 * @title NFTMiningRenderer
 * @notice Shared on-chain SVG renderer for NFTMiningPool clones.
 *
 * The renderer is deployed once by NFTMiningPoolFactory and selected during
 * pool creation. Keeping SVG assembly here avoids the EIP-170 runtime code-size
 * limit while every token remains fully on-chain.
 */
contract NFTMiningRenderer is INFTMiningRenderer {
    using Strings for uint256;

    function renderSVG(RenderParams calldata params) external pure override returns (string memory) {
        uint256 level = uint256(params.level);
        (uint256 hue, uint256 accentHue) = _paletteHues(params.paletteId);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="840" viewBox="0 0 600 840">',
            _renderDefs(hue, accentHue),
            '<rect x="18" y="18" width="564" height="804" rx="54" fill="hsl(',
            hue.toString(),
            ',44%,18%)"/>',
            _renderTexture(params.paletteId, accentHue),
            '<rect x="48" y="98" width="504" height="590" rx="38" fill="hsl(',
            accentHue.toString(),
            ',28%,22%)"/>',
            _renderGeometry(params.seed, level, hue, accentHue),
            _renderHeader(params.batchId, params.paletteId),
            _renderFooter(params, hue),
            _renderBatchFrame(params.paletteId, hue),
            "</svg>"
        );
    }

    function _renderDefs(uint256 hue, uint256 accentHue) internal pure returns (string memory) {
        return string.concat(
            '<defs><pattern id="g" width="28" height="28" patternUnits="userSpaceOnUse"><path d="M28 0H0V28" fill="none" stroke="#f4f3ee" stroke-opacity=".2"/></pattern>',
            '<pattern id="d" width="20" height="20" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line y2="20" stroke="hsl(',
            accentHue.toString(),
            ',72%,56%)" stroke-width="5" stroke-opacity=".34"/></pattern>',
            '<pattern id="p" width="26" height="26" patternUnits="userSpaceOnUse"><circle cx="4" cy="4" r="2.4" fill="#f4f3ee" fill-opacity=".26"/></pattern>',
            "<style>@keyframes f{to{stroke-dashoffset:-120}}@keyframes q{50%{transform:scale(1.08)}}.signal{animation:f 7s linear infinite}.pulse{animation:q 4.8s ease-in-out infinite;transform-box:fill-box;transform-origin:center}@media(prefers-reduced-motion:reduce){.signal,.pulse{animation:none}}</style>",
            '<linearGradient id="g',
            hue.toString(),
            '"><stop stop-color="hsl(',
            hue.toString(),
            ',62%,56%)"/><stop offset="1" stop-color="hsl(',
            accentHue.toString(),
            ',62%,42%)"/></linearGradient></defs>'
        );
    }

    function _renderTexture(uint8 paletteId, uint256 accentHue) internal pure returns (string memory) {
        if (paletteId == 1) return "";
        string memory patternId = paletteId == 4 || paletteId == 6 ? "d" : paletteId == 5 ? "p" : "g";
        return string.concat(
            '<rect x="34" y="34" width="532" height="772" rx="42" fill="url(#',
            patternId,
            ')" stroke="hsl(',
            accentHue.toString(),
            ',70%,54%)" stroke-opacity=".18"/>'
        );
    }

    function _renderGeometry(uint256 seed, uint256 level, uint256 hue, uint256 accentHue)
        internal
        pure
        returns (string memory)
    {
        string memory shape = _shapePath(seed);
        string memory mirror = seed & 1 == 0 ? "" : ' transform="translate(600 0) scale(-1 1)"';
        string memory fill = level == 1 ? "none" : string.concat("url(#g", hue.toString(), ")");

        return string.concat(
            "<g",
            mirror,
            '><path d="',
            shape,
            '" fill="',
            fill,
            '" stroke="#f4f3ee" stroke-width="18" stroke-linejoin="round" stroke-linecap="round"/>',
            '<path d="',
            shape,
            '" fill="none" stroke="#17191e" stroke-width="10" stroke-linejoin="round" stroke-linecap="round"/>',
            '<path d="',
            shape,
            '" fill="none" stroke="hsl(',
            accentHue.toString(),
            ',78%,58%)" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>',
            "</g>",
            _renderNodes(seed, level, hue, accentHue),
            _renderEvolution(level, hue, accentHue)
        );
    }

    function _shapePath(uint256 seed) internal pure returns (string memory) {
        uint256 variant = seed % 4;
        if (variant == 0) {
            return "M92 154Q212 154 332 139Q416 124 500 221Q500 270 469 318Q438 484 313 650Q250 650 188 592Q188 563 140 534Q92 344 92 154Z";
        }
        if (variant == 1) {
            return "M76 150Q246 122 416 150Q520 166 484 286Q448 368 476 510Q476 624 300 650Q176 638 196 520Q76 486 92 350Q64 250 76 150Z";
        }
        if (variant == 2) {
            return
                "M112 126Q300 150 488 126Q520 250 446 318Q500 438 438 628Q300 676 162 628Q100 486 154 350Q70 250 112 126Z";
        }
        return "M84 172Q206 102 328 142Q470 100 510 238Q458 334 482 430Q470 640 288 650Q140 632 176 500Q66 430 104 328Q54 242 84 172Z";
    }

    function _renderNodes(uint256 seed, uint256 level, uint256 hue, uint256 accentHue)
        internal
        pure
        returns (string memory nodes)
    {
        uint256 count = level + 1;
        if (count > 6) count = 6;

        for (uint256 i = 0; i < count; ++i) {
            uint256 entropy = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 x = 106 + (entropy % 388);
            uint256 y = 164 + ((entropy >> 16) % 426);
            uint256 radius = 14 + ((entropy >> 32) % 18);
            uint256 nodeHue = i % 2 == 0 ? hue : accentHue;
            nodes = string.concat(
                nodes,
                '<g class="pulse"><circle cx="',
                x.toString(),
                '" cy="',
                y.toString(),
                '" r="',
                (radius + 7).toString(),
                '" fill="#f4f3ee" stroke="#17191e" stroke-width="5"/><circle cx="',
                x.toString(),
                '" cy="',
                y.toString(),
                '" r="',
                (radius / 2).toString(),
                '" fill="hsl(',
                nodeHue.toString(),
                ',82%,58%)"/></g>'
            );
        }
    }

    function _renderEvolution(uint256 level, uint256 hue, uint256 accentHue)
        internal
        pure
        returns (string memory layers)
    {
        if (level >= 3) {
            layers = string.concat(
                layers,
                '<path d="M116 246Q300 164 484 246Q430 356 484 466Q300 596 116 466Q170 356 116 246Z" fill="none" stroke="hsl(',
                accentHue.toString(),
                ',76%,58%)" stroke-width="16"/><path d="M116 246Q300 164 484 246Q430 356 484 466Q300 596 116 466Q170 356 116 246Z" fill="none" stroke="#17191e" stroke-width="7"/>'
            );
        }
        if (level >= 4) {
            layers = string.concat(
                layers,
                '<rect x="126" y="194" width="142" height="112" rx="48" fill="url(#g)" stroke="#f4f3ee" stroke-width="10"/><rect x="332" y="474" width="142" height="112" rx="48" fill="url(#d)" stroke="#f4f3ee" stroke-width="10"/>'
            );
        }
        if (level >= 5) {
            layers = string.concat(
                layers,
                '<circle cx="300" cy="378" r="82" fill="#17191e" stroke="#f4f3ee" stroke-width="16"/><circle cx="300" cy="378" r="58" fill="none" stroke="hsl(',
                hue.toString(),
                ',76%,58%)" stroke-width="6"/><circle cx="300" cy="378" r="24" fill="hsl(',
                accentHue.toString(),
                ',82%,58%)"/>'
            );
        }
        if (level >= 6) {
            layers = string.concat(
                layers,
                '<path class="signal" d="M92 140Q300 70 508 140V636Q300 704 92 636Z" fill="none" stroke="hsl(',
                accentHue.toString(),
                ',82%,62%)" stroke-width="5" stroke-dasharray="3 18"/>'
            );
        }
        if (level > 6) {
            uint256 phase = ((level - 1) % 6) + 1;
            layers = string.concat(
                layers,
                '<circle cx="252" cy="378" r="42" fill="#17191e" stroke="#f4f3ee" stroke-width="10"/><circle cx="348" cy="378" r="42" fill="#17191e" stroke="#f4f3ee" stroke-width="10"/>'
            );
            if (phase >= 2) {
                layers = string.concat(
                    layers,
                    '<ellipse class="signal" cx="300" cy="378" rx="156" ry="112" fill="none" stroke="hsl(',
                    hue.toString(),
                    ',82%,62%)" stroke-width="7" stroke-dasharray="3 20"/>'
                );
            }
            if (phase >= 3) {
                layers = string.concat(
                    layers,
                    '<rect x="82" y="122" width="436" height="526" rx="76" fill="url(#g)" fill-opacity=".36" stroke="hsl(',
                    accentHue.toString(),
                    ',82%,62%)" stroke-width="4"/>'
                );
            }
        }
    }

    function _renderHeader(uint32 batchId, uint8 paletteId) internal pure returns (string memory) {
        return string.concat(
            '<text x="74" y="78" fill="#f4f3ee" font-family="monospace" font-size="17" font-weight="700" letter-spacing="2">BATCH ',
            uint256(batchId).toString(),
            '</text><text x="526" y="78" fill="#f4f3ee" font-family="monospace" font-size="17" font-weight="700" text-anchor="end" letter-spacing="2">PALETTE ',
            uint256(paletteId).toString(),
            "</text>"
        );
    }

    function _renderFooter(RenderParams calldata params, uint256 hue) internal pure returns (string memory) {
        uint256 level = uint256(params.level);
        string memory rank = level > 6
            ? string.concat(
                "  G", _generationForLevel(params.level).toString(), " P", _phaseForLevel(params.level).toString()
            )
            : "";

        return string.concat(
            _renderProgress(level, hue),
            '<rect x="58" y="716" width="484" height="60" rx="30" fill="#17191e" stroke="#f4f3ee" stroke-width="4"/>',
            '<text x="82" y="752" fill="#f4f3ee" font-family="monospace" font-size="17" font-weight="700" letter-spacing="2">L',
            level.toString(),
            rank,
            '</text><text x="518" y="752" fill="#f4f3ee" font-family="monospace" font-size="17" font-weight="700" text-anchor="end">B',
            uint256(params.batchId).toString(),
            "  #",
            params.tokenId.toString(),
            '</text><text x="300" y="804" fill="#f4f3ee" fill-opacity=".78" font-family="monospace" font-size="13" text-anchor="middle">REF ',
            params.referralCount.toString(),
            "  /  WEIGHT ",
            params.miningWeight.toString(),
            "</text>"
        );
    }

    function _renderProgress(uint256 level, uint256 hue) internal pure returns (string memory progress) {
        uint256 phase = level > 6 ? ((level - 1) % 6) + 1 : level;
        for (uint256 i = 0; i < 6; ++i) {
            progress = string.concat(
                progress,
                '<circle cx="',
                (82 + i * 20).toString(),
                '" cy="692" r="5" fill="',
                i < phase ? string.concat("hsl(", hue.toString(), ",82%,58%)") : "#17191e",
                '" stroke="#f4f3ee" stroke-width="2"/>'
            );
        }
    }

    function _renderBatchFrame(uint8 paletteId, uint256 hue) internal pure returns (string memory) {
        string memory accent = string.concat("hsl(", hue.toString(), ",82%,58%)");
        if (paletteId == 1) {
            return string.concat(
                '<rect x="28" y="28" width="544" height="784" rx="48" fill="none" stroke="#f4f3ee" stroke-width="10"/><rect x="42" y="42" width="516" height="756" rx="38" fill="none" stroke="',
                accent,
                '" stroke-width="4"/>'
            );
        }
        if (paletteId == 2) {
            return string.concat(
                '<path d="M54 786V152Q54 48 158 48H442Q546 48 546 152V786" fill="none" stroke="#f4f3ee" stroke-width="13" stroke-linecap="round"/><circle cx="112" cy="112" r="54" fill="#17191e" stroke="',
                accent,
                '" stroke-width="8"/><circle cx="488" cy="112" r="54" fill="#17191e" stroke="#f4f3ee" stroke-width="8"/>'
            );
        }
        if (paletteId == 3) {
            return string.concat(
                '<rect x="30" y="30" width="540" height="780" rx="48" fill="none" stroke="#f4f3ee" stroke-width="8" stroke-dasharray="92 20 8 20"/><rect class="signal" x="44" y="44" width="512" height="752" rx="36" fill="none" stroke="',
                accent,
                '" stroke-width="5" stroke-dasharray="8 18"/>'
            );
        }
        if (paletteId == 4) {
            return string.concat(
                '<path d="M118 32H482L568 118V722L482 808H118L32 722V118Z" fill="none" stroke="#f4f3ee" stroke-width="12" stroke-linejoin="round"/><path d="M142 50H458M550 142V698M458 790H142M50 698V142" stroke="',
                accent,
                '" stroke-width="5" stroke-linecap="round"/>'
            );
        }
        if (paletteId == 5) {
            return string.concat(
                '<rect x="34" y="34" width="532" height="772" rx="44" fill="none" stroke="#f4f3ee" stroke-width="10"/><g fill="#17191e" stroke="',
                accent,
                '" stroke-width="8"><circle cx="54" cy="132" r="26"/><circle cx="546" cy="226" r="34"/><circle cx="54" cy="520" r="26"/><circle cx="546" cy="636" r="34"/></g>'
            );
        }
        return string.concat(
            '<path d="M76 30H524Q570 30 570 76V764Q570 810 524 810H76Q30 810 30 764V76Q30 30 76 30Z" fill="none" stroke="#f4f3ee" stroke-width="9"/><path d="M94 50H506V72H548V226H526V614H548V768H506V790H94V768H52V614H74V226H52V72H94Z" fill="none" stroke="',
            accent,
            '" stroke-width="5" stroke-linejoin="round"/>'
        );
    }

    function _paletteHues(uint8 paletteId) internal pure returns (uint256 hue, uint256 accentHue) {
        if (paletteId == 1) hue = 210;
        else if (paletteId == 2) hue = 28;
        else if (paletteId == 3) hue = 142;
        else if (paletteId == 4) hue = 322;
        else if (paletteId == 5) hue = 260;
        else hue = 184;
        accentHue = (hue + 116) % 360;
    }

    function _generationForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? (uint256(level) - 1) / 6 : 0;
    }

    function _phaseForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? ((uint256(level) - 1) % 6) + 1 : uint256(level);
    }
}
