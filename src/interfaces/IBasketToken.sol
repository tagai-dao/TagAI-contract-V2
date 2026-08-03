// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBasketToken {
    function creatorPayout() external view returns (address);

    function wbnb() external view returns (address);

    function assetCount() external view returns (uint256);

    function assetAt(uint256 index) external view returns (address asset, uint16 targetWeightBps, uint256 balance);

    function claimableHolderFees(address holder) external view returns (uint256);

    function claimHolderFeesFor(address holder) external returns (uint256 amount);
}
