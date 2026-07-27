// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "./IPool.sol";

interface IBasketTVLMiningPool is IPool {
    struct BasketStake {
        address owner;
        address childPool;
        uint256 miningAmount;
        uint256 updatedAt;
        bool exists;
    }

    function createBasketStake(address basket) external returns (address childPool);

    function updateBasketStake(address basket) external;

    function getBasketStake(address basket) external view returns (BasketStake memory);

    function basketNavWeth(address basket) external view returns (uint256);
}
