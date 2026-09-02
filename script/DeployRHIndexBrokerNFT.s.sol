// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IndexBrokerNFTFactory} from
    "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {IndexBrokerNFTAMM} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTBurn, IndexBrokerNFTStake} from
    "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTRenderer} from "../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTRenderer.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RHNutboxRouterConfig} from "./config/RHNutboxRouterConfig.sol";

/**
 * @title DeployRHIndexBrokerNFT
 * @notice 部署 RH Index Broker NFT（Factory + 模板 + Renderer）。
 *
 * 依赖（version11.json 必须已有代码）：
 *   CommunityFactory、Pump、NutboxRouter、BasketRegistry、
 *   BasketSwapRouter、DefaultIndexToken、BasketVersion
 *
 * Uniswap V3 买指数：indexV3Router = SwapRouter02，fee=100（USDG/WETH 0.01% hub）。
 * USDG 为 6 decimals：minSettlementOut 由调用方按 6 位传入，合约不做 18→6 换算。
 *
 * 环境变量：PRIVATE_KEY、INDEX_BROKER_OWNER
 */
contract DeployRHIndexBrokerNFTScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), "/version11.json");
        require(vm.exists(path), "version11.json missing");
        string memory json = vm.readFile(path);

        address communityFactory = vm.envOr(
            "RH_COMMUNITY_FACTORY", vm.parseJsonAddress(json, ".CommunityFactory")
        );
        address pump = vm.envOr("RH_PUMP", vm.parseJsonAddress(json, ".Pump"));
        address nutboxRouter = vm.envOr("NUTBOX_ROUTER", vm.parseJsonAddress(json, ".NutboxRouter"));
        address basketRegistry = vm.envOr(
            "BASKET_REGISTRY", vm.parseJsonAddress(json, ".BasketRegistry")
        );
        address committee = vm.envOr("RH_COMMITTEE", vm.parseJsonAddress(json, ".Committee"));
        address basketSwapRouter = vm.envOr(
            "BASKET_SWAP_ROUTER", vm.parseJsonAddress(json, ".BasketSwapRouter")
        );
        address defaultIndexToken = vm.envOr(
            "DEFAULT_INDEX_TOKEN", vm.parseJsonAddress(json, ".DefaultIndexToken")
        );
        uint32 basketVersion = uint32(vm.envOr("BASKET_VERSION", vm.parseJsonUint(json, ".BasketVersion")));

        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(pump.code.length > 0, "Pump missing (run DeployRHPumpRefresh first)");
        require(nutboxRouter.code.length > 0, "NutboxRouter missing (run DeployRHNutboxRouter first)");
        require(basketRegistry.code.length > 0, "BasketRegistry missing");
        require(basketSwapRouter.code.length > 0, "BasketSwapRouter missing (deploy Basket V3 first)");
        require(defaultIndexToken.code.length > 0, "DefaultIndexToken missing");
        require(basketVersion != 0, "BasketVersion missing");

        address v3Router = RHNutboxRouterConfig.v3Router();
        uint24 v3Fee = 100; // USDG/WETH hub 0.01%
        require(v3Router.code.length > 0, "RH V3 router missing");

        require(vm.envExists("INDEX_BROKER_OWNER"), "INDEX_BROKER_OWNER must be explicit");
        address targetOwner = vm.envAddress("INDEX_BROKER_OWNER");
        require(targetOwner != address(0), "IndexBroker owner missing");

        console2.log("=== RH Index Broker NFT Deploy ===");
        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("V3 router", v3Router);
        console2.log("USDG", RHNutboxRouterConfig.usdg());
        console2.log("BasketSwapRouter", basketSwapRouter);
        console2.log("DefaultIndexToken", defaultIndexToken);

        uint32[] memory basketVersions = new uint32[](1);
        basketVersions[0] = basketVersion;
        address[] memory basketSwapRouters = new address[](1);
        basketSwapRouters[0] = basketSwapRouter;

        vm.startBroadcast(pk);
        IndexBrokerNFTRenderer renderer = new IndexBrokerNFTRenderer();
        IndexBrokerNFTBurn burnTemplate = new IndexBrokerNFTBurn();
        IndexBrokerNFTStake stakeTemplate = new IndexBrokerNFTStake();
        IndexBrokerNFTAMM ammTemplate = new IndexBrokerNFTAMM();
        IndexBrokerNFTFactory factory = new IndexBrokerNFTFactory(
            communityFactory,
            pump,
            address(renderer),
            address(ammTemplate),
            nutboxRouter,
            basketRegistry,
            basketVersions,
            basketSwapRouters,
            v3Router,
            v3Fee,
            defaultIndexToken
        );
        factory.addNFTTemplate(address(burnTemplate));
        factory.addNFTTemplate(address(stakeTemplate));
        // 构造已登记 constructor pump；若 version11 Pump 不同再补登记。
        if (!factory.supportedPump(pump)) {
            factory.addPump(pump);
        }
        if (committee.code.length > 0 && Ownable(committee).owner() == deployer) {
            ICommittee(committee).adminAddContract(address(factory));
        }
        if (targetOwner != deployer) {
            factory.transferOwnership(targetOwner);
        }
        vm.stopBroadcast();

        console2.log("Renderer", address(renderer));
        console2.log("BurnTemplate", address(burnTemplate));
        console2.log("StakeTemplate", address(stakeTemplate));
        console2.log("AMMTemplate", address(ammTemplate));
        console2.log("IndexBrokerNFTFactory", address(factory));
        if (committee.code.length == 0 || Ownable(committee).owner() != deployer) {
            console2.log("ACTION REQUIRED: Committee owner must adminAddContract(factory)");
        }
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept IndexBroker Factory ownership", targetOwner);
        }
        if (
            vm.envOr("WRITE_DEPLOYMENTS", false)
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                    || vm.isContext(VmSafe.ForgeContext.ScriptResume))
        ) {
            _writeAddresses(
                block.chainid,
                address(factory),
                address(renderer),
                address(burnTemplate),
                address(stakeTemplate),
                address(ammTemplate)
            );
        } else {
            console2.log("Dry-run: version11.json was not changed");
        }
        console2.log("=== Done ===");
    }

    /// @dev 把 Index Broker NFT 地址写回 deployments/<chainid>/version11.json：已存在键则替换，否则追加。
    function _writeAddresses(
        uint256 chainId,
        address factory,
        address renderer,
        address burnTemplate,
        address stakeTemplate,
        address ammTemplate
    ) internal {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/version11.json");
        if (!vm.exists(path)) {
            console2.log("version11.json not found, skip patching");
            return;
        }
        string memory json = vm.readFile(path);
        json = _setKey(json, "IndexBrokerNFTFactory", factory);
        json = _setKey(json, "IndexBrokerNFTRenderer", renderer);
        json = _setKey(json, "IndexBrokerNFTBurnTemplate", burnTemplate);
        json = _setKey(json, "IndexBrokerNFTStakeTemplate", stakeTemplate);
        json = _setKey(json, "IndexBrokerNFTAMMTemplate", ammTemplate);
        vm.writeFile(path, json);
        console2.log("Patched Index Broker NFT addresses into", path);
    }

    /// @dev 在 JSON 中设置 key 的值：存在则替换引号内地址，不存在则在末尾 } 前追加。
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
            return string.concat(
                _substring(existing, 0, valStart), vm.toString(val), _substring(existing, valEnd, b.length)
            );
        }
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

    function _hasKey(string memory json, string memory key) internal pure returns (bool) {
        return _indexOf(json, string.concat('"', key, '"')) != type(uint256).max;
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length == 0 || h.length < n.length) return type(uint256).max;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) { match_ = false; break; }
            }
            if (match_) return i;
        }
        return type(uint256).max;
    }

    function _indexOf(string memory haystack, string memory needle) internal pure returns (uint256) {
        return _indexOf(bytes(haystack), bytes(needle));
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
