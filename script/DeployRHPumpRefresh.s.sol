// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Pump} from "../src/pump/Pump.sol";
import {NutboxDeployConfig} from "../src/pump/NutboxDeployConfig.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/**
 * @title DeployRHPumpRefresh
 * @notice 仅部署新 Pump + Token 实现 + TagAISwapHook，复用 version9 的 IPShare / Nutbox / PoolManager。
 * @dev 禁止对本脚本之外跑全量 DeployRH.s.sol 到 4663（会 new IPShare / Committee）。
 *
 * 环境变量：PRIVATE_KEY、PUMP_OWNER（Ownable2Step 最终 owner，默认 deployer）。
 *
 * Dry run:
 *   forge script script/DeployRHPumpRefresh.s.sol --rpc-url $RH_RPC_URL --chain-id 4663 -vv
 */
contract DeployRHPumpRefreshScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    struct Reused {
        address committee;
        address communityFactory;
        address socialCurationFactory;
        address calculator;
        address ipshare;
        address poolManager;
        address weth;
        address feeAddress;
    }

    function run() external {
        require(block.chainid == RH_MAINNET_CHAIN_ID, "RH mainnet only (4663)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address targetOwner = vm.envOr("PUMP_OWNER", deployer);
        require(targetOwner != address(0), "Pump owner missing");

        Reused memory r = _loadVersion9();
        _validateReused(r);

        console2.log("=== RH Pump Refresh (no Nutbox/IPShare redeploy) ===");
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("IPShare", r.ipshare);
        console2.log("Committee", r.committee);
        console2.log("CommunityFactory", r.communityFactory);
        console2.log("HourlyTickCalculator", r.calculator);
        console2.log("PoolManager", r.poolManager);

        NutboxDeployConfig memory cfg = NutboxDeployConfig({
            communityFactory: r.communityFactory,
            calculator: r.calculator,
            socialCurationFactory: r.socialCurationFactory,
            committee: r.committee,
            poolManager: r.poolManager
        });

        vm.startBroadcast(pk);
        Pump pump = new Pump(r.ipshare, r.feeAddress, cfg);
        vm.stopBroadcast();
        console2.log("Pump", address(pump));
        console2.log("TokenImplementation", pump.tokenImplementation());

        bytes memory constructorArgs = abi.encode(IPoolManager(r.poolManager), address(pump));
        (address predictedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_FLAGS, type(TagAISwapHook).creationCode, constructorArgs
        );
        console2.log("Hook salt", uint256(salt));
        console2.log("predicted Hook", predictedHook);

        vm.startBroadcast(pk);
        TagAISwapHook hook = new TagAISwapHook{salt: salt}(IPoolManager(r.poolManager), address(pump));
        require(address(hook) == predictedHook, "CREATE2 hook address mismatch");
        require(uint160(address(hook)) & ((1 << 14) - 1) == HOOK_FLAGS, "invalid hook flags");

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(r.calculator);
        pump.adminSetNutbox(r.communityFactory, r.calculator, r.socialCurationFactory, r.committee);
        if (targetOwner != deployer) {
            pump.transferOwnership(targetOwner);
        }
        vm.stopBroadcast();

        console2.log("TagAISwapHook", address(hook));
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept Pump ownership", targetOwner);
        }
        if (
            vm.envOr("WRITE_DEPLOYMENTS", false)
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                    || vm.isContext(VmSafe.ForgeContext.ScriptResume))
        ) {
            _writeAddresses(address(pump), pump.tokenImplementation(), address(hook));
        } else {
            console2.log("Dry-run: version11.json was not changed");
        }
        console2.log("=== Done ===");
    }

    function _loadVersion9() internal view returns (Reused memory r) {
        string memory path = "deployments/4663/version9.json";
        require(vm.exists(path), "version9.json missing");
        string memory json = vm.readFile(path);
        r.committee = vm.parseJsonAddress(json, ".Committee");
        r.communityFactory = vm.parseJsonAddress(json, ".CommunityFactory");
        r.socialCurationFactory = vm.parseJsonAddress(json, ".SocialCurationFactory");
        r.calculator = vm.parseJsonAddress(json, ".HourlyTickCalculator");
        r.ipshare = vm.parseJsonAddress(json, ".IPShare");
        r.poolManager = vm.parseJsonAddress(json, ".PoolManager");
        r.weth = vm.parseJsonAddress(json, ".WETH");
        r.feeAddress = vm.parseJsonAddress(json, ".feeAddress");
    }

    function _validateReused(Reused memory r) internal view {
        require(r.committee.code.length > 0, "Committee missing");
        require(r.communityFactory.code.length > 0, "CommunityFactory missing");
        require(r.socialCurationFactory.code.length > 0, "SocialCurationFactory missing");
        require(r.calculator.code.length > 0, "HourlyTickCalculator missing");
        require(r.ipshare.code.length > 0, "IPShare missing, do not redeploy");
        require(r.poolManager.code.length > 0, "PoolManager missing");
        require(r.weth.code.length > 0, "WETH missing");
        require(r.feeAddress != address(0), "feeAddress missing");
    }

    function _writeAddresses(address pump, address tokenImpl, address hook) internal {
        string memory path = "deployments/4663/version11.json";
        if (!vm.exists(path)) {
            console2.log("version11.json not found, skip patching");
            return;
        }
        string memory json = vm.readFile(path);
        json = _setKey(json, "Pump", pump);
        json = _setKey(json, "TokenImplementation", tokenImpl);
        json = _setKey(json, "TagAISwapHook", hook);
        vm.writeFile(path, json);
        console2.log("Patched Pump/Hook into", path);
    }

    function _setKey(string memory existing, string memory key, address val) internal returns (string memory) {
        bytes memory b = bytes(existing);
        require(b.length > 0, "empty json");
        bytes memory k = bytes(string.concat('"', key, '"'));
        uint256 kPos = _indexOf(b, k);
        if (kPos != type(uint256).max) {
            uint256 i = kPos + k.length;
            while (i < b.length && b[i] != bytes1(":")) i++;
            i++;
            while (i < b.length && _isWs(b[i])) i++;
            require(i < b.length && b[i] == bytes1("\""), "no value quote");
            uint256 valStart = i + 1;
            uint256 valEnd = valStart;
            while (valEnd < b.length && b[valEnd] != bytes1("\"")) valEnd++;
            return string.concat(_substring(existing, 0, valStart), vm.toString(val), _substring(existing, valEnd, b.length));
        }
        uint256 end = b.length;
        while (end > 0 && b[end - 1] != bytes1("}")) end--;
        require(end > 0, "no closing brace");
        bytes memory pb = bytes(_substring(existing, 0, end - 1));
        uint256 lastNonWs = pb.length;
        while (lastNonWs > 0 && _isWs(pb[lastNonWs - 1])) lastNonWs--;
        bool needComma = lastNonWs > 0 && pb[lastNonWs - 1] != bytes1(",") && pb[lastNonWs - 1] != bytes1("{");
        return string.concat(
            _substring(existing, 0, lastNonWs),
            string.concat(needComma ? "," : "", '\n  "', key, '": "', vm.toString(val), '"\n}\n')
        );
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length == 0 || h.length < n.length) return type(uint256).max;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
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
