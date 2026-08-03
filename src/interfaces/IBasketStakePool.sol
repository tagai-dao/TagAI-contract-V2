// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBasketStakePool {
    struct RedeemRequest {
        uint256 tokenAmount;
        uint256 claimed;
        uint256 startTime;
        uint256 endTime;
    }

    function deposit(uint256 amount) external payable;

    function withdraw(uint256 amount) external payable;

    function redeem() external;

    function claimRewards() external payable returns (uint256 communityAmount, uint256 holderFeeAmount);

    function claimNftRewards() external payable returns (uint256 amount);

    function pendingRewards(address user) external view returns (uint256);

    function pendingNftRewards() external view returns (uint256);

    function pendingHolderFees(address user) external view returns (uint256);

    function getUserStakedAmount(address user) external view returns (uint256);

    function getTotalStakedAmount() external view returns (uint256);
}
