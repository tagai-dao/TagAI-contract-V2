// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

// Production contracts
import {Pump} from "../src/pump/Pump.sol";
import {HourlyTickCalculator} from "../src/nutbox/calculators/HourlyTickCalculator.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";

// PCS V4 types
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

// Interfaces for verification
import {ICommittee} from "../src/interfaces/ICommittee.sol";

/**
 * @title DeployBSCTwoPhase
 * @notice BSC mainnet deployment script with automatic salt mining.
 *
 * This script performs deployment in two phases within a single broadcast:
 *   Phase 1: Deploy HourlyTickCalculator and Pump
 *   Phase 2: Mine salt for Hook, then deploy TagAISwapHook with CREATE2
 *   Phase 3: Configure Pump
 *
 * The Hook address must satisfy: address & 0xFFFF == 0x0CC1
 *
 * Important: In Foundry's CREATE2 deployment with `new Contract{salt: ...}()`,
 * the deployer is the sender of the transaction (msg.sender), not the script address.
 *
 * Usage:
 *   forge script script/DeployBSCTwoPhase.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify
 *
 * Note: Uses PRIVATE_KEY_MAIN from .env for mainnet deployment
 */
contract DeployBSCTwoPhaseScript is Script {
    // ─── BSC Deployed Addresses (Reused) ─────────────────────────────────────────
    address constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;

    // IPShare v1 deployed address
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;

    // Fee receiver for Pump
    address constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    // Target hook bitmap: 0x0CC1
    uint16 constant TARGET_BITMAP = 0x0CC1;

    // Maximum salt mining iterations
    uint256 constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() public {
        // Use PRIVATE_KEY_MAIN for mainnet deployment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== TagAI V2 BSC Deployment (Two-Phase) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 56, "This script is for BSC mainnet (chainId 56)");
        console.log("");

        console.log("--- Reused Contracts ---");
        console.log("  Committee:              ", COMMITTEE);
        console.log("  CommunityFactory:       ", COMMUNITY_FACTORY);
        console.log("  SocialCurationFactory:  ", SOCIAL_CURATION_FACTORY);
        console.log("  CLPoolManager:          ", CL_POOL_MANAGER);
        console.log("  Vault:                  ", VAULT);
        console.log("  IPShare (v1):           ", IPSHARE);
        console.log("");

        // ═══════════════════════════════════════════════════════════════════════════
        // PHASE 1: Deploy HourlyTickCalculator and Pump
        // ═══════════════════════════════════════════════════════════════════════════

        console.log("--- Phase 1: Deploy Calculator and Pump ---");

        vm.startBroadcast(deployerPrivateKey);

        HourlyTickCalculator calculator = new HourlyTickCalculator(COMMUNITY_FACTORY);
        console.log("(1) HourlyTickCalculator:", address(calculator));

        Pump pump = new Pump(IPSHARE, FEE_RECEIVER);
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);
        console.log("(2) Pump:", address(pump));

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════════════════════
        // PHASE 2: Mine salt and deploy TagAISwapHook
        // ═══════════════════════════════════════════════════════════════════════════

        console.log("");
        console.log("--- Phase 2: Mine Salt and Deploy Hook ---");

        // Get creation bytecode with constructor args
        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode,
            abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("(3) Mining salt for Hook...");
        console.log("    Pump address:", address(pump));
        console.log("    Deployer:", deployer);
        console.log("    Bytecode hash:");
        console.logBytes32(bytecodeHash);

        // Mine for salt (deployer is the CREATE2 deployer)
        (bytes32 hookSalt, address predictedAddress, uint256 iterations) = mineSalt(deployer, bytecodeHash);

        console.log("    Found salt after %d iterations", iterations);
        console.log("    Salt (decimal): %d", uint256(hookSalt));
        console.log("    Salt (hex):");
        console.logBytes32(hookSalt);
        console.log("    Predicted Hook address:", predictedAddress);
        console.log("    Predicted address lower 16 bits: 0x%04x", uint16(uint160(predictedAddress)));

        // Deploy Hook with mined salt
        vm.startBroadcast(deployerPrivateKey);

        TagAISwapHook hook = new TagAISwapHook{salt: hookSalt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            address(pump)
        );

        // Verify deployed address matches prediction
        require(address(hook) == predictedAddress, "Hook address mismatch!");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook address does not have correct bitmap!");

        console.log("(4) TagAISwapHook deployed:", address(hook));
        console.log("    Address lower 16 bits: 0x%04x (target: 0x0CC1)", uint16(uint160(address(hook))));

        // ═══════════════════════════════════════════════════════════════════════════
        // PHASE 3: Configure Pump
        // ═══════════════════════════════════════════════════════════════════════════

        console.log("");
        console.log("--- Phase 3: Configure Pump ---");

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(
            COMMUNITY_FACTORY,
            address(calculator),
            SOCIAL_CURATION_FACTORY,
            COMMITTEE
        );
        console.log("(5) Pump configured: hookAddress, calculator, nutbox set");

        vm.stopBroadcast();

        // ─── Verify Committee whitelist ──────────────────────────────────────────
        console.log("");
        console.log("--- Post-Deployment Verification ---");

        bool isWhitelisted = ICommittee(COMMITTEE).verifyContract(address(calculator));
        if (isWhitelisted) {
            console.log("(6) VERIFIED: Calculator is whitelisted in Committee");
        } else {
            console.log("(6) WARNING: Calculator is NOT whitelisted in Committee!");
            console.log("    Committee owner must call:");
            console.log("    Committee.adminAddContract(", address(calculator), ")");
            console.log("    before Pump.createToken can succeed.");
        }

        // ─── Output Summary ──────────────────────────────────────────────────────
        console.log("");
        console.log("=== BSC Deployment Complete ===");
        console.log("--- Newly Deployed ---");
        console.log("  HourlyTickCalculator:", address(calculator));
        console.log("  Pump:                ", address(pump));
        console.log("  TagAISwapHook:       ", address(hook));
        console.log("--- Hook Salt (for record) ---");
        console.log("  Salt (decimal): %d", uint256(hookSalt));
        console.log("--- Configuration ---");
        console.log("  Pump.hookAddress:    ", address(hook));
        console.log("  Pump.calculator:     ", address(calculator));
        console.log("  Pump.committee:      ", COMMITTEE);
        console.log("  Pump.communityFactory:", COMMUNITY_FACTORY);
        console.log("  Pump.socialCurationFactory:", SOCIAL_CURATION_FACTORY);
        console.log("");
    }

    /**
     * @notice Mine for a salt that produces a valid hook address.
     * @dev Uses CREATE2 address formula: address = keccak256(0xff ++ deployer ++ salt ++ bytecodeHash)[12:]
     */
    function mineSalt(
        address deployer,
        bytes32 bytecodeHash
    ) internal pure returns (bytes32 salt, address predictedAddress, uint256 iterations) {
        for (uint256 i = 0; i < MAX_MINING_ITERATIONS; i++) {
            salt = bytes32(i);

            // Compute CREATE2 address
            bytes32 hash = keccak256(
                abi.encodePacked(
                    bytes1(0xff),
                    deployer,
                    salt,
                    bytecodeHash
                )
            );
            predictedAddress = address(uint160(uint256(hash)));

            // Check if lower 16 bits match target
            if (uint16(uint160(predictedAddress)) == TARGET_BITMAP) {
                return (salt, predictedAddress, i + 1);
            }
        }

        revert("No valid salt found within iteration limit");
    }
}
