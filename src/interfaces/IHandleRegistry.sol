// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice BSC handle NFT registry. An empty handle means the account is not registered.
interface IHandleRegistry {
    function handleOf(address account) external view returns (string memory);
}
