// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TagAITradeRouter} from "../src/router/TagAITradeRouter.sol";

interface ITradePumpDeployment {
    function nutboxRouter() external view returns (address);
    function pancakeV2Factory() external view returns (address);
}

/// @notice Deploys only the standalone trade executor. Existing Pump, pools and permissions are unchanged.
contract DeployBSCTagAITradeRouterScript is Script {
    function run() external returns (TagAITradeRouter executor) {
        require(block.chainid == 56, "BSC mainnet only");
        address pump = vm.envOr("TRADE_ROUTER_PUMP", address(0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa));
        address router = vm.envOr("TRADE_ROUTER_NUTBOX", address(0x72dc4F38A7E4159e97d826a6ab594748C6b68f17));
        address factory = vm.envOr("TRADE_ROUTER_V2_FACTORY", address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73));
        require(ITradePumpDeployment(pump).nutboxRouter() == router, "Pump router mismatch");
        require(ITradePumpDeployment(pump).pancakeV2Factory() == factory, "Pump factory mismatch");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY_MAIN"));
        executor = new TagAITradeRouter(pump, router, factory);
        vm.stopBroadcast();
        console2.log("TagAITradeRouter", address(executor));
        console2.log("Pump", pump);
        console2.log("NutboxRouter", router);
        console2.log("Pancake V2 factory", factory);
    }
}
