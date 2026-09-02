// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {NutboxCommunityFeeHook} from "../src/hook/NutboxCommunityFeeHook.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Deploys only NutboxCommunityFeeHook on RH mainnet. It does not configure a pool
///         and does not initiate an ownership transfer.
contract DeployRHNutboxCommunityFeeHookScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    function run() external returns (NutboxCommunityFeeHook hook) {
        require(block.chainid == RH_MAINNET_CHAIN_ID, "RH mainnet only");
        require(RH_POOL_MANAGER.code.length != 0, "PoolManager missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        bytes memory constructorArgs = abi.encode(IPoolManager(RH_POOL_MANAGER), deployer);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(NutboxCommunityFeeHook).creationCode, constructorArgs);

        console2.log("Deployer", deployer);
        console2.log("PoolManager", RH_POOL_MANAGER);
        console2.log("Predicted Hook", predicted);
        console2.log("CREATE2 salt", uint256(salt));

        vm.startBroadcast(privateKey);
        hook = new NutboxCommunityFeeHook{salt: salt}(IPoolManager(RH_POOL_MANAGER), deployer);
        vm.stopBroadcast();

        require(address(hook) == predicted, "CREATE2 address mismatch");
        require(uint160(address(hook)) & ((1 << 14) - 1) == HOOK_FLAGS, "invalid hook flags");
        require(hook.owner() == deployer, "unexpected owner");
        require(address(hook.poolManager()) == RH_POOL_MANAGER, "unexpected PoolManager");

        console2.log("NutboxCommunityFeeHook", address(hook));
        console2.log("Owner", hook.owner());
    }
}
