// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBasketRegistry {
    function isBasket(address basket) external view returns (bool);
}
