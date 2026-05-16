// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface of the Nutbox Community contract.
 * Covers the functions needed by TagAI V2 (Pump, Hook, tests).
 */
interface ICommunity {
    function adminAddPool(
        string memory poolName,
        uint16[] memory ratios,
        address poolFactory,
        bytes calldata meta
    ) external payable;

    function transferOwnership(address newOwner) external;

    /// @dev Pull accrued community-token rewards for the given pools to the caller.
    function withdrawPoolsRewards(
        address[] memory poolAddresses
    ) external payable;

    function getCommunityToken() external view returns (address);

    function getCommittee() external view returns (address);

    function activedPools(uint256 index) external view returns (address);
}
