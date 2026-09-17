// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {CommentBuyAdapter} from "../src/helper/CommentBuyAdapter.sol";
import {CommentTradeVault} from "../src/helper/CommentTradeVault.sol";

/// @notice Deploys and connects the BSC comment-buy adapter and custody vault.
contract DeployBSCCommentTradingScript is Script {
    string internal constant VERSION13_PATH = "deployments/56/version13.json";
    string internal constant VERSION11_PATH = "deployments/56/version11.json";

    address internal constant EXECUTOR = 0x1c89373063F9c2cEe23Bc5F04D0575984a4efaF2;

    function run() external returns (CommentBuyAdapter adapter, CommentTradeVault vault) {
        require(block.chainid == 56, "BSC mainnet only");

        string memory version13 = vm.readFile(VERSION13_PATH);
        string memory version11 = vm.readFile(VERSION11_PATH);

        address tradeRouter = vm.parseJsonAddress(version13, ".TagAITradeRouter");
        address reviewedHook = vm.parseJsonAddress(version13, ".TagAISwapHook");
        address feeReceiver = vm.parseJsonAddress(version13, ".FeeReceiver");
        address targetOwner = vm.parseJsonAddress(version13, ".targetOwner");
        address importedWrapper = vm.parseJsonAddress(version11, ".ImportedTokenSwapWrapper");

        require(tradeRouter.code.length > 0, "Trade router missing");
        require(reviewedHook.code.length > 0, "Reviewed hook missing");
        require(importedWrapper.code.length > 0, "Imported wrapper missing");
        require(feeReceiver != address(0), "Fee receiver missing");
        require(targetOwner != address(0), "Owner missing");

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);

        console2.log("=== BSC Comment Trading Deploy ===");
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("Executor", EXECUTOR);
        console2.log("Fee receiver", feeReceiver);
        console2.log("Trade router", tradeRouter);
        console2.log("Reviewed hook", reviewedHook);
        console2.log("Imported wrapper", importedWrapper);

        vm.startBroadcast(privateKey);

        adapter = new CommentBuyAdapter(tradeRouter, reviewedHook, importedWrapper);
        vault = new CommentTradeVault(EXECUTOR, feeReceiver, address(adapter));

        if (targetOwner != deployer) {
            vault.transferOwnership(targetOwner);
        }

        vm.stopBroadcast();

        require(address(vault.adapter()) == address(adapter), "Adapter binding failed");
        require(vault.executor() == EXECUTOR, "Executor mismatch");
        require(vault.feeReceiver() == feeReceiver, "Fee receiver mismatch");

        if (targetOwner == deployer) {
            require(vault.owner() == targetOwner, "Owner mismatch");
        } else {
            require(vault.pendingOwner() == targetOwner, "Vault pending owner mismatch");
        }

        console2.log("CommentBuyAdapter", address(adapter));
        console2.log("CommentTradeVault", address(vault));
        if (targetOwner != deployer) {
            console2.log("ACTION: target owner must accept ownership on CommentTradeVault", targetOwner);
        }
    }
}
