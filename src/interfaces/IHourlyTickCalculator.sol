// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "./ICalculator.sol";

/**
 * @dev Extended calculator interface with injection capability.
 *
 * HourlyTickCalculator accepts external token injections and distributes them
 * over a 168-hour (7-day) linear vesting window, bucketed by hour.
 */
interface IHourlyTickCalculator is ICalculator {
    /// @notice Inject tokens into the community's reward pool.
    /// @dev Caller must have approved this contract to transferFrom the community token.
    ///      Tokens are transferred directly to the community contract.
    /// @param community The registered community address.
    /// @param amount The amount of community tokens to inject (must be > 0).
    function inject(address community, uint256 amount) external;

    /// @notice Query hourly reward amounts for a range of hours.
    /// @param community The community address.
    /// @param startTimestamp The start timestamp (must be hour-aligned).
    /// @param numHours Number of hours to query.
    /// @return rewards Array of per-hour reward amounts.
    function getHourlyRewards(
        address community,
        uint256 startTimestamp,
        uint256 numHours
    ) external view returns (uint256[] memory rewards);
}
