// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TagAITradeRouter} from "../src/router/TagAITradeRouter.sol";
import {CommentBuyAdapter} from "../src/helper/CommentBuyAdapter.sol";

interface IMultiPumpDeployment {
    function nutboxRouter() external view returns (address);
    function pancakeV2Factory() external view returns (address);
}
interface IMultiPumpHook { function pump() external view returns (address); }

/// @notice Deploy replacements supporting V13 + V14. Does not touch the existing custody Vault.
/// @dev The target owner must accept both ownerships and then switch the Vault adapter.
contract DeployBSCMultiPumpTradingScript is Script {
    function run() external returns (TagAITradeRouter router, CommentBuyAdapter adapter) {
        require(block.chainid == 56, "BSC mainnet only");
        string memory v13 = vm.readFile("deployments/56/version13.json");
        string memory v14 = vm.readFile("deployments/56/version14.json");
        string memory v11 = vm.readFile("deployments/56/version11.json");
        address pump13 = vm.parseJsonAddress(v13, ".Pump");
        address pump14 = vm.parseJsonAddress(v14, ".Pump");
        address hook13 = vm.parseJsonAddress(v13, ".TagAISwapHook");
        address hook14 = vm.parseJsonAddress(v14, ".TagAISwapHook");
        address nutbox = vm.parseJsonAddress(v14, ".NutboxRouter");
        address factory = vm.parseJsonAddress(v14, ".PancakeV2Factory");
        address wrapper = vm.parseJsonAddress(v11, ".ImportedTokenSwapWrapper");
        address targetOwner = vm.parseJsonAddress(v14, ".targetOwner");
        require(targetOwner != address(0) && pump13 != pump14, "Invalid deployment configuration");
        require(IMultiPumpDeployment(pump13).nutboxRouter() == nutbox && IMultiPumpDeployment(pump14).nutboxRouter() == nutbox, "Router mismatch");
        require(IMultiPumpDeployment(pump13).pancakeV2Factory() == factory && IMultiPumpDeployment(pump14).pancakeV2Factory() == factory, "Factory mismatch");
        require(IMultiPumpHook(hook13).pump() == pump13 && IMultiPumpHook(hook14).pump() == pump14, "Hook mismatch");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_MAIN"));
        router = new TagAITradeRouter(pump13, nutbox, factory);
        router.setPump(pump14, true);
        adapter = new CommentBuyAdapter(address(router), hook13, wrapper);
        // Existing V13/V14 Hook fees are both 30/30/30 bps; no fee changes.
        adapter.setHookPolicy(hook14, true, 30, 30, 30);
        if (router.owner() != targetOwner) router.transferOwnership(targetOwner);
        if (adapter.owner() != targetOwner) adapter.transferOwnership(targetOwner);
        vm.stopBroadcast();

        require(router.pumpEnabled(pump13) && router.pumpEnabled(pump14), "Pump registration failed");
        require(address(adapter.router()) == address(router), "Adapter binding failed");
        console2.log("TagAITradeRouter", address(router));
        console2.log("CommentBuyAdapter", address(adapter));
        console2.log("Target owner", targetOwner);
        console2.log("NEXT: accept both ownerships; existing Vault owner calls setAdapter(new adapter).");
    }
}
