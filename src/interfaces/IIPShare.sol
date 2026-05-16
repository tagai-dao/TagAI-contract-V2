// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IIPShare {
    // ─── Core Functions ───────────────────────────────────────────────────────────

    function valueCapture(address subject) external payable;

    function ipshareCreated(address subject) external returns (bool);

    function createShare(address subject) external payable;

    function createFee() external view returns (uint256);

    function ipshareBalance(address subject, address holder) external view returns (uint256);

    function ipshareSupply(address subject) external view returns (uint256);

    function buyShares(address subject, address buyer, uint256 amountOutMin) external payable returns (uint256);

    function sellShares(address subject, uint256 shareAmount, uint256 amountOutMin) external;

    function getPendingProfits(address subject, address staker) external view returns (uint256);

    function getMaxStaker(address subject) external view returns (address, uint256);

    function getBuyAmountByValue(uint256 supply, uint256 ethAmount) external pure returns (uint256);

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error PendingTradeNow();
    error OnlyStaker();
    error FeePercentIsTooLarge();
    error TooMuchFee();
    error IPShareAlreadyCreated();
    error InsufficientPay();
    error RefundFail();
    error PayCreateFeeFail();
    error IPShareNotExist();
    error OutOfSlippage();
    error CostTradeFeeFail();
    error CanntSellLast10Shares();
    error UnableToSendFunds();
    error NoFunds();
    error InsufficientShares();
    error InUnstakingPeriodNow();
    error WrongAmountOrInsufficientStakeAmount();
    error NoIPShareToRedeem();
    error IPShareIsInlockingPeriodNow();
    error NoProfitToClaim();
}
