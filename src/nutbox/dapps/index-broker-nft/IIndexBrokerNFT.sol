// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIndexBrokerNFT {
    function initialize(
        address community,
        address admin,
        address renderer,
        address ammVault,
        address indexToken,
        string calldata name,
        string calldata symbol,
        address fundsReceiver,
        uint256[] calldata thresholds,
        uint256[] calldata weights,
        uint256 communityTokenPrice,
        uint256 indexMiningActivationTokenAmount,
        uint256 recommitPrice,
        uint256 nativePrice,
        uint256 maxSupply,
        uint16 referralBps,
        bool lockWhitelistSlots,
        bool rerollEnabled,
        address[] calldata whitelistAccounts,
        uint256[] calldata whitelistAllowances,
        bytes calldata templateConfig
    ) external;

    function nftTemplateInterfaceId() external pure returns (bytes4);
    function communityToken() external view returns (address);
    function indexToken() external view returns (address);
    function indexMiningToken() external view returns (address);
    function recommitPrice() external view returns (uint256);
    function lockWhitelistSlots() external view returns (bool);
    function rerollEnabled() external view returns (bool);
    function totalWhitelistAllocation() external view returns (uint256);
    function platformFeeReceiver() external view returns (address);
    function injectIndexRewards(uint256 amount) external;
}
