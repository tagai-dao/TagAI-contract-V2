// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CommentTradeVault} from "../src/helper/CommentTradeVault.sol";

/// @notice Deploys a replacement Vault using the existing permissionless Adapter.
/// @dev Record new addresses only after confirmed broadcast; users migrate funds and grants separately.
contract DeployBSCCommentTradeVaultScript is Script {
    address internal constant EXECUTOR = 0xf041Fd6B930cc9d3ea7496A7E3f0D2a5463f1888;

    function run() external returns (CommentTradeVault vault) {
        require(block.chainid == 56, "BSC mainnet only");
        string memory json = vm.readFile("deployments/56/version13.json");
        address adapter = vm.parseJsonAddress(json, ".CommentBuyAdapter");
        address feeReceiver = vm.parseJsonAddress(json, ".CommentTradeVaultFeeReceiver");
        address targetOwner = vm.parseJsonAddress(json, ".CommentTradeVaultTargetOwner");
        require(adapter.code.length > 0, "Adapter missing");
        require(feeReceiver != address(0), "Fee receiver missing");
        require(targetOwner != address(0), "Owner missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        console2.log("Deployer", deployer);
        console2.log("Existing CommentBuyAdapter", adapter);
        console2.log("Executor", EXECUTOR);
        console2.log("Fee receiver", feeReceiver);
        console2.log("Target owner", targetOwner);

        vm.startBroadcast(privateKey);
        vault = new CommentTradeVault(EXECUTOR, feeReceiver, adapter);
        if (targetOwner != deployer) vault.transferOwnership(targetOwner);
        vm.stopBroadcast();

        require(address(vault.adapter()) == adapter, "Adapter mismatch");
        require(vault.executor() == EXECUTOR, "Executor mismatch");
        require(vault.feeReceiver() == feeReceiver, "Fee receiver mismatch");
        require(vault.owner() == deployer, "Owner mismatch");
        if (targetOwner != deployer) {
            require(vault.pendingOwner() == targetOwner, "Pending owner mismatch");
        }

        console2.log("CommentTradeVault", address(vault));
        if (targetOwner != deployer) {
            console2.log("ACTION: target owner must accept ownership on the new Vault", targetOwner);
        }
    }
}
