// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @dev Interface of the Nutbox Community contract.
 * Unified interface covering both internal Nutbox usage and TagAI V2 (Pump, Hook, tests).
 */
interface ICommunity {
    function poolActived(address pool) external view returns (bool);

    function getShareAcc(address pool) external view returns (uint256);

    function getCommunityToken() external view returns (address);

    function getCommittee() external view returns (address);

    function getUserDebt(address pool, address user)
        external
        view
        returns (uint256);

    function appendUserReward(
        address user,
        uint256 amount
    ) external;

    function setUserDebt(
        address user,
        uint256 debt
    ) external;

    function updatePools() external;

    /// @dev Pull accrued community-token rewards for the given pools to the caller.
    function withdrawPoolsRewards(
        address[] memory poolAddresses
    ) external payable;

    function adminAddPool(
        string memory poolName,
        uint16[] memory ratios,
        address poolFactory,
        bytes calldata meta
    ) external payable;

    function activedPools(uint256 index) external view returns (address);

    function getPoolPendingRewards(
        address poolAddress,
        address user
    ) external view returns (uint256);
}
