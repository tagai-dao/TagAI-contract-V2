// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Pump12} from "../src/pump12/Pump12.sol";

/// @title DeployPump12RHScript
/// @notice 仅允许在 Robinhood Chain 主网连接 canonical USDG 与 Uniswap v4 PoolManager。
contract DeployPump12RHScript is Script {
    uint256 public constant RH_CHAIN_ID = 4663;
    uint8 public constant USDG_DECIMALS = 6;
    address public constant CANONICAL_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant CANONICAL_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external returns (Pump12 pump) {
        validateConfig(CANONICAL_USDG, CANONICAL_POOL_MANAGER);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console2.log("=== Pump12 Robinhood Deployment ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("USDG:", CANONICAL_USDG);
        console2.log("PoolManager:", CANONICAL_POOL_MANAGER);

        vm.startBroadcast(privateKey);
        pump = new Pump12(CANONICAL_USDG, CANONICAL_POOL_MANAGER);
        vm.stopBroadcast();

        console2.log("Pump12:", address(pump));
    }

    /// @notice 可在 dry-run、fork 和单元测试中独立调用的部署前检查。
    function validateConfig(address usdg, address poolManager) public view {
        require(block.chainid == RH_CHAIN_ID, "Pump12: unsupported chain");
        require(usdg == CANONICAL_USDG, "Pump12: non-canonical USDG");
        require(usdg.code.length > 0, "Pump12: USDG has no code");

        uint8 actualDecimals;
        try IERC20Metadata(usdg).decimals() returns (uint8 decimals_) {
            actualDecimals = decimals_;
        } catch {
            revert("Pump12: unreadable USDG decimals");
        }
        require(actualDecimals == USDG_DECIMALS, "Pump12: USDG decimals must be 6");

        require(poolManager == CANONICAL_POOL_MANAGER, "Pump12: non-canonical PoolManager");
        require(poolManager.code.length > 0, "Pump12: PoolManager has no code");
    }
}
