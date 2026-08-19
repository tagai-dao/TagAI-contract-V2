// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/helper/ImportHelper.sol";
import "../src/helper/ImportedTokenSwapWrapper.sol";

contract DeployImportHelper is Script {
    address private constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address private constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address private constant NUTBOX_COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address private constant HOURLY_TICK_CALCULATOR = 0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address swapWrapper = vm.envAddress("IMPORTED_TOKEN_SWAP_WRAPPER");
        vm.startBroadcast(deployerPrivateKey);
        ImportHelper helper = new ImportHelper(
            COMMUNITY_FACTORY, SOCIAL_CURATION_FACTORY, NUTBOX_COMMITTEE, HOURLY_TICK_CALCULATOR, swapWrapper
        );
        ImportedTokenSwapWrapper(payable(swapWrapper)).setRegistrar(address(helper));
        vm.stopBroadcast();
        console.log("ImportHelper deployed at:", address(helper));
    }
}
