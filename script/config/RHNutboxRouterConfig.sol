// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INutboxRouter} from "../../src/router/INutboxRouter.sol";

/// @notice RH（Robinhood Chain）NutboxRouter 部署配置。
/// @dev 第 3 期采用方案 B：V3 router 暂置 address(0)，禁用 V3 指数回购路径
///     （_swapV3 因 pancakeV3Factory==0 自然 revert UnsupportedSwapSource）。
///      NFT AMM 社区币定价走 Uniswap V4 官方上市池；外部资产（ETH/BTC/USDT 等）
///      的 spot price pool 待 RH 主网地址确认后通过 addPricePool() 运行时配置，
///      不在构造期硬编码，避免引入未验证地址。
library RHNutboxRouterConfig {
    // RH mainnet（chain id 4663）
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    // RH Uniswap V2（robinhood-chain-quickstart）
    address internal constant RH_V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant RH_V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

    // RH Uniswap V3（SwapRouter02）——方案 B 暂不启用，留 address(0)。
    address internal constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant RH_V3_ROUTER = address(0);

    function wrappedNative() internal pure returns (address) {
        return RH_WETH;
    }

    function poolManager() internal pure returns (address) {
        return RH_POOL_MANAGER;
    }

    function v2Factory() internal pure returns (address) {
        return RH_V2_FACTORY;
    }

    function v2Router() internal pure returns (address) {
        return RH_V2_ROUTER;
    }

    function v3Factory() internal pure returns (address) {
        return RH_V3_FACTORY;
    }

    function v3Router() internal pure returns (address) {
        return RH_V3_ROUTER;
    }

    /// @dev 构造期不注入任何 price pool / route；运行时通过 addPricePool() 配置。
    function initialConfig() internal pure returns (bytes memory) {
        INutboxRouter.InitialPricePool[] memory emptyPools =
            new INutboxRouter.InitialPricePool[](0);
        INutboxRouter.InitialRoute[] memory emptyRoutes = new INutboxRouter.InitialRoute[](0);
        return abi.encode(emptyPools, emptyRoutes);
    }
}
