// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Base64 as SoladyBase64} from "solady/src/utils/Base64.sol";

import {IIndexBrokerNFTRenderer} from "../../src/nutbox/dapps/index-broker-nft/IIndexBrokerNFTRenderer.sol";
import {NiulaiIPFSRenderer} from "../../src/nutbox/dapps/index-broker-nft/NiulaiIPFSRenderer.sol";

contract NiulaiIPFSRendererTest is Test {
    NiulaiIPFSRenderer private renderer;

    function setUp() public {
        renderer = new NiulaiIPFSRenderer();
    }

    function test_MapsRepresentativeTokenIdsToCanonicalIPFSImages() public view {
        assertEq(renderer.imageURI(1), "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/0001.png");
        assertEq(renderer.imageURI(2), "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/0002.png");
        assertEq(
            renderer.imageURI(3_333), "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/3333.png"
        );
        assertEq(
            renderer.imageURI(6_666), "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/6666.png"
        );
    }

    function test_PadsEveryFourDigitBoundary() public view {
        assertEq(renderer.fileName(9), "0009.png");
        assertEq(renderer.fileName(10), "0010.png");
        assertEq(renderer.fileName(99), "0099.png");
        assertEq(renderer.fileName(100), "0100.png");
        assertEq(renderer.fileName(999), "0999.png");
        assertEq(renderer.fileName(1_000), "1000.png");
    }

    function test_TokenURIContainsOnchainMetadataAndCanonicalIPFSImage() public view {
        string memory json = _decodeDataURI(renderer.renderTokenURI(_params(1)));

        assertEq(vm.parseJsonString(json, ".name"), "Niulai #1");
        assertEq(vm.parseJsonString(json, ".description"), "Niulai NFT Collection");
        assertEq(
            vm.parseJsonString(json, ".image"),
            "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/0001.png"
        );
        assertEq(vm.parseJson(json, ".attributes"), abi.encode(new bytes[](0)));
        assertFalse(_contains(json, "4everland.io"));
    }

    function test_MetadataImageDependsOnlyOnTokenId() public view {
        IIndexBrokerNFTRenderer.RenderParams memory first = _params(3333);
        IIndexBrokerNFTRenderer.RenderParams memory second = _params(3333);
        second.seed = type(uint256).max;
        second.level = 99;
        second.indexMiningWeight = type(uint256).max;

        assertEq(
            vm.parseJsonString(_decodeDataURI(renderer.renderTokenURI(first)), ".image"),
            vm.parseJsonString(_decodeDataURI(renderer.renderTokenURI(second)), ".image")
        );
    }

    function test_RenderSVGUsesFileSpecificHTTPSGatewayFallback() public view {
        string memory svg = renderer.renderSVG(_params(1));

        assertTrue(_contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(
            _contains(
                svg, "https://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4.ipfs.4everland.io/0001.png"
            )
        );
        assertTrue(_contains(svg, "</svg>"));
    }

    function test_ContractURIUsesCollectionNameAndCanonicalIPFSImage() public view {
        string memory json = _decodeDataURI(renderer.renderContractURI("Niulai"));

        assertEq(vm.parseJsonString(json, ".name"), "Niulai");
        assertEq(vm.parseJsonString(json, ".description"), "Niulai NFT Collection");
        assertEq(
            vm.parseJsonString(json, ".image"),
            "ipfs://bafybeidiexi3nx3zbf6odsctmq5ym34olizubfjkbmpcrps74gzcb7lco4/0001.png"
        );
    }

    function test_RevertsForTokenIdZero() public {
        vm.expectRevert(abi.encodeWithSelector(NiulaiIPFSRenderer.InvalidTokenId.selector, 0));
        renderer.fileName(0);
    }

    function test_RevertsAboveCollectionSupply() public {
        vm.expectRevert(abi.encodeWithSelector(NiulaiIPFSRenderer.InvalidTokenId.selector, 6_667));
        renderer.renderTokenURI(_params(6_667));
    }

    function _params(uint256 tokenId) private pure returns (IIndexBrokerNFTRenderer.RenderParams memory params) {
        params = IIndexBrokerNFTRenderer.RenderParams({
            collectionName: "Niulai",
            tokenId: tokenId,
            seed: 0,
            referralCount: 0,
            referrerTokenId: 0,
            miningWeight: 1,
            indexMiningWeight: 0,
            indexMiningTokenUnit: 1 ether,
            level: 1,
            miningActive: true,
            indexMiningActive: false
        });
    }

    function _decodeDataURI(string memory uri) private pure returns (string memory) {
        bytes memory raw = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertTrue(raw.length > prefix.length);

        for (uint256 i; i < prefix.length; ++i) {
            assertEq(raw[i], prefix[i]);
        }

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
