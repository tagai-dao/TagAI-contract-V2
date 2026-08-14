// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
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
 * Usage (broadcast + verify; only write the candidate record after success):
 *   WRITE_DEPLOYMENTS=true forge script script/DeployBSCPumpRefresh.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * Set PUMP_OWNER to initiate Ownable2Step ownership handover. The canonical
 * deployments/56/addresses.json is intentionally never overwritten here.
 */
contract DeployBSCPumpRefreshScript is Script {
    string constant OUTPUT_PATH = "deployments/56/pump-refresh.json";

    // ─── Reused BSC infrastructure ───────────────────────────────────────────
    address constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    // ─── Reused from previous V9 deploy (no Committee re-whitelist needed) ───
    address constant CALCULATOR = 0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d;
    address constant DFX_FACTORY = 0x77Fb65140B746e639bB512c2C25604d1924aE774;
    address constant DFX_STAKING = 0x2D91b9a98A49C8dd2CF68Be2F8ABbFB3a78C2eae;

    uint16 constant TARGET_BITMAP = 0x0CC1;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);
        address targetOwner = vm.envOr("PUMP_OWNER", deployer);
        bool writeDeployments = vm.envOr("WRITE_DEPLOYMENTS", false);

        require(block.chainid == 56, "BSC mainnet only (chainId 56)");
        _validateDependencies();

        console.log("=== BSC Pump Refresh Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Reusing Calculator:", CALCULATOR);
        console.log("Reusing DFXStarScoreStakingFactory:", DFX_FACTORY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        Pump pump = new Pump(IPSHARE, FEE_RECEIVER);
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);
        console.log("Pump:", address(pump));
        console.log("TokenImplementation:", pump.tokenImplementation());

        vm.stopBroadcast();

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode, abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("Mining Hook salt for Pump:", address(pump));
        (bytes32 hookSalt, address predictedHook, uint256 iterations) = mineSalt(CREATE2_DEPLOYER, bytecodeHash);
        console.log("  iterations:", iterations);
        console.log("  HookSalt:", uint256(hookSalt));
        console.log("  predicted Hook:", predictedHook);

        vm.startBroadcast(deployerPrivateKey);

        TagAISwapHook hook =
            new TagAISwapHook{salt: hookSalt}(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump));
        require(address(hook) == predictedHook, "Hook address mismatch");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
        console.log("TagAISwapHook:", address(hook));

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(CALCULATOR);
        pump.adminSetNutbox(COMMUNITY_FACTORY, CALCULATOR, SOCIAL_CURATION_FACTORY, COMMITTEE);
        if (targetOwner != deployer) pump.transferOwnership(targetOwner);
        console.log("Pump configured");

        vm.stopBroadcast();

        _validateDeployment(pump, hook, targetOwner);

        if (writeDeployments) {
            _writeAddresses(pump, hook, hookSalt, deployer, targetOwner);
            console.log("Candidate deployment record written:", OUTPUT_PATH);
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

    function _validateDependencies() internal view {
        require(COMMITTEE.code.length > 0, "Committee missing");
        require(COMMUNITY_FACTORY.code.length > 0, "CommunityFactory missing");
        require(SOCIAL_CURATION_FACTORY.code.length > 0, "SocialCurationFactory missing");
        require(CL_POOL_MANAGER.code.length > 0, "CLPoolManager missing");
        require(VAULT.code.length > 0, "Vault missing");
        require(IPSHARE.code.length > 0, "IPShare missing");
        require(CALCULATOR.code.length > 0, "Calculator missing");
        require(DFX_FACTORY.code.length > 0, "DFX factory missing");
        require(DFX_STAKING.code.length > 0, "DFX staking missing");
        require(ICommittee(COMMITTEE).verifyContract(CALCULATOR), "Calculator not whitelisted");
        require(Ownable(COMMITTEE).owner() != address(0), "Committee owner missing");
    }

    function _validateDeployment(Pump pump, TagAISwapHook hook, address targetOwner) internal view {
        require(address(pump).code.length > 0, "Pump deployment failed");
        require(pump.tokenImplementation().code.length > 0, "Token implementation missing");
        require(address(hook).code.length > 0, "Hook deployment failed");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
        require(pump.getIPShare() == IPSHARE, "Pump IPShare mismatch");
        require(pump.getFeeReceiver() == FEE_RECEIVER, "Pump fee receiver mismatch");
        require(pump.getPoolManager() == CL_POOL_MANAGER, "Pump pool manager mismatch");
        require(pump.getVault() == VAULT, "Pump Vault mismatch");
        require(pump.getHookAddress() == address(hook), "Pump Hook mismatch");
        require(pump.getCalculator() == CALCULATOR, "Pump Calculator mismatch");
        require(pump.nutboxCommunityFactory() == COMMUNITY_FACTORY, "Pump CommunityFactory mismatch");
        require(pump.socialCurationFactory() == SOCIAL_CURATION_FACTORY, "Pump SocialCurationFactory mismatch");
        require(pump.nutboxCommittee() == COMMITTEE, "Pump Committee mismatch");
        if (targetOwner != pump.owner()) require(pump.pendingOwner() == targetOwner, "Pump owner handover missing");
    }

    function _writeAddresses(Pump pump, TagAISwapHook hook, bytes32 hookSalt, address deployer, address targetOwner)
        internal
    {
        string memory objectKey = "pumpRefresh";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "targetOwner", targetOwner);
        vm.serializeAddress(objectKey, "Committee", COMMITTEE);
        vm.serializeAddress(objectKey, "CommunityFactory", COMMUNITY_FACTORY);
        vm.serializeAddress(objectKey, "HourlyTickCalculator", CALCULATOR);
        vm.serializeAddress(objectKey, "SocialCurationFactory", SOCIAL_CURATION_FACTORY);
        vm.serializeAddress(objectKey, "DFXStarScoreStakingFactory", DFX_FACTORY);
        vm.serializeAddress(objectKey, "DFXStarScoreStaking", DFX_STAKING);
        vm.serializeAddress(objectKey, "IPShare", IPSHARE);
        vm.serializeAddress(objectKey, "CLPoolManager", CL_POOL_MANAGER);
        vm.serializeAddress(objectKey, "Vault", VAULT);
        vm.serializeAddress(objectKey, "Pump", address(pump));
        vm.serializeAddress(objectKey, "TokenImplementation", pump.tokenImplementation());
        vm.serializeAddress(objectKey, "TagAISwapHook", address(hook));
        string memory json = vm.serializeUint(objectKey, "HookSalt", uint256(hookSalt));
        vm.writeJson(json, OUTPUT_PATH);
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
