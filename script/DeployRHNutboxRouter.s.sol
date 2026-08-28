// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {RHNutboxRouterConfig} from "./config/RHNutboxRouterConfig.sol";

/**
 * @title DeployRHNutboxRouter
 * @notice 部署 RH NutboxRouter（方案 B：V3 router=0，禁用 V3 指数回购；V2 + Uniswap V4 可用）。
 *
 * Dry run（不广播）:
 *   forge script script/DeployRHNutboxRouter.s.sol --rpc-url $RH_RPC_URL --chain-id 4663 -vv
 *
 * 不在本任务中 --broadcast；统一发布按总计划手动执行。
 */
contract DeployRHNutboxRouterScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address weth = RHNutboxRouterConfig.wrappedNative();
        address poolManager = RHNutboxRouterConfig.poolManager();
        require(weth.code.length > 0, "RH WETH missing");
        require(poolManager.code.length > 0, "RH PoolManager missing");

        console2.log("=== RH NutboxRouter Deploy ===");
        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("WETH", weth);
        console2.log("PoolManager", poolManager);

        vm.startBroadcast(pk);
        NutboxRouter router = _deployRouter(weth, poolManager);
        vm.stopBroadcast();

        console2.log("NutboxRouter", address(router));
        _writeAddresses(block.chainid, address(router));
        console2.log("=== Done (dry-run, not broadcast) ===");
    }

    function _deployRouter(address weth, address poolManager) internal returns (NutboxRouter router) {
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = RHNutboxRouterConfig.v2Factory();
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = RHNutboxRouterConfig.v2Router();
        // V3 factory 仍 allowlist（运行时若启用 V3 可复用）；V3 router=0 禁用回购路径。
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = RHNutboxRouterConfig.v3Factory();
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = poolManager;
        // RH 不部署 Pancake Infinity CL manager。
        address[] memory pancakeV4CLManagers = new address[](0);

        router = new NutboxRouter(
            weth,
            RHNutboxRouterConfig.v3Router(), // address(0) → 方案 B
            v2Routers,
            v2Factories,
            v3Factories,
            uniswapV4Managers,
            pancakeV4CLManagers,
            RHNutboxRouterConfig.initialConfig()
        );
    }

    /// @dev 把 NutboxRouter 写回 deployments/<chainid>/addresses.json（在末尾 } 前插入键）。
    function _writeAddresses(uint256 chainId, address router) internal {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/addresses.json");
        if (!vm.exists(path)) {
            console2.log("addresses.json not found, skip patching");
            return;
        }
        vm.writeFile(path, _patch(vm.readFile(path), router));
        console2.log("Patched NutboxRouter into", path);
    }

    /// @dev 在已有 JSON 末尾 } 前插入 NutboxRouter 字段。
    function _patch(string memory existing, address router) internal pure returns (string memory) {
        bytes memory b = bytes(existing);
        require(b.length > 0, "empty json");
        uint256 end = b.length;
        while (end > 0 && b[end - 1] != bytes1("}")) { end--; }
        require(end > 0, "no closing brace");
        uint256 insertAt = end - 1;
        bytes memory pb = bytes(_substring(existing, 0, insertAt));
        uint256 lastNonWs = pb.length;
        while (lastNonWs > 0 && _isWs(pb[lastNonWs - 1])) {
            lastNonWs--;
        }
        bool needComma = lastNonWs > 0 && pb[lastNonWs - 1] != bytes1(",") && pb[lastNonWs - 1] != bytes1("{");
        string memory suffix = string.concat(
            needComma ? "," : "",
            '\n  "NutboxRouter": "',
            vm.toString(router),
            '"\n}\n'
        );
        return string.concat(_substring(existing, 0, lastNonWs), suffix);
    }

    function _isWs(bytes1 c) internal pure returns (bool) {
        return c == bytes1(" ") || c == bytes1("\n") || c == bytes1("\r") || c == bytes1("\t");
    }

    function _substring(string memory s, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < end - start; ++i) {
            out[i] = b[start + i];
        }
        return string(out);
    }
}
