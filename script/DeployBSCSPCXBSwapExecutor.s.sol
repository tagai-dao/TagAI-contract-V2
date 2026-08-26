// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SPCXBSwapExecutor} from "../src/helper/SPCXBSwapExecutor.sol";

/**
 * @title DeployBSCSPCXBSwapExecutor
 * @notice Deploys the fee-preserving SPCXB deep-liquidity route on BSC.
 *
 * Dry run:
 *   forge script script/DeployBSCSPCXBSwapExecutor.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast only after SPCXB_FEE_ADDRESS and SPCXB_EXECUTOR_OWNER are reviewed:
 *   forge script script/DeployBSCSPCXBSwapExecutor.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy -vv
 */
contract DeployBSCSPCXBSwapExecutorScript is Script {
    address internal constant PANCAKE_V3_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        require(vm.envExists("SPCXB_FEE_ADDRESS"), "SPCXB_FEE_ADDRESS must be explicit");
        require(vm.envExists("SPCXB_EXECUTOR_OWNER"), "SPCXB_EXECUTOR_OWNER must be explicit");
        address feeAddress = vm.envAddress("SPCXB_FEE_ADDRESS");
        address targetOwner = vm.envAddress("SPCXB_EXECUTOR_OWNER");

        require(feeAddress != address(0), "fee address missing");
        require(targetOwner != address(0), "owner missing");
        require(PANCAKE_V3_SMART_ROUTER.code.length > 0, "SmartRouter missing");
        require(IPSHARE.code.length > 0, "IPShare missing");
        require(WBNB.code.length > 0, "WBNB missing");
        require(USDT.code.length > 0, "USDT missing");
        require(SPCXB.code.length > 0, "SPCXB missing");

        console2.log("=== BSC SPCXB Swap Executor Deploy ===");
        console2.log("Deployer", deployer);
        console2.log("Fee address", feeAddress);
        console2.log("Target owner", targetOwner);

        vm.startBroadcast(privateKey);
        SPCXBSwapExecutor executor =
            new SPCXBSwapExecutor(PANCAKE_V3_SMART_ROUTER, IPSHARE, WBNB, USDT, SPCXB, feeAddress);
        if (targetOwner != deployer) executor.transferOwnership(targetOwner);
        vm.stopBroadcast();

        require(address(executor).code.length > 0, "executor deployment failed");
        require(executor.feeAddress() == feeAddress, "fee address mismatch");
        require(executor.creatorFeeBps() == 20, "creator fee mismatch");
        require(executor.tagaiFeeBps() == 20, "TagAI fee mismatch");
        require(executor.owner() == deployer, "unexpected current owner");
        require(
            executor.pendingOwner() == (targetOwner == deployer ? address(0) : targetOwner), "pending owner mismatch"
        );

        console2.log("SPCXBSwapExecutor", address(executor));
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept ownership", targetOwner);
        }
        console2.log("ACTION REQUIRED: set SPCXB_SWAP_EXECUTOR in the BSC API environment");
    }
}
