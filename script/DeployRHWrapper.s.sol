// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TagAISwapWrapper} from "../src/helper/TagAISwapWrapper.sol";

/**
 * @title DeployRHWrapper
 * @notice 仅重部署 TagAISwapWrapper（复用已上线 ImportHelper / IPShare / WETH）。
 *
 * RH mainnet:
 *   FOUNDRY_PROFILE=rh_mainnet \
 *   PRIVATE_KEY=<funded> \
 *   RH_FEE_ADDRESS=0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048 \
 *   forge script script/DeployRHWrapper.s.sol:DeployRHWrapperScript \
 *     --rpc-url https://rpc.mainnet.chain.robinhood.com \
 *     --broadcast --slow --gas-estimate-multiplier 300 -vvv
 *
 * 成功后把日志里的 TagAISwapWrapper 地址写入 deployments/4663/version11.json。
 */
contract DeployRHWrapperScript is Script {
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;

    // deployments/4663/version11.json
    address internal constant MN_IMPORT_HELPER = 0xEC774DB6800B00BA1e87f0799cb29dEc21ACB4A9;
    address internal constant MN_IPSHARE = 0x8A7b0d80FA92699CE3e5bB2c8fE404D6733796d1;
    address internal constant MN_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant MN_FEE_DEFAULT = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    function run() external {
        require(
            block.chainid != RH_MAINNET_CHAIN_ID,
            "standalone Wrapper deploy disabled: ImportHelper pins its Wrapper; deploy both atomically"
        );
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        require(block.chainid == RH_MAINNET_CHAIN_ID, "expected RH mainnet 4663");

        address importHelper = vm.envOr("RH_IMPORT_HELPER", MN_IMPORT_HELPER);
        address ipshare = vm.envOr("RH_IPSHARE", MN_IPSHARE);
        address weth = vm.envOr("RH_WETH", MN_WETH);
        address feeAddress = vm.envOr("RH_FEE_ADDRESS", MN_FEE_DEFAULT);

        console.log("=== Redeploy TagAISwapWrapper ===");
        console.log("Chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("ImportHelper:", importHelper);
        console.log("IPShare:", ipshare);
        console.log("WETH:", weth);
        console.log("feeAddress:", feeAddress);
        console.log("Deployer balance:", deployer.balance);

        require(importHelper.code.length > 0, "ImportHelper missing");
        require(ipshare.code.length > 0, "IPShare missing");
        require(weth.code.length > 0, "WETH missing");
        require(feeAddress != address(0), "zero feeAddress");
        require(deployer.balance > 0, "deployer has zero ETH; fund this address first");

        vm.startBroadcast(pk);
        TagAISwapWrapper wrapper = new TagAISwapWrapper(importHelper, ipshare, weth, feeAddress);
        vm.stopBroadcast();

        console.log("TagAISwapWrapper:", address(wrapper));
        console.log("feeAddress (constructor):", feeAddress);
        console.log("=== Done - update deployments/4663/version11.json manually if needed ===");
    }
}
