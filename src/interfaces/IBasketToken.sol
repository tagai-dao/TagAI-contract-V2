// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IBasketToken {
    enum Venue {
        V4,
        V3,
        WETH
    }

    struct LegRoute {
        Venue venue;
        PoolKey v4Pool;
        uint24 v3Fee;
    }

    function creatorPayout() external view returns (address);

    function rebalanceExecutor() external view returns (address);

    function weth() external view returns (address);

    function assetCount() external view returns (uint256);

    function assetAt(uint256 index) external view returns (address asset, uint16 targetWeightBps, uint256 activeReserve);

    function assetRouteAt(uint256 index) external view returns (LegRoute memory);

    function claimableHolderFees(address holder) external view returns (uint256);

    function claimHolderFeesFor(address holder) external returns (uint256 amount);
}
