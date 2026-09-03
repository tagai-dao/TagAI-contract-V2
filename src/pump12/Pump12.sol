// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Pump12
/// @notice Pump12 工厂骨架。Task 0 只冻结 Robinhood 基础设施门禁。
contract Pump12 {
    uint256 public constant RH_CHAIN_ID = 4663;
    uint8 public constant USDG_DECIMALS = 6;
    address public constant CANONICAL_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant CANONICAL_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    error UnsupportedChain(uint256 actualChainId);
    error InvalidUsdG(address actual);
    error UsdGHasNoCode(address target);
    error InvalidUsdGDecimals(uint8 actualDecimals);
    error InvalidPoolManager(address actual);
    error PoolManagerHasNoCode(address target);
    error TaskNotImplemented();

    address public immutable usdg;
    address public immutable poolManager;

    constructor(address usdg_, address poolManager_) {
        if (block.chainid != RH_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (usdg_ != CANONICAL_USDG) revert InvalidUsdG(usdg_);
        if (usdg_.code.length == 0) revert UsdGHasNoCode(usdg_);

        uint8 actualDecimals;
        try IERC20Metadata(usdg_).decimals() returns (uint8 decimals_) {
            actualDecimals = decimals_;
        } catch {
            revert InvalidUsdGDecimals(type(uint8).max);
        }
        if (actualDecimals != USDG_DECIMALS) revert InvalidUsdGDecimals(actualDecimals);

        if (poolManager_ != CANONICAL_POOL_MANAGER) revert InvalidPoolManager(poolManager_);
        if (poolManager_.code.length == 0) revert PoolManagerHasNoCode(poolManager_);

        usdg = usdg_;
        poolManager = poolManager_;
    }

    /// @dev Task 1 将替换为完整的 Token 创建流程。
    function create(bytes calldata) external pure returns (address) {
        revert TaskNotImplemented();
    }

    /// @dev Task 1 将替换为原子 Listing 流程。
    function list(address) external pure {
        revert TaskNotImplemented();
    }
}
