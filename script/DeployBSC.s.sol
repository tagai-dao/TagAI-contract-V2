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
 * @title DeployBSC
 * @notice BSC mainnet deployment script. Reuses already-deployed Nutbox stack + IPShare.
 *
 * Deployment order:
 *   (1) HourlyTickCalculator
 *   (2) Pump
 *   (3) TagAISwapHook (CREATE2 with mined salt)
 *   (4) Pump.adminSetHookAddress / adminSetCalculator / adminSetNutbox
 *   (5) Verify Committee.verifyContract(Calculator) == true
 *
 * Pre-requisites:
 *   - Committee owner must call adminAddContract(calculatorAddress) BEFORE
 *     Pump.createToken can succeed. This script checks the whitelist status
 *     but cannot add the contract unless the deployer is the Committee owner.
 *
 * Usage:
 *   forge script script/DeployBSC.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify
 *
 * Note: Uses PRIVATE_KEY_MAIN from .env for mainnet deployment
 */
contract DeployBSCScript is Script {
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

    // ─── Hook Salt (Mined for address with lower 16 bits = 0x0CC1) ─────────────
    // This salt is mined using MineHookSalt.s.sol after Pump is deployed
    // TODO: Update this salt after running MineHookSalt.s.sol with the deployed Pump address
    bytes32 constant HOOK_SALT = bytes32(uint256(0x1)); // Placeholder - must be mined

    // Target hook bitmap for verification
    uint16 constant TARGET_BITMAP = 0x0CC1;

    function run() public {
        // Use PRIVATE_KEY_MAIN for mainnet deployment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== TagAI V2 BSC Deployment ===");
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

        vm.startBroadcast(deployerPrivateKey);

        // ─── (1) Deploy HourlyTickCalculator ─────────────────────────────────────
        HourlyTickCalculator calculator = new HourlyTickCalculator(COMMUNITY_FACTORY);
        console.log("(1) HourlyTickCalculator:", address(calculator));

        // ─── (2) Deploy Pump ─────────────────────────────────────────────────────
        Pump pump = new Pump(IPSHARE, FEE_RECEIVER);
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);
        console.log("(2) Pump:", address(pump));

        // ─── (3) Deploy TagAISwapHook (CREATE2) ──────────────────────────────────
        // The salt must be mined so that the deployed address has lower 16 bits = 0x0CC1
        // Run MineHookSalt.s.sol with PUMP_ADDRESS=<pump address> to find the correct salt
        TagAISwapHook hook = new TagAISwapHook{salt: HOOK_SALT}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            address(pump)
        );
        console.log("(3) TagAISwapHook (CREATE2):", address(hook));

        // Verify hook address has correct bitmap
        uint16 addressBitmap = uint16(uint160(address(hook)));
        console.log("    Hook address lower 16 bits: 0x%04x", addressBitmap);
        require(addressBitmap == TARGET_BITMAP, "Hook address does not have correct bitmap!");

        // ─── (4) Configure Pump ──────────────────────────────────────────────────
        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(
            COMMUNITY_FACTORY,
            address(calculator),
            SOCIAL_CURATION_FACTORY,
            COMMITTEE
        );
        console.log("(4) Pump configured: hookAddress, calculator, nutbox set");

        vm.stopBroadcast();

        // ─── (5) Verify Committee whitelist ──────────────────────────────────────
        bool isWhitelisted = ICommittee(COMMITTEE).verifyContract(address(calculator));
        if (isWhitelisted) {
            console.log("(5) VERIFIED: Calculator is whitelisted in Committee");
        } else {
            console.log("(5) WARNING: Calculator is NOT whitelisted in Committee!");
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
        console.log("--- Configuration ---");
        console.log("  Pump.hookAddress:    ", address(hook));
        console.log("  Pump.calculator:     ", address(calculator));
        console.log("  Pump.committee:      ", COMMITTEE);
        console.log("  Pump.communityFactory:", COMMUNITY_FACTORY);
        console.log("  Pump.socialCurationFactory:", SOCIAL_CURATION_FACTORY);
        console.log("");
        console.log("// Post-process: save output to deployments/56/addresses.json");
    }
}
