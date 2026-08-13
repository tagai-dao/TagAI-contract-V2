// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Base64 as SoladyBase64} from "solady/src/utils/Base64.sol";

import "../../src/nutbox/dapps/index-broker-nft/StonkBrokerRenderer.sol";

contract StonkBrokerRendererTest is Test {
    StonkBrokerRenderer private renderer;

    function setUp() public {
        renderer = new StonkBrokerRenderer();
    }

    function test_DeploysAndOwnsIndependentArtModules() public view {
        assertGt(address(renderer.faceRenderer()).code.length, 0);
        assertGt(address(renderer.bodyRenderer()).code.length, 0);
        assertGt(address(renderer.accessoryRenderer()).code.length, 0);
    }

    function test_UnrevealedSeedUsesPlaceholder() public view {
        IIndexBrokerNFTRenderer.RenderParams memory params = _params(0);
        assertTrue(_contains(renderer.renderSVG(params), "#f5d36b"));
        string memory json = _decodeDataURI(renderer.renderTokenURI(params));
        assertTrue(_contains(json, "Unrevealed"));
        vm.parseJson(json);
    }

    function test_RevealedSeedRendersLocalStonkArtAndAttributes() public view {
        IIndexBrokerNFTRenderer.RenderParams memory params = _params(987654321);
        string memory svg = renderer.renderSVG(params);
        assertTrue(_contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(_contains(svg, "#8dbfe8"));
        assertTrue(_contains(svg, "</svg>"));

        string memory json = _decodeDataURI(renderer.renderTokenURI(params));
        assertTrue(_contains(json, '"trait_type":"Background"'));
        assertTrue(_contains(json, '"trait_type":"Hair Style"'));
        assertTrue(_contains(json, '"Community Mining Weight","value":12000'));
        assertTrue(_contains(json, '"Index Mining Weight","value":5000000000000000000'));
        assertTrue(_contains(json, '"Index Mining Active","value":true'));
        vm.parseJson(json);
    }

    function test_ImageIsDeterminedBySeedAndIndexWeightNotOtherRenderParams() public view {
        IIndexBrokerNFTRenderer.RenderParams memory first = _params(123456789);
        IIndexBrokerNFTRenderer.RenderParams memory second = _params(123456789);
        second.tokenId = 999;
        second.level = 20;
        second.miningWeight = 999 ether;
        assertEq(keccak256(bytes(renderer.renderSVG(first))), keccak256(bytes(renderer.renderSVG(second))));
    }

    function test_IndexMiningWeightChangesBadgeAcrossFourTiers() public view {
        IIndexBrokerNFTRenderer.RenderParams memory params = _params(123456789);
        bytes32[4] memory hashes;
        uint256[4] memory weights = [uint256(50_000 ether), 500_000 ether, 5_000_000 ether, 50_000_000 ether];

        for (uint256 i; i < weights.length; ++i) {
            params.indexMiningWeight = weights[i];
            string memory svg = renderer.renderSVG(params);
            assertTrue(_contains(svg, string.concat('id="index-mining-badge" data-tier="', vm.toString(i), '"')));
            hashes[i] = keccak256(bytes(svg));
            if (i != 0) assertNotEq(hashes[i - 1], hashes[i]);
        }
    }

    function test_BadgeUsesCommunityTokenUnitForDecimals() public view {
        IIndexBrokerNFTRenderer.RenderParams memory eighteenDecimals = _params(123456789);
        eighteenDecimals.indexMiningWeight = 500_000 ether;

        IIndexBrokerNFTRenderer.RenderParams memory sixDecimals = _params(123456789);
        sixDecimals.communityTokenUnit = 1e6;
        sixDecimals.indexMiningWeight = 500_000 * 1e6;

        assertEq(
            keccak256(bytes(renderer.renderSVG(eighteenDecimals))), keccak256(bytes(renderer.renderSVG(sixDecimals)))
        );
    }

    function test_ContractURIIsFullyOnchain() public view {
        string memory json = _decodeDataURI(renderer.renderContractURI("Pixel Brokers"));
        assertTrue(_contains(json, '"name":"Pixel Brokers"'));
        assertTrue(_contains(json, "data:image/svg+xml;base64,"));
    }

    function _params(uint256 seed) private pure returns (IIndexBrokerNFTRenderer.RenderParams memory) {
        return IIndexBrokerNFTRenderer.RenderParams({
            collectionName: "Pixel Brokers",
            tokenId: 7,
            seed: seed,
            referralCount: 3,
            referrerTokenId: 2,
            miningWeight: 12_000,
            indexMiningWeight: 5 ether,
            communityTokenUnit: 1 ether,
            level: 2,
            miningActive: true,
            indexMiningActive: true
        });
    }

    function _decodeDataURI(string memory uri) private pure returns (string memory) {
        bytes memory raw = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory encoded = new bytes(raw.length - prefix.length);
        for (uint256 i; i < encoded.length; ++i) {
            encoded[i] = raw[i + prefix.length];
        }
        return string(SoladyBase64.decode(string(encoded)));
    }

    function _contains(string memory value, string memory needle) private pure returns (bool) {
        bytes memory haystack = bytes(value);
        bytes memory target = bytes(needle);
        if (target.length == 0 || target.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j; j < target.length; ++j) {
                if (haystack[i + j] != target[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
