// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TagAITradeRouter} from "../src/router/TagAITradeRouter.sol";
import {TagAILiquidityRouter} from "../src/router/TagAILiquidityRouter.sol";

contract DeployBSCTagAILiquidityRouterScript is Script {
    function run() external returns (TagAILiquidityRouter router) {
        require(block.chainid == 56, "BSC mainnet only");
        address executor = vm.envAddress("BSC_V13_TRADE_ROUTER");
        address expectedPump = vm.envOr("TRADE_ROUTER_PUMP", address(0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa));
        TagAITradeRouter trade = TagAITradeRouter(payable(executor));
        require(address(trade).code.length != 0 && address(trade.pump()) == expectedPump, "Trade router mismatch");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY_MAIN"));
        router = new TagAILiquidityRouter(trade);
        vm.stopBroadcast();
        console2.log("TagAILiquidityRouter", address(router));
        console2.log("TagAITradeRouter", executor);
        console2.log("Pump", expectedPump);
    }
}
