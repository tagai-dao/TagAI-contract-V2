// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface of the Nutbox CommunityFactory.
 * Creates Community clone instances with a specified reward calculator.
 */
interface ICommunityFactory {
    function createCommunity(
        bool isMintable,
        address communityToken,
        address communityTokenFactory,
        bytes calldata tokenMeta,
        address rewardCalculator,
        bytes calldata distributionPolicy
    ) external payable returns (address community);
}
