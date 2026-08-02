// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @dev Optional deploy-time overrides; address(0) keeps compile-time defaults in Pump.sol.
struct NutboxDeployConfig {
    address communityFactory;
    address calculator;
    address socialCurationFactory;
    address aiChannelPoolFactory;
    address committee;
    address poolManager;
}

library NutboxDeployConfigLib {
    function empty() internal pure returns (NutboxDeployConfig memory) {
        return NutboxDeployConfig(address(0), address(0), address(0), address(0), address(0), address(0));
    }
}
