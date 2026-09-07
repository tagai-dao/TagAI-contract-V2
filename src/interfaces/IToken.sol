// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPump} from "./IPump.sol";

interface IToken {
    // ─── Errors ──────────────────────────────────────────────────────────────────

    error TokenNotListed();
    error TokenListed();
    error IPShareNotCreated();
    error OnlyIPShareOwner();
    error IPShareAlreadySet();
    error ZeroIPShareSubject();
    error TokenInitialized();
    error ClaimOrderExist();
    error InvalidClaimAmount();
    error OutOfSlippage();
    error InsufficientFund();
    error RefundFail();
    error CostFeeFail();
    error DustIssue();
    error ListingDisabledDuringAntiSnipe();
    error TokenListingPending();
    error TokenNotListingPending();
    error ListingDeadlineExpired();
    error InvalidComponentMinOuts();
    error IndexTokenNotReady();
    error NoEligibleRewardSupply();
    error InvalidRewardAmount();

    // ─── Events ──────────────────────────────────────────────────────────────────

    event Trade(
        address indexed buyer,
        address indexed sellsman,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tiptagFee,
        uint256 sellsmanFee
    );

    event TokenListedToDex(address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96);
    event TokenListingQueued(address indexed token);

    event AntiSnipeInjected(address indexed token, address indexed community, uint256 ethUsed, uint256 tokensPurchased);

    /// @notice Emitted when the community token fee subject (IPShare owner) is transferred.
    event IPShareSubjectTransferred(address indexed previousSubject, address indexed newSubject);

    /// @notice Emitted when listing LP fees are collected and routed.
    event ListingFeesCollected(address indexed caller, uint256 bnbAmount, uint256 tokenAmount, uint256 callerReward);
    event BuybackRewardNotified(address indexed indexToken, uint256 amount, uint256 accRewardPerToken);
    event BuybackRewardClaimed(address indexed caller, address indexed account, uint256 amount);
    event ComponentPoolTaxBurned(
        address indexed pair, address indexed from, address indexed to, uint256 grossAmount, uint256 taxAmount
    );

    // ─── View Functions ──────────────────────────────────────────────────────────

    function nutboxCommunity() external view returns (address);

    function NUTBOX_ALLOCATION() external view returns (uint256);

    function listed() external view returns (bool);

    function listingPending() external view returns (bool);

    function getIPShare() external view returns (address);

    function ipshareSubject() external view returns (address);

    /// @notice Collect accrued native LP fees from the locked listing position and route proceeds.
    function collectFees() external returns (uint256 bnbAmount, uint256 tokenAmount);

    function finalizeListing(uint256[] calldata componentMinOuts, uint256 deadline) external returns (address);
    function recoverFailedListing() external;
    function notifyBuybackReward(uint256 amount) external;
    function claimBuybackReward(address account) external returns (uint256 amount);
    function pendingBuybackReward(address account) external view returns (uint256 amount);
    function accIndexRewardPerToken() external view returns (uint256);

    function initializeIndex(
        address pump,
        address creator,
        address v2Factory,
        address router,
        address basketHook,
        address settlement,
        address hook,
        IPump.IndexConfig calldata config
    ) external;

    function indexCreator() external view returns (address);
    function pancakeV2Factory() external view returns (address);
    function indexName() external view returns (string memory);
    function indexSymbol() external view returns (string memory);
    function basketFeeBps() external view returns (uint16);
    function creatorShareBps() external view returns (uint16);
    function indexToken() external view returns (address);
    function listingHook() external view returns (address);
    function listingInfrastructure()
        external
        view
        returns (address router, address basketHook, address settlement, address poolManager);
    function listingPoolParameters() external view returns (bytes32);
    function LISTING_LP_FEE() external view returns (uint24);
    function COMPONENT_POOL_TAX_BPS() external view returns (uint256);
    function componentListingNativeBudget() external view returns (uint256);

    function componentCount() external view returns (uint256);
    function componentAt(uint256 index) external view returns (address asset, uint16 weight, address pair);
}
