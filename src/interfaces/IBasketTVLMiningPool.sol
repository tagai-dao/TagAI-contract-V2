// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "./IPool.sol";

interface IBasketTVLMiningPool is IPool {
    struct BasketStake {
        address basketCreator;
        address childPool;
        uint256 nftTokenId;
        uint256 miningAmount;
        uint256 updatedAt;
        bool exists;
    }

    function createBasketStake(address basket, uint256 nftTokenId) external returns (address childPool);

    function updateBasketStake(address basket) external;

    function getBasketStake(address basket) external view returns (BasketStake memory);

    function nftBasketPoolCount(uint256 nftTokenId) external view returns (uint256);

    function basketNavWeth(address basket) external view returns (uint256);
}
