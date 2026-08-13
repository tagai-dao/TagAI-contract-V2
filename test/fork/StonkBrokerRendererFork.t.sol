// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../../src/nutbox/dapps/index-broker-nft/StonkBrokerRenderer.sol";

interface IOriginalStonkBrokerRenderer {
    function renderSvg(uint256 tokenId, uint256 traitSeed) external view returns (string memory);
}

contract StonkBrokerRendererForkTest is Test {
    address private constant ORIGINAL_RENDERER = 0x2a2fC76d9CB0E5d2bDB2Ba6b236B6e7EF264b186;

    function test_LocalRendererRetainsOriginalArtForRepresentativeSeeds() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        StonkBrokerRenderer renderer = new StonkBrokerRenderer();
        IOriginalStonkBrokerRenderer original = IOriginalStonkBrokerRenderer(ORIGINAL_RENDERER);

        uint256[5] memory seeds = [
            uint256(1),
            uint256(987654321),
            uint256(keccak256("stonk-broker-one")),
            uint256(keccak256("stonk-broker-two")),
            type(uint256).max
        ];

        for (uint256 i; i < seeds.length; ++i) {
            IIndexBrokerNFTRenderer.RenderParams memory params = _params(seeds[i]);
            string memory localSvg = renderer.renderSVG(params);
            string memory originalSvg = original.renderSvg(params.tokenId, seeds[i]);
            assertTrue(
                _startsWith(localSvg, _withoutClosingSvg(originalSvg)), "migrated base art differs from original"
            );
            assertTrue(_contains(localSvg, 'id="index-mining-badge"'), "index mining badge missing");
        }
    }

    function _params(uint256 seed) private pure returns (IIndexBrokerNFTRenderer.RenderParams memory) {
        return IIndexBrokerNFTRenderer.RenderParams({
            collectionName: "Pixel Brokers",
            tokenId: 7,
            seed: seed,
            referralCount: 0,
            referrerTokenId: 0,
            miningWeight: 0,
            indexMiningWeight: 0,
            communityTokenUnit: 1 ether,
            level: 0,
            miningActive: false,
            indexMiningActive: false
        });
    }

    function _withoutClosingSvg(string memory value) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        bytes memory result = new bytes(raw.length - 6);
        for (uint256 i; i < result.length; ++i) {
            result[i] = raw[i];
        }
        return string(result);
    }

    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory raw = bytes(value);
        bytes memory expected = bytes(prefix);
        if (raw.length < expected.length) return false;
        for (uint256 i; i < expected.length; ++i) {
            if (raw[i] != expected[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) private pure returns (bool) {
        bytes memory raw = bytes(value);
        bytes memory expected = bytes(needle);
        if (expected.length == 0 || raw.length < expected.length) return false;
        for (uint256 i; i <= raw.length - expected.length; ++i) {
            bool matches = true;
            for (uint256 j; j < expected.length; ++j) {
                if (raw[i + j] != expected[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
