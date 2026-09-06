// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {TagAISwapWrapper} from "../src/helper/TagAISwapWrapper.sol";
import {RHNutboxRouterConfig} from "./config/RHNutboxRouterConfig.sol";

/**
 * @title DeployRHNutboxRouter
 * @notice 部署 RH NutboxRouter：Uniswap V2 + V3 + V4，构造期写入官方股价格池。
 *
 * 环境变量：PRIVATE_KEY、NUTBOX_ROUTER_OWNER（Ownable2Step 最终 owner）。
 *
 * Dry run:
 *   forge script script/DeployRHNutboxRouter.s.sol --rpc-url $RH_RPC_URL --chain-id 4663 -vv
 */
contract DeployRHNutboxRouterScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(vm.envExists("NUTBOX_ROUTER_OWNER"), "NUTBOX_ROUTER_OWNER must be explicit");
        address targetOwner = vm.envAddress("NUTBOX_ROUTER_OWNER");
        require(targetOwner != address(0), "NutboxRouter owner missing");

        address weth = RHNutboxRouterConfig.wrappedNative();
        address poolManager = RHNutboxRouterConfig.poolManager();
        address v3Router = RHNutboxRouterConfig.v3Router();
        require(weth.code.length > 0, "RH WETH missing");
        require(poolManager.code.length > 0, "RH PoolManager missing");
        require(v3Router != address(0) && v3Router.code.length > 0, "RH V3 router missing");

        console2.log("=== RH NutboxRouter Deploy ===");
        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("WETH", weth);
        console2.log("USDG", RHNutboxRouterConfig.usdg());
        console2.log("PoolManager", poolManager);
        console2.log("V3 router", v3Router);

        address wrapper = _existingWrapper(block.chainid);

        vm.startBroadcast(pk);
        NutboxRouter router = _deployRouter(weth, poolManager, v3Router);
        if (wrapper != address(0) && wrapper.code.length > 0) {
            try TagAISwapWrapper(payable(wrapper)).adminSetNutboxRouter(address(router)) {
                console2.log("Wrapper.nutboxRouter set", wrapper);
                if (Ownable(wrapper).owner() == deployer && targetOwner != deployer) {
                    Ownable(wrapper).transferOwnership(targetOwner);
                    console2.log("Wrapper ownership transferred", targetOwner);
                }
            } catch {
                console2.log("ACTION REQUIRED: wrapper owner must adminSetNutboxRouter", wrapper);
            }
        }
        if (targetOwner != deployer) {
            router.transferOwnership(targetOwner);
        }
        vm.stopBroadcast();

        console2.log("NutboxRouter", address(router));
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept NutboxRouter ownership", targetOwner);
        }
        if (
            vm.envOr("WRITE_DEPLOYMENTS", false)
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                    || vm.isContext(VmSafe.ForgeContext.ScriptResume))
        ) {
            _writeAddresses(block.chainid, address(router));
        } else {
            console2.log("Dry-run: version11.json was not changed");
        }
        console2.log("=== Done ===");
    }

    function _deployRouter(address weth, address poolManager, address v3Router)
        internal
        returns (NutboxRouter router)
    {
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = RHNutboxRouterConfig.v2Factory();
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = RHNutboxRouterConfig.v2Router();
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = RHNutboxRouterConfig.v3Factory();
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = poolManager;
        address[] memory pancakeV4CLManagers = new address[](0);

        router = new NutboxRouter(
            weth,
            v3Router,
            v2Routers,
            v2Factories,
            v3Factories,
            uniswapV4Managers,
            pancakeV4CLManagers,
            RHNutboxRouterConfig.initialConfig()
        );
    }

    function _existingWrapper(uint256 chainId) internal view returns (address) {
        address configured = vm.envOr("RH_WRAPPER", address(0));
        if (configured != address(0)) return configured;
        string memory path = string.concat("deployments/", vm.toString(chainId), "/version11.json");
        if (!vm.exists(path)) return address(0);
        try vm.parseJsonAddress(vm.readFile(path), ".TagAISwapWrapper") returns (address w) {
            return w;
        } catch {
            return address(0);
        }
    }

    /// @dev 把 NutboxRouter 写回 deployments/<chainid>/version11.json：已存在键则替换值，否则在末尾 } 前插入。
    function _writeAddresses(uint256 chainId, address router) internal {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/version11.json");
        if (!vm.exists(path)) {
            console2.log("version11.json not found, skip patching");
            return;
        }
        vm.writeFile(path, _setKey(vm.readFile(path), "NutboxRouter", router));
        console2.log("Patched NutboxRouter into", path);
    }

    /// @dev 在 JSON 中设置 key 的值：存在则替换引号内地址，不存在则在末尾 } 前追加。
    function _setKey(string memory existing, string memory key, address val) internal returns (string memory) {
        bytes memory b = bytes(existing);
        require(b.length > 0, "empty json");
        bytes memory k = bytes(string.concat('"', key, '"'));
        uint256 kPos = _indexOf(b, k);
        if (kPos != type(uint256).max) {
            // 定位值：跳过 key 后的 ':' 与空白，找到首个 '"' ... '"' 区间并替换。
            uint256 i = kPos + k.length;
            while (i < b.length && b[i] != bytes1(":")) i++;
            i++; // 跳过 ':'
            while (i < b.length && _isWs(b[i])) i++;
            require(i < b.length && b[i] == bytes1("\""), "no value quote");
            uint256 valStart = i + 1;
            uint256 valEnd = valStart;
            while (valEnd < b.length && b[valEnd] != bytes1("\"")) valEnd++;
            return string.concat(
                _substring(existing, 0, valStart), vm.toString(val), _substring(existing, valEnd, b.length)
            );
        }
        // 不存在：在末尾 } 前追加。
        uint256 end = b.length;
        while (end > 0 && b[end - 1] != bytes1("}")) { end--; }
        require(end > 0, "no closing brace");
        uint256 insertAt = end - 1;
        bytes memory pb = bytes(_substring(existing, 0, insertAt));
        uint256 lastNonWs = pb.length;
        while (lastNonWs > 0 && _isWs(pb[lastNonWs - 1])) { lastNonWs--; }
        bool needComma = lastNonWs > 0 && pb[lastNonWs - 1] != bytes1(",") && pb[lastNonWs - 1] != bytes1("{");
        string memory suffix = string.concat(needComma ? "," : "", '\n  "', key, '": "', vm.toString(val), '"\n}\n');
        return string.concat(_substring(existing, 0, lastNonWs), suffix);
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length == 0 || h.length < n.length) return type(uint256).max;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) { m = false; break; }
            }
            if (m) return i;
        }
        return type(uint256).max;
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
