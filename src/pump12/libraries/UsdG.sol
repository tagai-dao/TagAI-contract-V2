// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @title UsdG
/// @notice Pump12 内部 18 位 WAD 与 canonical USDG 6 位原子单位之间的换算。
library UsdG {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAW_SCALE = 1e6;
    uint256 internal constant WAD_PER_RAW = WAD / RAW_SCALE;

    /// @notice 将 USDG raw units 精确转换为 18 位 WAD。
    function toWad(uint256 raw6) internal pure returns (uint256) {
        return raw6 * WAD_PER_RAW;
    }

    /// @notice 对外付款使用向下舍入，避免协议多支付一个 USDG 原子单位。
    function toRaw6(uint256 wad) internal pure returns (uint256) {
        return wad / WAD_PER_RAW;
    }

    /// @notice 协议应收入账使用向上舍入，避免低估应收金额。
    function toRaw6Up(uint256 wad) internal pure returns (uint256) {
        uint256 quotient = wad / WAD_PER_RAW;
        return wad % WAD_PER_RAW == 0 ? quotient : quotient + 1;
    }
}
