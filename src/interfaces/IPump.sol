// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IPump {
    // ─── Errors ──────────────────────────────────────────────────────────────────

    error TickHasBeenCreated();
    error SaltNotAvailable();
    error CantBeZeroAddress();
    error CantSetSocialDistributionMoreThanTotalSupply();
    error TooMuchFee();
    error InsufficientCreateFee();
    error TokenNotCreated();
    error PreMineTokenFail();
    error RefundFail();
    error TokenNotListed();
    error NutboxNotConfigured();

    // ─── Events ──────────────────────────────────────────────────────────────────

    event NewToken(string tick, address indexed token, address indexed creator);
    event NutboxLinked(address indexed token, address indexed community);
    event NutboxStakingPoolLinked(
        address indexed token, address indexed pool, address indexed lpToken, uint16 rewardRatio
    );
    event NutboxAllocationParked(address indexed token, address indexed hook, uint256 amount);
    event IPShareChanged(address indexed oldIPShare, address indexed newIPShare);
    event CreateFeeChanged(uint256 indexed oldFee, uint256 indexed newFee);
    event FeeAddressChanged(address indexed oldAddress, address indexed newAddress);
    event FeeRatiosChanged(uint256 indexed donutFee, uint256 indexed sellsmanFee);
    event ConstituentApprovalSet(address indexed asset, bool approved);

    // ─── View Functions ──────────────────────────────────────────────────────────

    function createdTokens(address token) external view returns (bool);

    function getFeeReceiver() external view returns (address);

    function getFeeRatio() external view returns (uint256[2] memory);

    function getHookAddress() external view returns (address);

    function getCalculator() external view returns (address);

    function getIPShare() external view returns (address);

    function getPoolManager() external view returns (address);

    function getVault() external view returns (address);

    function approvedConstituent(address asset) external view returns (bool);

    // ─── State-Changing Functions ────────────────────────────────────────────────

    function createToken(string calldata tick, bytes32 salt) external payable returns (address);

    function adminSetConstituentApproval(address asset, bool approved) external;

    struct IndexConfig {
        string name;
        string symbol;
        address[] constituentAssets; // Pump13 creation accepts 1–4 assets.
        uint16[] targetWeights;
        uint16 basketFeeBps;
        uint16 creatorShareBps;
        bool retainCommunityOwnership;
    }

    event IndexInfrastructureChanged(
        address indexed nutboxRouter,
        address indexed basketHookV4,
        address indexed pancakeV2Factory,
        address settlementToken
    );
    event ListingSwapSlippageChanged(uint16 previousBps, uint16 newBps);
    event ListingKeeperChanged(address indexed previousKeeper, address indexed newKeeper);
    event BuybackRouterChanged(address indexed previousRouter, address indexed newRouter);
    event IndexConfigured(
        address indexed token,
        string name,
        string symbol,
        address[] constituentAssets,
        uint16[] targetWeights,
        uint16 basketFeeBps,
        uint16 creatorShareBps,
        bool retainCommunityOwnership
    );
    event IndexTokenCreated(address indexed token, address indexed indexToken, address indexed creator);
    event FailedListingRecovered(address indexed token);

    error IndexConfigRequired();
    error InvalidIndexConfig();
    error IndexInfrastructureNotConfigured();
    error OnlyCreatedToken();
    error ListingAlreadyFinalized();
    error OnlyListingKeeper();
    error InvalidBuybackRouter();

    function nutboxRouter() external view returns (address);
    function basketHookV4() external view returns (address);
    function pancakeV2Factory() external view returns (address);
    function settlementToken() external view returns (address);
    function listingSwapSlippageBps() external view returns (uint16);
    function listingKeeper() external view returns (address);
    function buybackRouter() external view returns (address);
    function indexTokenOf(address token) external view returns (address);

    function createToken(string calldata tick, bytes32 salt, IndexConfig calldata indexConfig)
        external
        payable
        returns (address);

    function finalizeTokenListing() external returns (address indexToken);
    function finalizeTokenListing(address token, uint256[] calldata componentMinOuts, uint256 deadline)
        external
        returns (address indexToken);
    function adminRecoverFailedListing(address token) external;
}
