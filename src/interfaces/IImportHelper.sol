// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @title IImportHelper
/// @notice Minimal interface consumed by TagAISwapWrapper for sellsman resolution + 登记查询。
interface IImportHelper {
    /// @dev token → 首次导入者（sellsman 回退源）。
    function importerOf(address token) external view returns (address);
}

/// @title IImportedTokenMarketRegistrar
/// @notice ImportHelper 通过此接口在 Wrapper 登记导入代币的市场（community + deployer）。
interface IImportedTokenMarketRegistrar {
    function registerImportedToken(address token, address community, address deployer) external;

    function getImportedMarket(address token)
        external
        view
        returns (bool registered, address community, address deployer);
}
