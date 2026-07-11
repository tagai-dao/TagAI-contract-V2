// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @title IImportHelper
/// @notice Minimal interface consumed by TagAISwapWrapper for sellsman resolution.
interface IImportHelper {
    function importerOf(address token) external view returns (address);
}
