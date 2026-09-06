// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IIndexFund {
    struct InitParams {
        address usdg;
        address indexToken;
        address creator;
        address creatorFeeRecipient;
        address desk;
        address burnNet;
        address hook;
        PoolId poolId;
        address basketRegistry;
        address basketRouter;
        address basketRouteRegistry;
        address poolManager;
        address weth;
    }

    function initialize(InitParams calldata params) external;

    function onDeskProceeds(uint256 usdgRaw) external returns (uint256 indexOut);
}
