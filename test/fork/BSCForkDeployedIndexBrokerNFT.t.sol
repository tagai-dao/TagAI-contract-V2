// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {IIndexBrokerNFT} from "../../src/nutbox/dapps/index-broker-nft/IIndexBrokerNFT.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {BSCForkIndexBrokerNFT} from "./BSCForkIndexBrokerNFT.t.sol";

/// @notice Full lifecycle fork test against the production V11 Index Broker NFT deployment.
/// @dev Committee approval is applied only to forked state; no mainnet state is mutated.
contract BSCForkDeployedIndexBrokerNFT is BSCForkIndexBrokerNFT {
    address internal constant DEPLOYED_FACTORY = 0xB1708D2F3A504846a47cdB2e4Dfb48b3ea1c9b5F;
    address internal constant DEPLOYED_BURN_TEMPLATE = 0x1D875946C87a650AF2Aa5B04427D44E647a480B9;
    address internal constant DEPLOYED_STAKE_TEMPLATE = 0xc24Ff0009fF1AaD70eF8714ee32ebc8f6b7983a5;
    address internal constant DEPLOYED_AMM_TEMPLATE = 0x698680412e34db49CdBa62c46a0Faad31D05ce0A;
    address internal constant DEPLOYED_RENDERER = 0xd4B6120f566CDecD88b7Be6f994a6c7493F8a068;
    address internal constant DEPLOYED_NUTBOX_ROUTER = 0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f;

    function _indexBrokerFactory() internal override returns (IndexBrokerNFTFactory factory) {
        factory = IndexBrokerNFTFactory(DEPLOYED_FACTORY);
        assertEq(factory.defaultRenderer(), DEPLOYED_RENDERER, "deployed Renderer");
        assertEq(factory.ammTemplate(), DEPLOYED_AMM_TEMPLATE, "deployed AMM template");
        assertEq(factory.nutboxRouter(), DEPLOYED_NUTBOX_ROUTER, "deployed NutboxRouter");
        assertEq(factory.nftTemplateCount(), 2, "deployed template count");
        assertEq(factory.nftTemplateAt(0), DEPLOYED_BURN_TEMPLATE, "deployed Burn template");
        assertEq(factory.nftTemplateAt(1), DEPLOYED_STAKE_TEMPLATE, "deployed Stake template");
        assertEq(
            IIndexBrokerNFT(DEPLOYED_BURN_TEMPLATE).nftTemplateInterfaceId(),
            IIndexBrokerNFT.initialize.selector,
            "Burn template interface"
        );
        assertEq(
            IIndexBrokerNFT(DEPLOYED_STAKE_TEMPLATE).nftTemplateInterfaceId(),
            IIndexBrokerNFT.initialize.selector,
            "Stake template interface"
        );

        if (!factory.supportedPump(address(pump))) {
            vm.prank(factory.owner());
            factory.addPump(address(pump));
        }

        if (!ICommittee(COMMITTEE).verifyContract(DEPLOYED_FACTORY)) {
            vm.prank(Ownable(COMMITTEE).owner());
            ICommittee(COMMITTEE).adminAddContract(DEPLOYED_FACTORY);
        }
    }
}
