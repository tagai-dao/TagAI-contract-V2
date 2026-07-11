// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestImportToken} from "../src/mocks/TestImportToken.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {IHourlyTickCalculator} from "../src/interfaces/IHourlyTickCalculator.sol";
import {SocialCuration} from "../src/nutbox/dapps/social-curation/SocialCuration.sol";
import {SocialCurationFactory} from "../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import {ICommunity} from "../src/interfaces/ICommunity.sol";

/**
 * @notice RH testnet: 部署测试币 → ImportHelper 建社区 → inject →（可选）签 claim
 *
 * Usage:
 *   forge script script/SmokeImportHelper.s.sol:SmokeImportHelperScript \
 *     --rpc-url http://127.0.0.1:18546 --broadcast --slow --chain 46630 \
 *     --gas-estimate-multiplier 300 -vvv
 */
contract SmokeImportHelperScript is Script {
    // deployments/46630/addresses.json
    address constant IMPORT_HELPER = 0x8A7b0d80FA92699CE3e5bB2c8fE404D6733796d1;
    address constant CALCULATOR = 0xf5D8d9402A4603bD67400500E62880eee91cF12C;
    address constant SCF = 0xd52624320654FBEA5F1f988d5F4E55B74C56e67D;

    uint256 constant MINT_AMOUNT = 100_000_000 ether; // 1 亿
    uint256 constant INJECT_AMOUNT = 100_000_000 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Smoke ImportHelper ===");
        console.log("Deployer:", deployer);
        console.log("Chain:", block.chainid);

        vm.startBroadcast(pk);

        TestImportToken token = new TestImportToken("ImportSmoke", "ISMOKE", deployer, MINT_AMOUNT);
        console.log("(1) TestImportToken:", address(token));
        console.log("    balance:", token.balanceOf(deployer));

        ImportHelper helper = ImportHelper(payable(IMPORT_HELPER));
        (address community, address pool) = helper.createCommunityAndPool{value: 0}(
            address(token),
            CALCULATOR,
            bytes("")
        );
        console.log("(2) Community:", community);
        console.log("    SocialCuration pool:", pool);

        token.approve(CALCULATOR, INJECT_AMOUNT);
        IHourlyTickCalculator(CALCULATOR).inject(community, INJECT_AMOUNT);
        console.log("(3) Injected:", INJECT_AMOUNT);

        vm.stopBroadcast();

        console.log("    Community token bal:", IERC20(address(token)).balanceOf(community));
        console.log("    claimSigner:", SocialCurationFactory(SCF).claimSigner());
        console.log("    pool community:", SocialCuration(payable(pool)).community());

        // 写地址，方便后续 claim
        string memory json = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "TestImportToken": "', vm.toString(address(token)), '",\n',
            '  "Community": "', vm.toString(community), '",\n',
            '  "SocialCurationPool": "', vm.toString(pool), '",\n',
            '  "injected": "', vm.toString(INJECT_AMOUNT), '",\n',
            '  "deployer": "', vm.toString(deployer), '"\n',
            "}\n"
        );
        try vm.createDir("deployments/46630", true) {} catch {}
        vm.writeFile("deployments/46630/import-smoke.json", json);
        console.log("Wrote deployments/46630/import-smoke.json");
        console.log("");
        console.log("Note: HourlyTickCalculator vests over 168 hours.");
        console.log("      Claimable amount is 0 in the same hour as inject; wait >= 1 hour.");
    }
}
