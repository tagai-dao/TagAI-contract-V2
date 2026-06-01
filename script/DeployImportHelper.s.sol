// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/helper/ImportHelper.sol";

contract DeployImportHelper is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        vm.startBroadcast(deployerPrivateKey);
        ImportHelper helper = new ImportHelper();
        vm.stopBroadcast();
        console.log("ImportHelper deployed at:", address(helper));
    }
}
