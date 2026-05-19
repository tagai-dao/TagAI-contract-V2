// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

// Import the actual hook contract to get its bytecode
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";

// PCS V4 types
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

/**
 * @title MineHookSalt
 * @notice Brute-force mine CREATE2 salt for TagAISwapHook deployment.
 *
 * PancakeSwap V4 requires hook addresses to have specific flags encoded
 * in the lower 16 bits of the address. TagAISwapHook's bitmap is:
 *   (1<<0) | (1<<6) | (1<<7) | (1<<10) | (1<<11) = 0x0CC1
 *
 * The deployed address must satisfy: address & 0xFFFF == 0x0CC1
 *
 * Usage:
 *   1. First deploy Pump to get its address
 *   2. Set PUMP_ADDRESS environment variable
 *   3. Run: forge script script/MineHookSalt.s.sol -vvv
 *
 * Or use the two-phase approach in DeployBSC.s.sol
 */
contract MineHookSaltScript is Script {
    // Target hook bitmap: 0x0CC1
    uint16 constant TARGET_BITMAP = 0x0CC1;

    // Deployment parameters (matching DeployBSC.s.sol)
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;

    function run() public {
        // Read pump address from environment (must be set after Pump deployment)
        address pumpAddress = vm.envAddress("PUMP_ADDRESS");

        console.log("=== Hook Salt Mining ===");
        console.log("Target bitmap: 0x%04x", TARGET_BITMAP);
        console.log("CLPoolManager:", CL_POOL_MANAGER);
        console.log("Vault:", VAULT);
        console.log("Pump address:", pumpAddress);
        console.log("");

        // Get creation bytecode with constructor args
        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode,
            abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), pumpAddress)
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("Bytecode hash:");
        console.logBytes32(bytecodeHash);
        console.log("");

        // Mine for salt
        // In Foundry, the deployer is the script address during broadcast
        // But for CREATE2, we need the actual deployer address
        address deployer = msg.sender; // This will be the caller (deployer)

        console.log("Deployer:", deployer);
        console.log("Mining started...");
        console.log("");

        (bytes32 salt, address predictedAddress, uint256 iterations) = mineSalt(deployer, bytecodeHash);

        console.log("=== Mining Result ===");
        console.log("Found salt after %d iterations", iterations);
        console.log("Salt (hex):");
        console.logBytes32(salt);
        console.log("Salt (decimal): %d", uint256(salt));
        console.log("Predicted hook address:", predictedAddress);
        console.log("Address lower 16 bits: 0x%04x", uint16(uint160(predictedAddress)));
        console.log("");

        // Verify
        require(uint16(uint160(predictedAddress)) == TARGET_BITMAP, "Address does not match target bitmap");
        console.log("VERIFIED: Address matches target bitmap 0x0CC1");
        console.log("");
        console.log("=== Copy this to DeployBSC.s.sol ===");
        console.log("bytes32 constant HOOK_SALT = bytes32(uint256(%d));", uint256(salt));
        console.log("// Expected Hook address: %s", predictedAddress);
    }

    /**
     * @notice Mine for a salt that produces a valid hook address.
     * @dev Uses CREATE2 address formula: address = keccak256(0xff ++ deployer ++ salt ++ bytecodeHash)[12:]
     */
    function mineSalt(
        address deployer,
        bytes32 bytecodeHash
    ) internal pure returns (bytes32 salt, address predictedAddress, uint256 iterations) {
        uint256 maxIterations = 100_000_000; // Safety limit

        for (uint256 i = 0; i < maxIterations; i++) {
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
