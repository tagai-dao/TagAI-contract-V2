// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIndexBrokerNFTPriceOracle {
    enum SourceType {
        V2_PAIR,
        V3_POOL,
        UNISWAP_V4,
        PANCAKE_V4_CL
    }

    struct UniswapV4Source {
        address poolManager;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PancakeV4CLSource {
        address currency0;
        address currency1;
        address hooks;
        address poolManager;
        uint24 fee;
        bytes32 parameters;
    }

    function wrappedNative() external view returns (address);

    function validateSource(address communityToken, SourceType sourceType, bytes calldata sourceData) external view;

    function quoteNative(
        address communityToken,
        uint256 communityTokenAmount,
        SourceType sourceType,
        bytes calldata sourceData
    ) external view returns (uint256 nativeAmount);
}
