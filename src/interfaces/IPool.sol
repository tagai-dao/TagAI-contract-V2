// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface of the Nutbox staking pool.
 */
interface IPool {
    function getUserStakedAmount(address user) external view returns (uint256);

    function getTotalStakedAmount() external view returns (uint256);

    function getFactory() external view returns (address);

    function getCommunity() external view returns (address);
}
