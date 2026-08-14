// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Pump} from "../src/pump/Pump.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DeployBSCPumpRefresh
 * @notice Redeploy Pump (+ new Token impl) and TagAISwapHook on BSC mainnet.
 *         Reuses existing HourlyTickCalculator, DFXStarScoreStakingFactory, Nutbox infra.
 *
 * Usage (simulate):
 *   source .env
 *   forge script script/DeployBSCPumpRefresh.s.sol --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Usage (broadcast + verify; only update the V11 record after success):
 *   WRITE_DEPLOYMENTS=true forge script script/DeployBSCPumpRefresh.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * Set PUMP_OWNER to initiate Ownable2Step ownership handover. Reused addresses
 * are loaded from deployments/56/version11.json. A successful broadcast with
 * WRITE_DEPLOYMENTS=true replaces only the V11 Pump/Token/Hook fields and then
 * advances its status from `preparing` to `pump-deployed`.
 */
contract DeployBSCPumpRefreshScript is Script {
    string internal constant VERSION11_PATH = "deployments/56/version11.json";

    // ─── Reused BSC infrastructure ───────────────────────────────────────────
    address internal committee;
    address internal communityFactory;
    address internal socialCurationFactory;
    address internal clPoolManager;
    address internal vault;
    address internal ipshare;
    address internal feeReceiver;

    // ─── Reused from previous V9 deploy (no Committee re-whitelist needed) ───
    address internal calculator;
    address internal dfxFactory;
    address internal dfxStaking;
    address internal create2Deployer;
    address internal previousPump;

    uint16 constant TARGET_BITMAP = 0x0CC1;
    uint256 constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() public {
        require(block.chainid == 56, "BSC mainnet only (chainId 56)");
        _loadVersion11();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);
        address targetOwner = vm.envOr("PUMP_OWNER", deployer);
        bool writeDeployments = vm.envOr("WRITE_DEPLOYMENTS", false);

        _validateDependencies();

        console.log("=== BSC Pump Refresh Deploy ===");
        console.log("Deployer:", deployer);
        console.log("V11 deployment record:", VERSION11_PATH);
        console.log("Reusing Calculator:", calculator);
        console.log("Reusing DFXStarScoreStakingFactory:", dfxFactory);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        Pump pump = new Pump(ipshare, feeReceiver);
        pump.adminSetPoolManager(clPoolManager);
        pump.adminSetVault(vault);
        console.log("Pump:", address(pump));
        console.log("TokenImplementation:", pump.tokenImplementation());

        vm.stopBroadcast();

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode, abi.encode(ICLPoolManager(clPoolManager), IVault(vault), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("Mining Hook salt for Pump:", address(pump));
        (bytes32 hookSalt, address predictedHook, uint256 iterations) = mineSalt(create2Deployer, bytecodeHash);
        console.log("  iterations:", iterations);
        console.log("  HookSalt:", uint256(hookSalt));
        console.log("  predicted Hook:", predictedHook);

        vm.startBroadcast(deployerPrivateKey);

        TagAISwapHook hook =
            new TagAISwapHook{salt: hookSalt}(ICLPoolManager(clPoolManager), IVault(vault), address(pump));
        require(address(hook) == predictedHook, "Hook address mismatch");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
        console.log("TagAISwapHook:", address(hook));

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(calculator);
        pump.adminSetNutbox(communityFactory, calculator, socialCurationFactory, committee);
        if (targetOwner != deployer) pump.transferOwnership(targetOwner);
        console.log("Pump configured");

        vm.stopBroadcast();

        _validateDeployment(pump, hook, targetOwner);

        bool isBroadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (writeDeployments && isBroadcast) {
            _writeAddresses(pump, hook, hookSalt, deployer, targetOwner);
            console.log("V11 Pump deployment recorded:", VERSION11_PATH);
        } else if (writeDeployments) {
            console.log("Dry run: WRITE_DEPLOYMENTS ignored outside broadcast/resume context");
        } else {
            console.log("Dry run: deployment record not written");
        }

        console.log("");
        console.log("=== Deploy Complete ===");
        console.log("New Pump:", address(pump));
        console.log("New TokenImplementation:", pump.tokenImplementation());
        console.log("New TagAISwapHook:", address(hook));
        if (targetOwner != deployer) {
            console.log("ACTION REQUIRED: target owner must accept Pump ownership:", targetOwner);
        }
        console.log("Update tiptag-ui / tagai-api / subgraph with new Pump + Hook addresses.");
    }

    function _loadVersion11() internal {
        require(vm.exists(VERSION11_PATH), "deployments/56/version11.json missing");
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");
        require(_sameString(vm.parseJsonString(json, ".status"), "preparing"), "V11 Pump already recorded");
        require(vm.parseJsonUint(json, ".HookBitmap") == TARGET_BITMAP, "Unexpected Hook bitmap");

        committee = vm.parseJsonAddress(json, ".Committee");
        communityFactory = vm.parseJsonAddress(json, ".CommunityFactory");
        socialCurationFactory = vm.parseJsonAddress(json, ".SocialCurationFactory");
        clPoolManager = vm.parseJsonAddress(json, ".CLPoolManager");
        vault = vm.parseJsonAddress(json, ".Vault");
        ipshare = vm.parseJsonAddress(json, ".IPShare");
        feeReceiver = vm.parseJsonAddress(json, ".FeeReceiver");
        calculator = vm.parseJsonAddress(json, ".HourlyTickCalculator");
        dfxFactory = vm.parseJsonAddress(json, ".DFXStarScoreStakingFactory");
        dfxStaking = vm.parseJsonAddress(json, ".DFXStarScoreStaking");
        create2Deployer = vm.parseJsonAddress(json, ".Create2Deployer");
        previousPump = vm.parseJsonAddress(json, ".PreviousPump");
        require(vm.parseJsonAddress(json, ".Pump") == previousPump, "V11 Pump baseline changed");
    }

    function _validateDependencies() internal view {
        require(committee.code.length > 0, "Committee missing");
        require(communityFactory.code.length > 0, "CommunityFactory missing");
        require(socialCurationFactory.code.length > 0, "SocialCurationFactory missing");
        require(clPoolManager.code.length > 0, "CLPoolManager missing");
        require(vault.code.length > 0, "Vault missing");
        require(ipshare.code.length > 0, "IPShare missing");
        require(calculator.code.length > 0, "Calculator missing");
        require(dfxFactory.code.length > 0, "DFX factory missing");
        require(dfxStaking.code.length > 0, "DFX staking missing");
        require(create2Deployer.code.length > 0, "CREATE2 deployer missing");
        require(ICommittee(committee).verifyContract(calculator), "Calculator not whitelisted");
        require(Ownable(committee).owner() != address(0), "Committee owner missing");
    }

    function _validateDeployment(Pump pump, TagAISwapHook hook, address targetOwner) internal view {
        require(address(pump).code.length > 0, "Pump deployment failed");
        require(pump.tokenImplementation().code.length > 0, "Token implementation missing");
        require(address(hook).code.length > 0, "Hook deployment failed");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
        require(pump.getIPShare() == ipshare, "Pump IPShare mismatch");
        require(pump.getFeeReceiver() == feeReceiver, "Pump fee receiver mismatch");
        require(pump.getPoolManager() == clPoolManager, "Pump pool manager mismatch");
        require(pump.getVault() == vault, "Pump Vault mismatch");
        require(pump.getHookAddress() == address(hook), "Pump Hook mismatch");
        require(pump.getCalculator() == calculator, "Pump Calculator mismatch");
        require(pump.nutboxCommunityFactory() == communityFactory, "Pump CommunityFactory mismatch");
        require(pump.socialCurationFactory() == socialCurationFactory, "Pump SocialCurationFactory mismatch");
        require(pump.nutboxCommittee() == committee, "Pump Committee mismatch");
        if (targetOwner != pump.owner()) require(pump.pendingOwner() == targetOwner, "Pump owner handover missing");
    }

    function _writeAddresses(Pump pump, TagAISwapHook hook, bytes32 hookSalt, address deployer, address targetOwner)
        internal
    {
        _requireVersion11Status("preparing");
        _writeAddress(".deployer", deployer);
        _writeAddress(".PumpDeployer", deployer);
        _writeAddress(".PumpTargetOwner", targetOwner);
        _writeBool(".PumpOwnershipAccepted", targetOwner == deployer);
        _writeAddress(".Pump", address(pump));
        _writeAddress(".TokenImplementation", pump.tokenImplementation());
        _writeAddress(".TagAISwapHook", address(hook));
        _writeUint(".HookSalt", uint256(hookSalt));
        _writeString(".status", "pump-deployed");
    }

    function _requireVersion11Status(string memory expected) internal view {
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");
        require(_sameString(vm.parseJsonString(json, ".status"), expected), "Unexpected V11 deployment status");
    }

    function _writeAddress(string memory key, address value) internal {
        vm.writeJson(string.concat('"', vm.toString(value), '"'), VERSION11_PATH, key);
    }

    function _writeUint(string memory key, uint256 value) internal {
        vm.writeJson(vm.toString(value), VERSION11_PATH, key);
    }

    function _writeBool(string memory key, bool value) internal {
        vm.writeJson(value ? "true" : "false", VERSION11_PATH, key);
    }

    function _writeString(string memory key, string memory value) internal {
        vm.writeJson(string.concat('"', value, '"'), VERSION11_PATH, key);
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function mineSalt(address deployer, bytes32 bytecodeHash)
        internal
        pure
        returns (bytes32 salt, address predictedAddress, uint256 iterations)
    {
        for (uint256 i = 0; i < MAX_MINING_ITERATIONS; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
            predictedAddress = address(uint160(uint256(hash)));
            if (uint16(uint160(predictedAddress)) == TARGET_BITMAP) {
                return (salt, predictedAddress, i + 1);
            }
        }
        revert("No valid salt found");
    }
}
