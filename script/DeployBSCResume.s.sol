// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Pump} from "../src/pump/Pump.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";

/**
 * @title DeployBSCResume
 * @notice Resume BSC deployment after Phase 1 succeeded but Hook + Pump config failed.
 *
 * Run (do NOT use --skip-simulation):
 *   forge script script/DeployBSCResume.s.sol:DeployBSCResumeScript \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 */
contract DeployBSCResumeScript is Script {
    // ─── Already deployed on BSC (Phase 1) ───────────────────────────────────────
    address constant CALCULATOR = 0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d;
    address constant PUMP = 0xDb32C901409673D2543dc5C971EC44B2dE905B31;
    address constant DFX_FACTORY = 0x77Fb65140B746e639bB512c2C25604d1924aE774;

    // ─── Reused infrastructure ─────────────────────────────────────────────────
    address constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;

    // Mined for Pump = 0xDb32C901409673D2543dc5C971EC44B2dE905B31
    bytes32 constant HOOK_SALT = bytes32(uint256(66174));
    address constant EXPECTED_HOOK = 0x23Daa598211F15CC8Cc301382BA440C318240CC1;
    uint16 constant TARGET_BITMAP = 0x0CC1;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);

        require(block.chainid == 56, "BSC mainnet only");
        require(PUMP.code.length > 0, "Pump not deployed");
        require(CALCULATOR.code.length > 0, "Calculator not deployed");
        require(DFX_FACTORY.code.length > 0, "DFX factory not deployed");

        console.log("=== BSC Deployment Resume ===");
        console.log("Deployer:", deployer);

        address dfxAdmin = vm.envOr("DFX_STAKING_ADMIN", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _addDFXAdminIfNeeded(DFX_FACTORY, dfxAdmin);

        TagAISwapHook hook;
        if (EXPECTED_HOOK.code.length > 0) {
            hook = TagAISwapHook(payable(EXPECTED_HOOK));
            console.log("Hook already deployed:", address(hook));
        } else {
            hook = new TagAISwapHook{salt: HOOK_SALT}(
                ICLPoolManager(CL_POOL_MANAGER),
                IVault(VAULT),
                PUMP
            );
            require(address(hook) == EXPECTED_HOOK, "Hook address mismatch");
            require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
            console.log("Hook deployed:", address(hook));
        }

        Pump pump = Pump(payable(PUMP));
        if (pump.getHookAddress() != address(hook)) {
            pump.adminSetHookAddress(address(hook));
        }
        if (pump.getCalculator() != CALCULATOR) {
            pump.adminSetCalculator(CALCULATOR);
        }
        if (pump.nutboxCommunityFactory() != COMMUNITY_FACTORY || pump.hourlyTickCalculator() != CALCULATOR) {
            pump.adminSetNutbox(COMMUNITY_FACTORY, CALCULATOR, SOCIAL_CURATION_FACTORY, COMMITTEE);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("--- Manual Follow-up (Committee Multisig) ---");
        _logPendingWhitelist("HourlyTickCalculator", CALCULATOR);
        _logPendingWhitelist("DFXStarScoreStakingFactory", DFX_FACTORY);
        console.log("");
        console.log("=== Resume Complete ===");
        console.log("Pump:", PUMP);
        console.log("TagAISwapHook:", address(hook));
    }

    function _addDFXAdminIfNeeded(address dfxFactory, address admin) internal {
        (bool ok, bytes memory data) = dfxFactory.staticcall(abi.encodeWithSignature("isAdmin(address)", admin));
        if (ok && data.length > 0 && abi.decode(data, (bool))) {
            console.log("DFX admin already set:", admin);
            return;
        }
        (bool success,) = dfxFactory.call(abi.encodeWithSignature("addAdmin(address)", admin));
        require(success, "addAdmin failed");
        console.log("DFX admin set:", admin);
    }

    function _logPendingWhitelist(string memory label, address target) internal view {
        if (ICommittee(COMMITTEE).verifyContract(target)) {
            console.log(string.concat("  [OK] ", label, " whitelisted: ", vm.toString(target)));
        } else {
            console.log(string.concat("  [TODO] ", label, " -> Committee.adminAddContract(", vm.toString(target), ")"));
        }
    }
}
