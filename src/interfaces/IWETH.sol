// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Minimal WETH interface for wrap/unwrap in V3/V4 sell paths.
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256) external;

    function transfer(address to, uint256 value) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
