// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {ImportedTokenSwapWrapper} from "../src/helper/ImportedTokenSwapWrapper.sol";

/**
 * @title DeployRHImportWrapper
 * @notice 部署 BSC-compatible ImportedTokenSwapWrapper + ImportHelper（复用 NutboxRouter / Nutbox / IPShare）。
 *
 * RH testnet (46630):
 *   FOUNDRY_PROFILE=rh_testnet forge script script/DeployRHImportWrapper.s.sol:DeployRHImportWrapperScript \
 *     --broadcast --slow --gas-estimate-multiplier 300 -vvv
 *
 * 可选覆盖（.env）:
 *   RH_COMMUNITY_FACTORY / RH_SCF / RH_COMMITTEE / RH_IPSHARE / RH_FEE_ADDRESS / NUTBOX_ROUTER
 */
contract DeployRHImportWrapperScript is Script {
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;

    // deployments/46630/version11.json（既有栈）
    address internal constant TN_COMMUNITY_FACTORY = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;
    address internal constant TN_SCF = 0xd52624320654FBEA5F1f988d5F4E55B74C56e67D;
    address internal constant TN_COMMITTEE = 0xa77253Ac630502A35A6FcD210A01f613D33ba7cD;
    address internal constant TN_IPSHARE = 0x33a1F7760f48c53E811aFaCa931B27124cafdC19;
    // Uniswap WETH9 on RH testnet
    address internal constant TN_WETH = 0x37E402B8081eFcE1D82A09a066512278006e4691;
    // 已部署的 Pump（testnet）——用于拒绝 Pump 代币导入。
    address internal constant TN_PUMP = 0x8c701E56A178A9cEd02D731e057Af6E709A66A9e;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // 显式 fork 测试网（勿用 .env 的 RH_RPC_URL——那边常是 mainnet）
        string memory rpc = vm.envOr("RH_RPC_URL", string("https://rpc.testnet.chain.robinhood.com"));
        if (block.chainid == RH_MAINNET_CHAIN_ID) {
            rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        }
        vm.createSelectFork(rpc);

        address communityFactory =
            vm.envOr("RH_COMMUNITY_FACTORY", _defaultDependency("CommunityFactory", TN_COMMUNITY_FACTORY));
        address scf = vm.envOr("RH_SCF", _defaultDependency("SocialCurationFactory", TN_SCF));
        address committee = vm.envOr("RH_COMMITTEE", _defaultDependency("Committee", TN_COMMITTEE));
        address ipshare = vm.envOr("RH_IPSHARE", _defaultDependency("IPShare", TN_IPSHARE));
        address feeAddress = vm.envOr("RH_FEE_ADDRESS", _defaultFeeAddress(deployer));
        address pump = vm.envOr("RH_PUMP", _defaultPump());
        address nutboxRouter = vm.envOr("NUTBOX_ROUTER", _defaultNutboxRouter());

        console.log("=== Deploy ImportHelper + ImportedTokenSwapWrapper ===");
        console.log("Chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("CommunityFactory:", communityFactory);
        console.log("SCF:", scf);
        console.log("Committee:", committee);
        console.log("IPShare:", ipshare);
        console.log("NutboxRouter:", nutboxRouter);
        console.log("feeAddress:", feeAddress);
        console.log("Pump:", pump);

        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(scf.code.length > 0, "SCF missing");
        require(committee.code.length > 0, "Committee missing");
        require(ipshare.code.length > 0, "IPShare missing");
        require(nutboxRouter.code.length > 0, "NutboxRouter missing");

        vm.startBroadcast(pk);

        ImportedTokenSwapWrapper wrapper = new ImportedTokenSwapWrapper(nutboxRouter, feeAddress, ipshare);
        console.log("ImportedTokenSwapWrapper:", address(wrapper));

        ImportHelper importHelper = new ImportHelper(communityFactory, scf, committee, ipshare, pump, address(wrapper));
        console.log("ImportHelper:", address(importHelper));

        wrapper.setRegistrar(address(importHelper));
        console.log("Wrapper.registrar set");

        vm.stopBroadcast();

        if (
            vm.envOr("WRITE_DEPLOYMENTS", false)
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume))
        ) {
            _patchAddresses(block.chainid, address(importHelper), address(wrapper), wrapper.wrappedNative());
        } else {
            console.log("Dry-run: version11.json was not changed");
        }
        console.log("=== Done ===");
    }

    function _defaultNutboxRouter() internal view returns (address) {
        if (block.chainid == RH_MAINNET_CHAIN_ID) return _defaultDependency("NutboxRouter", address(0));
        if (block.chainid == RH_TESTNET_CHAIN_ID) return address(0);
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_testnet|rh_mainnet");
    }

    function _defaultFeeAddress(address testnetDefault) internal view returns (address) {
        if (block.chainid == RH_TESTNET_CHAIN_ID) return testnetDefault;
        if (block.chainid == RH_MAINNET_CHAIN_ID) {
            string memory v11 = "deployments/4663/version11.json";
            require(vm.exists(v11), "deployments/4663/version11.json missing");
            address feeAddress = vm.parseJsonAddress(vm.readFile(v11), ".feeAddress");
            require(feeAddress != address(0), "mainnet feeAddress missing from version11.json");
            return feeAddress;
        }
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_testnet|rh_mainnet");
    }

    function _defaultDependency(string memory key, address testnetDefault) internal view returns (address dependency) {
        if (block.chainid == RH_TESTNET_CHAIN_ID) return testnetDefault;
        if (block.chainid != RH_MAINNET_CHAIN_ID) {
            revert("unsupported chain: use FOUNDRY_PROFILE=rh_testnet|rh_mainnet");
        }

        string memory v11 = "deployments/4663/version11.json";
        require(vm.exists(v11), "deployments/4663/version11.json missing");
        dependency = vm.parseJsonAddress(vm.readFile(v11), string.concat(".", key));
        require(dependency != address(0), "mainnet dependency missing from version11.json");
    }

    /// @dev 主网从 version11 Pump 读取（未部署则回退 version9）；测试网用常量。
    ///      禁止主网误用测试网 Pump，否则 ImportHelper 无法拒绝主网 Pump 代币。
    function _defaultPump() internal view returns (address) {
        if (block.chainid == RH_TESTNET_CHAIN_ID) return TN_PUMP;
        if (block.chainid == RH_MAINNET_CHAIN_ID) {
            string memory v11 = "deployments/4663/version11.json";
            if (vm.exists(v11)) {
                address p = vm.parseJsonAddress(vm.readFile(v11), ".Pump");
                if (p != address(0)) return p;
            }
            return vm.parseJsonAddress(vm.readFile("deployments/4663/version9.json"), ".Pump");
        }
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_testnet|rh_mainnet");
    }

    /// @dev 更新新旧地址字段，保留其余已部署地址。
    function _patchAddresses(uint256 chainId, address importHelper, address wrapper, address weth) internal {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/version11.json");
        // 读已有 JSON 再写回关键键（简单拼接：整文件重写时合并已知常量）
        // 测试网：用已知栈地址 + 新地址
        if (chainId == RH_TESTNET_CHAIN_ID) {
            string memory json = string.concat(
                "{\n",
                '  "version": 11,\n',
                '  "status": "testnet",\n',
                '  "sourceVersion": 9,\n',
                '  "chainId": 46630,\n',
                '  "deployer": "0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611",\n',
                '  "Committee": "',
                vm.toString(TN_COMMITTEE),
                '",\n',
                '  "CommunityFactory": "',
                vm.toString(TN_COMMUNITY_FACTORY),
                '",\n',
                '  "HourlyTickCalculator": "0xf5D8d9402A4603bD67400500E62880eee91cF12C",\n',
                '  "SocialCurationFactory": "',
                vm.toString(TN_SCF),
                '",\n',
                '  "DFXStarScoreStakingFactory": "0xddbAba530728b5B8939d7fdDC334432490916e90",\n',
                '  "IPShare": "',
                vm.toString(TN_IPSHARE),
                '",\n',
                '  "PoolManager": "0x552815eF68E6eb418A3d65D0AA1043d93204F612",\n',
                '  "Pump": "0x8c701E56A178A9cEd02D731e057Af6E709A66A9e",\n',
                '  "TokenImplementation": "0x5Aa71794E2Fe52a0c554f5da7249Cc55B39B2b93",\n',
                '  "TagAISwapHook": "0x644dD54B13Bdf38AFF947cA2a46EE4b9144E60cC",\n',
                '  "WETH": "',
                vm.toString(weth),
                '",\n',
                '  "ImportHelper": "',
                vm.toString(importHelper),
                '",\n',
                '  "ImportedTokenSwapWrapper": "',
                vm.toString(wrapper),
                '",\n',
                '  "TagAISwapWrapper": "',
                vm.toString(wrapper),
                '"\n',
                "}\n"
            );
            vm.writeFile(path, json);
            console.log("Updated:", path);
        } else if (chainId == RH_MAINNET_CHAIN_ID) {
            require(vm.exists(path), "version11.json missing");
            string memory json = vm.readFile(path);
            address previousImportHelper = vm.parseJsonAddress(json, ".ImportHelper");
            address previousWrapper = vm.parseJsonAddress(json, ".TagAISwapWrapper");
            json = _setKey(json, "PreviousImportHelper", previousImportHelper);
            json = _setKey(json, "PreviousTagAISwapWrapper", previousWrapper);
            json = _setKey(json, "ImportHelper", importHelper);
            json = _setKey(json, "ImportedTokenSwapWrapper", wrapper);
            json = _setKey(json, "TagAISwapWrapper", wrapper);
            json = _setKey(json, "WETH", weth);
            vm.writeFile(path, json);
            console.log("Patched ImportHelper/ImportedTokenSwapWrapper into", path);
        } else {
            console.log("Skip version11.json patch for chain", chainId);
        }
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
            return
                string.concat(
                    _substring(existing, 0, valStart), vm.toString(val), _substring(existing, valEnd, b.length)
                );
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
