// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../../../interfaces/INFTMiningRenderer.sol";

/**
 * @title BSCNFTMiningRenderer
 * @notice Black-and-gold BSC cyberpunk SVG renderer for NFTMiningPool.
 * @dev Each batch rotates through six dark-network textures. The token seed
 * controls signal placement while level, referrals and mining weight evolve the card.
 */
contract BSCNFTMiningRenderer is INFTMiningRenderer {
    using Strings for uint256;

    struct Theme {
        string accent;
        string secondary;
        string surface;
        string label;
    }

    struct Layout {
        uint256 coreX;
        uint256 coreY;
        uint256 rotation;
        uint256 orbitRadius;
        uint256 motif;
        string coreScale;
    }

    function renderSVG(RenderParams calldata params) external pure override returns (string memory) {
        Theme memory theme = _theme(params.paletteId);
        Layout memory layout = _layout(params);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="840" viewBox="0 0 600 840">',
            _defs(theme),
            '<rect width="600" height="840" rx="48" fill="#0B0E11"/>',
            '<path d="M30 106V62Q30 30 62 30H538Q570 30 570 62V778Q570 810 538 810H62Q30 810 30 778V734" fill="none" stroke="',
            theme.accent,
            '" stroke-width="3"/>',
            '<path d="M48 116V72Q48 48 72 48H528Q552 48 552 72V768Q552 792 528 792H72Q48 792 48 768V724" fill="',
            theme.surface,
            '" stroke="#2B3139" stroke-width="2"/>',
            _header(params, theme),
            _networkField(params, theme, layout),
            _miningCore(theme, layout),
            _evolution(params, theme, layout),
            _movingParticles(params, theme),
            _footer(params, theme),
            "</svg>"
        );
    }

    function _defs(Theme memory theme) private pure returns (string memory) {
        return string.concat(
            '<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="',
            theme.surface,
            '"/><stop offset="1" stop-color="#0B0E11"/></linearGradient>',
            '<linearGradient id="core" x1="0" y1="0" x2="1" y2="1"><stop stop-color="',
            theme.accent,
            '"/><stop offset="1" stop-color="',
            theme.secondary,
            '"/></linearGradient><radialGradient id="halo"><stop stop-color="',
            theme.accent,
            '" stop-opacity=".3"/><stop offset="1" stop-color="',
            theme.accent,
            '" stop-opacity="0"/></radialGradient>',
            '<pattern id="grid" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M24 0H0V24" fill="none" stroke="#848E9C" stroke-opacity=".08"/></pattern>',
            '<filter id="glow" x="-80%" y="-80%" width="260%" height="260%"><feGaussianBlur stdDeviation="6" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
            "<style>@keyframes dash{to{stroke-dashoffset:-96}}@keyframes pulse{50%{opacity:.42}}.flow{animation:dash 7s linear infinite}.pulse{animation:pulse 3.2s ease-in-out infinite}@media(prefers-reduced-motion:reduce){.flow,.pulse{animation:none}}</style></defs>"
        );
    }

    function _header(RenderParams calldata params, Theme memory theme) private pure returns (string memory) {
        return string.concat(
            '<rect x="66" y="68" width="468" height="58" rx="16" fill="#0B0E11" stroke="#2B3139"/>',
            '<path d="M82 98h18l9-15 9 15h18" fill="none" stroke="',
            theme.accent,
            '" stroke-width="5" stroke-linejoin="round"/>',
            '<text x="154" y="94" fill="#F5F5F5" font-family="monospace" font-size="15" font-weight="700" letter-spacing="2">BSC // CYBER MINING</text>',
            '<text x="154" y="113" fill="#848E9C" font-family="monospace" font-size="11" letter-spacing="1.5">',
            theme.label,
            " // BATCH ",
            uint256(params.batchId).toString(),
            '</text><text x="512" y="103" fill="',
            theme.accent,
            '" font-family="monospace" font-size="14" font-weight="700" text-anchor="end">#',
            params.tokenId.toString(),
            "</text>"
        );
    }

    function _networkField(RenderParams calldata params, Theme memory theme, Layout memory layout)
        private
        pure
        returns (string memory field)
    {
        field = string.concat(
            '<rect x="66" y="146" width="468" height="430" rx="28" fill="url(#bg)" stroke="#2B3139"/>',
            '<rect x="66" y="146" width="468" height="430" rx="28" fill="url(#grid)"/>'
        );
        field = string.concat(field, _halo(layout));
        field = string.concat(field, _largeMotif(params, theme, layout));

        uint256 nodeCount = 6 + (uint256(params.level) > 3 ? 2 : 0);
        for (uint256 i; i < nodeCount; ++i) {
            field = string.concat(field, _networkNode(params, theme, layout, i));
        }
    }

    function _halo(Layout memory layout) private pure returns (string memory) {
        return string.concat(
            '<circle cx="', layout.coreX.toString(), '" cy="', layout.coreY.toString(), '" r="196" fill="url(#halo)"/>'
        );
    }

    function _movingParticles(RenderParams calldata params, Theme memory theme)
        private
        pure
        returns (string memory particles)
    {
        for (uint256 i; i < 3; ++i) {
            particles = string.concat(particles, _movingParticle(params.seed, theme, i));
        }
    }

    function _movingParticle(uint256 seed, Theme memory theme, uint256 index) private pure returns (string memory) {
        uint256 entropy = uint256(keccak256(abi.encodePacked(seed, "moving-particle", index)));
        uint256 x1 = 92 + (entropy % 118);
        uint256 y1 = 188 + ((entropy >> 20) % 324);
        uint256 controlX = 210 + ((entropy >> 44) % 180);
        uint256 controlY = 174 + ((entropy >> 68) % 340);
        uint256 x2 = 390 + ((entropy >> 92) % 118);
        uint256 y2 = 188 + ((entropy >> 116) % 324);
        uint256 duration = 7 + ((entropy >> 140) % 9);
        uint256 delay = 1 + ((entropy >> 164) % 6);
        uint256 radius = 3 + ((entropy >> 188) % 4);
        string memory color = index % 2 == 0 ? theme.accent : theme.secondary;
        string memory path = string.concat(
            "M",
            x1.toString(),
            " ",
            y1.toString(),
            " Q",
            controlX.toString(),
            " ",
            controlY.toString(),
            " ",
            x2.toString(),
            " ",
            y2.toString()
        );
        return string.concat(
            '<path d="',
            path,
            '" fill="none" stroke="',
            color,
            '" stroke-opacity=".12" stroke-width="2" stroke-dasharray="3 13"/>',
            '<circle cx="',
            x1.toString(),
            '" cy="',
            y1.toString(),
            '" r="2" fill="',
            color,
            '" fill-opacity=".55"/><circle r="',
            radius.toString(),
            '" fill="',
            color,
            '" filter="url(#glow)"><animateMotion dur="',
            duration.toString(),
            's" begin="-',
            delay.toString(),
            's" repeatCount="indefinite" path="',
            path,
            '"/></circle>'
        );
    }

    function _networkNode(RenderParams calldata params, Theme memory theme, Layout memory layout, uint256 index)
        private
        pure
        returns (string memory)
    {
        uint256 entropy = uint256(keccak256(abi.encodePacked(params.seed, params.batchId, index)));
        uint256 x = 92 + (entropy % 416);
        uint256 y = 176 + ((entropy >> 24) % 352);
        uint256 radius = 4 + ((entropy >> 48) % 5);
        string memory color = index % 3 == 0 ? theme.secondary : theme.accent;
        return string.concat(
            '<path d="M',
            layout.coreX.toString(),
            " ",
            layout.coreY.toString(),
            "L",
            x.toString(),
            " ",
            y.toString(),
            '" stroke="',
            color,
            '" stroke-opacity=".2" stroke-width="2" stroke-dasharray="4 10"/>',
            '<circle cx="',
            x.toString(),
            '" cy="',
            y.toString(),
            '" r="',
            radius.toString(),
            '" fill="',
            color,
            '"/><circle class="pulse" cx="',
            x.toString(),
            '" cy="',
            y.toString(),
            '" r="',
            (radius + 7).toString(),
            '" fill="none" stroke="',
            color,
            '" stroke-opacity=".35"/>'
        );
    }

    function _miningCore(Theme memory theme, Layout memory layout) private pure returns (string memory) {
        return string.concat(
            '<g transform="translate(',
            layout.coreX.toString(),
            " ",
            layout.coreY.toString(),
            ')"><g transform="rotate(',
            layout.rotation.toString(),
            ')"><circle class="flow" r="',
            (layout.orbitRadius - 24).toString(),
            '" fill="none" stroke="',
            theme.accent,
            '" stroke-opacity=".42" stroke-width="3" stroke-dasharray="8 16"/><g transform="scale(',
            layout.coreScale,
            ')">',
            '<path d="M0-112 97-56 97 56 0 112-97 56-97-56Z" fill="#0B0E11" stroke="#F5F5F5" stroke-width="8"/>',
            '<path d="M0-94 81-47 81 47 0 94-81 47-81-47Z" fill="url(#core)" fill-opacity=".2" stroke="',
            theme.accent,
            '" stroke-width="3"/>',
            '<g fill="url(#core)" filter="url(#glow)"><path d="M0-58 30-28 0 2-30-28Z"/><path d="M58 0 28 30-2 0 28-30Z"/><path d="M0 58-30 28 0-2 30 28Z"/><path d="M-58 0-28-30 2 0-28 30Z"/><path d="M0-22 22 0 0 22-22 0Z"/></g>',
            '<circle r="8" fill="#F5F5F5"/></g></g></g>'
        );
    }

    function _evolution(RenderParams calldata params, Theme memory theme, Layout memory layout)
        private
        pure
        returns (string memory layers)
    {
        uint256 level = uint256(params.level);
        if (level >= 2) {
            for (uint256 i; i < 4; ++i) {
                uint256 entropy = uint256(keccak256(abi.encodePacked(params.seed, "data-block", i)));
                uint256 x = 88 + (entropy % 392);
                uint256 y = 178 + ((entropy >> 24) % 322);
                uint256 size = 26 + ((entropy >> 48) % 25);
                layers = string.concat(
                    layers,
                    '<rect x="',
                    x.toString(),
                    '" y="',
                    y.toString(),
                    '" width="',
                    size.toString(),
                    '" height="',
                    size.toString(),
                    '" rx="4" fill="#0B0E11" stroke="',
                    theme.accent,
                    '" stroke-opacity=".45" stroke-width="3"/>'
                );
            }
        }
        if (level >= 3) {
            layers = string.concat(
                layers,
                '<circle class="flow" cx="',
                layout.coreX.toString(),
                '" cy="',
                layout.coreY.toString(),
                '" r="',
                layout.orbitRadius.toString(),
                '" fill="none" stroke="',
                theme.secondary,
                '" stroke-width="5" stroke-dasharray="2 18" stroke-linecap="round"/>'
            );
        }
        if (level >= 4) {
            uint256 top = layout.coreY - layout.orbitRadius;
            uint256 bottom = layout.coreY + layout.orbitRadius;
            uint256 left = layout.coreX - layout.orbitRadius;
            uint256 right = layout.coreX + layout.orbitRadius;
            layers = string.concat(
                layers,
                '<path d="M',
                layout.coreX.toString(),
                " ",
                top.toString(),
                "V",
                (top + 34).toString(),
                "M",
                layout.coreX.toString(),
                " ",
                (bottom - 34).toString(),
                "V",
                bottom.toString(),
                "M",
                left.toString(),
                " ",
                layout.coreY.toString(),
                "H",
                (left + 34).toString(),
                "M",
                (right - 34).toString(),
                " ",
                layout.coreY.toString(),
                "H",
                right.toString(),
                '" stroke="#F5F5F5" stroke-width="8" stroke-linecap="round"/><g fill="',
                theme.accent,
                '"><circle cx="',
                layout.coreX.toString(),
                '" cy="',
                top.toString(),
                '" r="8"/><circle cx="',
                layout.coreX.toString(),
                '" cy="',
                bottom.toString(),
                '" r="8"/><circle cx="',
                left.toString(),
                '" cy="',
                layout.coreY.toString(),
                '" r="8"/><circle cx="',
                right.toString(),
                '" cy="',
                layout.coreY.toString(),
                '" r="8"/></g>'
            );
        }
        if (level >= 5) {
            layers = string.concat(
                layers,
                '<g transform="translate(',
                layout.coreX.toString(),
                " ",
                (layout.coreY - layout.orbitRadius + 18).toString(),
                ')"><g transform="rotate(',
                layout.rotation.toString(),
                ')"><path d="M-80 26 0-18l80 44-20 28L0 22-60 54Z" fill="',
                theme.secondary,
                '" fill-opacity=".35" stroke="',
                theme.secondary,
                '" stroke-width="3"/></g></g>'
            );
        }
        if (level >= 6) {
            layers = string.concat(
                layers,
                '<rect class="flow" x="78" y="158" width="444" height="396" rx="24" fill="none" stroke="',
                theme.accent,
                '" stroke-opacity=".7" stroke-width="3" stroke-dasharray="20 16"/>'
            );
        }
        if (level > 6) {
            uint256 generation = (level - 1) / 6;
            layers = string.concat(
                layers,
                '<text x="300" y="552" fill="',
                theme.accent,
                '" font-family="monospace" font-size="12" font-weight="700" text-anchor="middle" letter-spacing="4">CYBER TIER ',
                generation.toString(),
                "</text>"
            );
        }
    }

    function _footer(RenderParams calldata params, Theme memory theme) private pure returns (string memory) {
        uint256 level = uint256(params.level);
        return string.concat(
            '<text x="72" y="612" fill="#848E9C" font-family="monospace" font-size="11" letter-spacing="2">COLLECTION</text>',
            '<text x="72" y="638" fill="#F5F5F5" font-family="monospace" font-size="16" font-weight="700">',
            params.collectionName,
            '</text><rect x="66" y="660" width="468" height="92" rx="18" fill="#0B0E11" stroke="#2B3139"/>',
            _metric(88, "LEVEL", level.toString(), theme.accent),
            _metric(216, "POWER", params.miningWeight.toString(), theme.accent),
            _metric(370, "REFERRALS", params.referralCount.toString(), theme.accent),
            _progress(level, theme),
            '<text x="300" y="778" fill="#5E6673" font-family="monospace" font-size="10" text-anchor="middle" letter-spacing="3">ONCHAIN CYBER MINING // BNB SMART CHAIN</text>'
        );
    }

    function _metric(uint256 x, string memory label, string memory value, string memory accent)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '<text x="',
            x.toString(),
            '" y="690" fill="#5E6673" font-family="monospace" font-size="10" letter-spacing="1.5">',
            label,
            '</text><text x="',
            x.toString(),
            '" y="719" fill="',
            accent,
            '" font-family="monospace" font-size="18" font-weight="700">',
            value,
            "</text>"
        );
    }

    function _progress(uint256 level, Theme memory theme) private pure returns (string memory bars) {
        uint256 phase = level > 6 ? ((level - 1) % 6) + 1 : level;
        for (uint256 i; i < 6; ++i) {
            bars = string.concat(
                bars,
                '<rect x="',
                (88 + i * 25).toString(),
                '" y="735" width="18" height="4" rx="2" fill="',
                i < phase ? theme.accent : "#2B3139",
                '"/>'
            );
        }
    }

    function _layout(RenderParams calldata params) private pure returns (Layout memory layout) {
        uint256 entropy = uint256(keccak256(abi.encodePacked(params.seed, params.tokenId, params.batchId)));
        layout.coreX = 220 + (entropy % 161);
        layout.coreY = 300 + ((entropy >> 24) % 121);
        layout.rotation = (entropy >> 48) % 46;
        layout.orbitRadius = 122 + ((entropy >> 72) % 29);
        layout.motif = (entropy >> 96) % 4;

        uint256 scaleVariant = (entropy >> 120) % 3;
        if (scaleVariant == 0) layout.coreScale = ".88";
        else if (scaleVariant == 1) layout.coreScale = "1.00";
        else layout.coreScale = "1.12";
    }

    function _largeMotif(RenderParams calldata params, Theme memory theme, Layout memory layout)
        private
        pure
        returns (string memory)
    {
        uint256 entropy = uint256(keccak256(abi.encodePacked(params.seed, "large-motif")));
        uint256 x = 102 + (entropy % 250);
        uint256 y = 190 + ((entropy >> 32) % 210);
        uint256 rotation = (entropy >> 64) % 70;

        if (layout.motif == 0) {
            return string.concat(
                '<path d="M',
                x.toString(),
                " ",
                y.toString(),
                "l148 46-96 118Z",
                '" fill="',
                theme.accent,
                '" fill-opacity=".05" stroke="',
                theme.accent,
                '" stroke-opacity=".2" stroke-width="3"/>'
            );
        }
        if (layout.motif == 1) {
            return string.concat(
                '<rect x="',
                x.toString(),
                '" y="',
                y.toString(),
                '" width="188" height="96" rx="18" transform="rotate(',
                rotation.toString(),
                " ",
                x.toString(),
                " ",
                y.toString(),
                ')" fill="',
                theme.secondary,
                '" fill-opacity=".05" stroke="',
                theme.secondary,
                '" stroke-opacity=".2" stroke-width="3"/>'
            );
        }
        if (layout.motif == 2) {
            return string.concat(
                '<g transform="translate(',
                x.toString(),
                " ",
                y.toString(),
                ')" fill="none" stroke="',
                theme.accent,
                '" stroke-opacity=".18"><circle r="74" stroke-width="18"/><circle r="108" stroke-width="3" stroke-dasharray="12 18"/></g>'
            );
        }
        return string.concat(
            '<g transform="translate(',
            x.toString(),
            " ",
            y.toString(),
            ") rotate(",
            rotation.toString(),
            ')" fill="',
            theme.accent,
            '" fill-opacity=".07"><path d="M-120-18H120V18H-120Z"/><path d="M-80 36H150V54H-80Z"/></g>'
        );
    }

    function _theme(uint8 paletteId) private pure returns (Theme memory theme) {
        if (paletteId == 1) return Theme("#F0B90B", "#FFE27A", "#181A20", "NEON GRID 01");
        if (paletteId == 2) return Theme("#FFD166", "#F0B90B", "#15130D", "DARK MESH 02");
        if (paletteId == 3) return Theme("#E0A800", "#FFF0A8", "#19160B", "QUANTUM LINK 03");
        if (paletteId == 4) return Theme("#FFB000", "#FFD86B", "#17130A", "DATA VAULT 04");
        if (paletteId == 5) return Theme("#D6B84C", "#FFF2B2", "#18160F", "HASH CIRCUIT 05");
        return Theme("#F7C948", "#FFF8D6", "#121212", "ZERO DARK 06");
    }
}
