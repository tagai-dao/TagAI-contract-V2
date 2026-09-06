// SPDX-License-Identifier: MIT
// Derived from StonkBrokerTraitsV6Proposal; see SOURCE_NOTICE.md.
pragma solidity ^0.8.24;

/// @notice Stonk Broker visual trait probabilities and deterministic seed decoder — Devil Horns (acc 7), Bull Horns (acc 10), Gold Smile mouth (~1%).
/// Same trait roll weights and dedup mechanics; new seed domain for side-by-side safety.
library StonkBrokerTraits {
    struct Traits {
        uint8 background;
        uint8 skin;
        uint8 hairStyle;
        uint8 hairColor;
        uint8 eyeColor;
        uint8 noseColor; // 0–9 five colors × Flat/Wide shape; 10 Clown Red (Wide-only) ~1%; 11 None ~10% uncommon
        uint8 mouth;
        uint8 suit;
        uint8 tie;
        uint8 neckwear;
        uint8 faceAccessory;
        uint8 brokerBadge;
        uint8 pocketSquare; // 0 none; 1 cream / 2 white / 3 gold — ~1% ultra rare
    }

    uint256 internal constant MAX_SEED_ATTEMPTS = 256;

    function candidateSeed(uint256 tokenId, uint256 attempt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("STONK_TRAIT_V6", tokenId, attempt)));
    }

    function decode(uint256 seed) internal pure returns (Traits memory t) {
        t.background = uint8(seed % 8);
        t.skin = uint8((seed / 5) % 13);
        // Hair: common 0–5 + Bald (6); Rainbow Afro (7) ~0.1% ultra rare (1/1000).
        {
            uint16 hairRoll = uint16((seed / 11) % 1000);
            if (hairRoll == 0) {
                t.hairStyle = 7; // Rainbow Afro
            } else {
                t.hairStyle = uint8((hairRoll - 1) % 7); // Classic Side..Bald
            }
        }
        t.hairColor = uint8((seed / 17) % 7);
        // Eyes: 8 standard colors (0–7); Bull Candle (8) ~1% super rare — green candlestick
        // bar eyes replacing the pupil, layered above whichever base color would have rolled.
        if ((seed / 89) % 100 == 0) {
            t.eyeColor = 8; // Bull Candle
        } else {
            t.eyeColor = uint8((seed / 23) % 8);
        }
        // Nose: 5 colors × Flat/Wide (0–9, even=Flat/odd=Wide); Clown Red Wide-only (10) ~1%;
        // None (11) ~10% fairly uncommon. Black removed.
        {
            uint8 noseRoll = uint8((seed / 31) % 100);
            if (noseRoll == 0) {
                t.noseColor = 10; // Clown Red — Wide only
            } else if (noseRoll <= 10) {
                t.noseColor = 11; // None — no nose pixels
            } else {
                t.noseColor = uint8((noseRoll - 11) % 10); // Taupe..Pink, Flat/Wide
            }
        }
        // Mouth: commons 0–5; rares Blond Beard/Mustache/Gray Beard ~3% each;
        // Gold Tooth (9) ~1% super rare — Smirk + one gold tooth pixel.
        if ((seed / 67) % 100 == 0) {
            t.mouth = 9; // Gold Tooth
        } else {
            uint8 mouthRoll = uint8((seed / 29) % 100);
            if (mouthRoll < 3) {
                t.mouth = 6; // Blond Beard
            } else if (mouthRoll < 6) {
                t.mouth = 7; // Blonde Mustache
            } else if (mouthRoll < 9) {
                t.mouth = 8; // Gray Beard
            } else {
                t.mouth = uint8((mouthRoll - 9) % 6); // Neutral..Mustache
            }
        }
        // Suit: common 0–5; Rainbow (6) ~1%; Pink (7) ~0.5%; Red solid (8) ~1% rare.
        {
            uint8 suitRoll = uint8((seed / 37) % 200);
            if (suitRoll < 2) {
                t.suit = 6; // Rainbow (super rare)
            } else if (suitRoll == 2) {
                t.suit = 7; // Pink (ultra rare)
            } else if (suitRoll <= 4) {
                t.suit = 8; // Red solid (rare) — rolls 3–4 → ~1%
            } else {
                t.suit = uint8((suitRoll - 5) % 6); // Charcoal..Forest (green)
            }
        }
        t.tie = uint8((seed / 41) % 6);
        t.neckwear = uint8((seed / 45) % 4) == 0 ? 1 : 0;
        t.brokerBadge = uint8((seed / 49) % 8);
        if (t.brokerBadge > 3) t.brokerBadge = 0;

        // Pocket square ~1% ultra rare (cream / white / gold).
        if ((seed / 53) % 100 == 0) {
            t.pocketSquare = uint8(1 + ((seed / 59) % 3));
        } else {
            t.pocketSquare = 0;
        }

        // Gold Headset / Golden Devil / Golden Bull / Gold Rims / Gold Banded Frameless — ~1% each.
        if ((seed / 61) % 100 == 0) {
            t.faceAccessory = 12;
        } else if ((seed / 73) % 100 == 0) {
            t.faceAccessory = 13; // Golden Devil Horns
        } else if ((seed / 79) % 100 == 0) {
            t.faceAccessory = 14; // Golden Bull Horns
        } else if ((seed / 71) % 100 == 0) {
            t.faceAccessory = 18; // Gold Rims
        } else if ((seed / 83) % 100 == 0) {
            t.faceAccessory = 21; // Gold Banded Frameless
        } else {
            uint8 accRoll = uint8((seed / 43) % 40);
            if (accRoll == 0) {
                t.faceAccessory = 0;
            } else if (accRoll == 1) {
                t.faceAccessory = 1;
            } else if (accRoll == 2) {
                t.faceAccessory = 2;
            } else if (accRoll == 3) {
                t.faceAccessory = 3;
            }
            // Halo (was 4) removed — horns cover that head-variation slot
            else if (accRoll == 4) {
                t.faceAccessory = 0;
            } else if (accRoll <= 10) {
                t.faceAccessory = 5; // Headset (slate, left boom)
            } else if (accRoll <= 15) {
                t.faceAccessory = 11; // Bluetooth Headset (navy, titanium boom)
            } else if (accRoll <= 17) {
                t.faceAccessory = 15; // Blue Boom Headset (navy, blue boom) — ~5%
            } else if (accRoll == 18) {
                t.faceAccessory = 6;
            } else if (accRoll == 19) {
                t.faceAccessory = 7; // Devil Horns
            } else if (accRoll == 20) {
                t.faceAccessory = 8;
            } else if (accRoll <= 23) {
                t.faceAccessory = 9; // Crown
            } else if (accRoll <= 26) {
                t.faceAccessory = 10; // Bull Horns
            } else {
                // 27–39 (13 rolls): None/glasses rotation + Banded Frameless every 5th (~6.5%)
                uint8 tailRoll = accRoll % 5;
                t.faceAccessory = tailRoll == 4 ? 19 : tailRoll; // 19 = Banded Frameless
            }
        }
    }

    function traitSignature(uint256 seed) internal pure returns (bytes32) {
        Traits memory t = decode(seed);
        return keccak256(
            abi.encodePacked(
                t.background,
                t.skin,
                t.hairStyle,
                t.hairColor,
                t.eyeColor,
                t.noseColor,
                t.mouth,
                t.suit,
                t.tie,
                t.neckwear,
                t.faceAccessory,
                t.brokerBadge,
                t.pocketSquare
            )
        );
    }

    function skinName(uint8 skin) internal pure returns (string memory) {
        if (skin <= 5) return "Human";
        if (skin == 6) return "Devil";
        if (skin == 7) return "Zombie";
        if (skin == 8) return "Robot";
        if (skin == 9) return "Marshmallow";
        if (skin == 10) return "Alien";
        if (skin == 11) return "Lemon";
        return "Shadow";
    }

    function hairStyleName(uint8 style) internal pure returns (string memory) {
        if (style == 0) return "Classic Side";
        if (style == 1) return "Long Side";
        if (style == 2) return "Wide Top";
        if (style == 3) return "Short Crop";
        if (style == 4) return "Wavy";
        if (style == 5) return "Tall";
        if (style == 6) return "Bald";
        return "Rainbow Afro"; // 7 — ultra rare
    }

    /// @notice Names for the 8 eye colors rendered by _pickEye() in the SVG renderer, plus the
    /// super-rare Bull Candle eye style (8) which is a distinct shape, not a color swatch.
    function eyeColorName(uint8 color) internal pure returns (string memory) {
        if (color == 0) return "Blue"; // 0x2b3fd1
        if (color == 1) return "Green"; // 0x4b8f29
        if (color == 2) return "Brown"; // 0x7d5534
        if (color == 3) return "Slate Gray"; // 0x5b6678
        if (color == 4) return "Teal"; // 0x1f7a8c
        if (color == 5) return "Violet"; // 0x8a4fff
        if (color == 6) return "Amber"; // 0xb5651d
        if (color == 7) return "Navy"; // 0x1d3557
        return "Bull Candle"; // 8 — ~1% super rare, green candlestick bar eyes
    }

    function hairColorName(uint8 color) internal pure returns (string memory) {
        if (color == 0) return "Jet Black";
        if (color == 1) return "Dark Brown";
        if (color == 2) return "Brown";
        if (color == 3) return "Light Brown";
        if (color == 4) return "Charcoal";
        if (color == 5) return "Gray Brown";
        return "Blonde";
    }

    /// @notice Metadata-facing Hair Color, aware of hairStyle. The raw `hairColor` roll is still
    /// decoded and stored for every token (it drives the SVG hair layer where relevant), but it
    /// is cosmetically meaningless for Bald (no hair to color) and for Rainbow Afro (multicolor,
    /// not a single swatch) — listing e.g. "Charcoal" on a Bald broker or one fixed color on a
    /// Rainbow Afro read as data glitches on marketplaces. Bald reports "None" (and is dropped
    /// from the attributes array entirely by the renderer's `_attr` helper); Rainbow Afro reports
    /// "Rainbow" instead of the underlying roll.
    function hairColorNameForMetadata(uint8 hairStyle, uint8 color) internal pure returns (string memory) {
        if (hairStyle == 6) return "None"; // Bald
        if (hairStyle == 7) return "Rainbow"; // Rainbow Afro — ultra rare
        return hairColorName(color);
    }

    function faceAccessoryName(uint8 acc) internal pure returns (string memory) {
        if (acc == 0) return "None";
        if (acc == 1) return "Rimless Glasses";
        if (acc == 2) return "Sunglasses";
        if (acc == 3) return "3D Glasses";
        if (acc == 4) return "None"; // Halo removed — index retired
        if (acc == 5) return "Headset"; // slate dual cups, left boom
        if (acc == 6) return "Monocle";
        if (acc == 7) return "Devil Horns";
        if (acc == 8) return "Eye Patch";
        if (acc == 9) return "Crown";
        if (acc == 10) return "Bull Horns";
        if (acc == 11) return "Bluetooth Headset";
        if (acc == 12) return "Gold Headset"; // super rare ~1%
        if (acc == 13) return "Golden Devil Horns"; // super rare ~1%
        if (acc == 14) return "Golden Bull Horns"; // super rare ~1%
        if (acc == 15) return "Blue Boom Headset";
        // 16 Balding Cap / 17 Top Hat — rejected
        if (acc == 18) return "Gold Rims"; // ~1%
        if (acc == 19) return "Banded Frameless"; // OG rimless + bands into hair
        // 20 Black Monocle — declined / unused
        if (acc == 21) return "Gold Banded Frameless"; // ~1% super rare
        return "None";
    }

    function tieName(uint8 tie) internal pure returns (string memory) {
        if (tie == 0) return "Blue";
        if (tie == 1) return "Green";
        if (tie == 2) return "Red";
        if (tie == 3) return "Gold";
        if (tie == 4) return "Purple";
        return "Teal";
    }

    function brokerBadgeName(uint8 badge) internal pure returns (string memory) {
        if (badge == 0) return "None";
        if (badge == 1) return "Insider";
        if (badge == 2) return "Whale";
        return "Diamond Hands";
    }

    function pocketSquareName(uint8 sq) internal pure returns (string memory) {
        if (sq == 0) return "None";
        if (sq == 1) return "Cream";
        if (sq == 2) return "White";
        return "Gold";
    }

    function noseColorName(uint8 nose) internal pure returns (string memory) {
        if (nose == 0) return "Taupe - Flat";
        if (nose == 1) return "Taupe - Wide"; // original #ba9a95 shape
        if (nose == 2) return "Light Brown - Flat";
        if (nose == 3) return "Light Brown - Wide";
        if (nose == 4) return "Brown - Flat";
        if (nose == 5) return "Brown - Wide";
        if (nose == 6) return "Dark Brown - Flat";
        if (nose == 7) return "Dark Brown - Wide";
        if (nose == 8) return "Pink - Flat";
        if (nose == 9) return "Pink - Wide";
        if (nose == 10) return "Clown Red - Wide"; // ~1% super rare, Wide-only
        return "None"; // 11 — fairly uncommon (~10%), no nose pixels
    }

    function neckwearName(uint8 neckwear) internal pure returns (string memory) {
        return neckwear == 1 ? "Bow Tie" : "Tie";
    }

    function mouthName(uint8 mouth) internal pure returns (string memory) {
        if (mouth == 0) return "Neutral";
        if (mouth == 1) return "Smirk";
        if (mouth == 2) return "Smile";
        if (mouth == 3) return "Beard";
        if (mouth == 4) return "Open";
        if (mouth == 5) return "Mustache"; // chevron
        if (mouth == 6) return "Blond Beard"; // rare: black top + blonde chinstrap
        if (mouth == 7) return "Blonde Mustache"; // rare blonde chevron
        if (mouth == 8) return "Gray Beard"; // rare: black top + gray chinstrap
        return "Gold Tooth"; // 9 — super rare Smirk + one gold tooth pixel
    }

    function suitName(uint8 suit) internal pure returns (string memory) {
        if (suit == 0) return "Charcoal";
        if (suit == 1) return "Navy";
        if (suit == 2) return "Slate";
        if (suit == 3) return "Steel";
        if (suit == 4) return "Purple";
        if (suit == 5) return "Forest";
        if (suit == 6) return "Rainbow"; // super rare
        if (suit == 7) return "Pink"; // ultra rare
        if (suit == 8) return "Red"; // solid crimson ~1% rare
        return "Red"; // 9 unused (strips rejected) — keep name safe
    }
}
