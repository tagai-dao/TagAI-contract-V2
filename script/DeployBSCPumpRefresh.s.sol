// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Pump} from "../src/pump/Pump.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";

/**
 * @title DeployBSCPumpRefresh
 * @notice Redeploy Pump (+ new Token impl) and TagAISwapHook on BSC mainnet.
 *         Reuses existing HourlyTickCalculator, DFXStarScoreStakingFactory, Nutbox infra.
 *
 * Usage (simulate):
 *   source .env
 *   forge script script/DeployBSCPumpRefresh.s.sol --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Usage (broadcast + verify):
 *   forge script script/DeployBSCPumpRefresh.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 */
contract DeployBSCPumpRefreshScript is Script {
    // ─── Reused BSC infrastructure ───────────────────────────────────────────
    address constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    // ─── Reused from previous V9 deploy (no Committee re-whitelist needed) ───
    address constant CALCULATOR = 0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d;
    address constant DFX_FACTORY = 0x77Fb65140B746e639bB512c2C25604d1924aE774;
    address constant DFX_STAKING = 0x2D91b9a98A49C8dd2CF68Be2F8ABbFB3a78C2eae;

    uint16 constant TARGET_BITMAP = 0x0CC1;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);

        require(block.chainid == 56, "BSC mainnet only (chainId 56)");
        require(CALCULATOR.code.length > 0, "Calculator missing");
        require(ICommittee(COMMITTEE).verifyContract(CALCULATOR), "Calculator not whitelisted");

        console.log("=== BSC Pump Refresh Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Reusing Calculator:", CALCULATOR);
        console.log("Reusing DFXStarScoreStakingFactory:", DFX_FACTORY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        Pump pump = new Pump(IPSHARE, FEE_RECEIVER);
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);
        console.log("Pump:", address(pump));
        console.log("TokenImplementation:", pump.tokenImplementation());

        vm.stopBroadcast();

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode,
            abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("Mining Hook salt for Pump:", address(pump));
        (bytes32 hookSalt, address predictedHook, uint256 iterations) =
            mineSalt(CREATE2_DEPLOYER, bytecodeHash);
        console.log("  iterations:", iterations);
        console.log("  HookSalt:", uint256(hookSalt));
        console.log("  predicted Hook:", predictedHook);

        vm.startBroadcast(deployerPrivateKey);

        TagAISwapHook hook = new TagAISwapHook{salt: hookSalt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            address(pump)
        );
        require(address(hook) == predictedHook, "Hook address mismatch");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Hook bitmap mismatch");
        console.log("TagAISwapHook:", address(hook));

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(CALCULATOR);
        pump.adminSetNutbox(COMMUNITY_FACTORY, CALCULATOR, SOCIAL_CURATION_FACTORY, COMMITTEE);
        console.log("Pump configured");

        vm.stopBroadcast();

        _writeAddresses(pump, hook, hookSalt, deployer);

        console.log("");
        console.log("=== Deploy Complete ===");
        console.log("Old Pump (deprecated): 0x32b7afeF0Dbf1739c4135784735AbFC2d3b8FA21");
        console.log("Old Hook (deprecated): 0x5917E8bb289766FddE79314DcaE626a241950cC1");
        console.log("New Pump:", address(pump));
        console.log("New TokenImplementation:", pump.tokenImplementation());
        console.log("New TagAISwapHook:", address(hook));
        console.log("Update tiptag-ui / tagai-api / subgraph with new Pump + Hook addresses.");
    }

    function _writeAddresses(Pump pump, TagAISwapHook hook, bytes32 hookSalt, address deployer) internal {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory dir = string.concat("deployments/", chainIdStr);
        string memory path = string.concat(dir, "/addresses.json");

        string memory json = string.concat(
            "{\n",
            '  "chainId": ', chainIdStr, ',\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "Committee": "', vm.toString(COMMITTEE), '",\n',
            '  "CommunityFactory": "', vm.toString(COMMUNITY_FACTORY), '",\n',
            '  "HourlyTickCalculator": "', vm.toString(CALCULATOR), '",\n',
            '  "SocialCurationFactory": "', vm.toString(SOCIAL_CURATION_FACTORY), '",\n',
            '  "DFXStarScoreStakingFactory": "', vm.toString(DFX_FACTORY), '",\n',
            '  "DFXStarScoreStaking": "', vm.toString(DFX_STAKING), '",\n',
            '  "IPShare": "', vm.toString(IPSHARE), '",\n',
            '  "CLPoolManager": "', vm.toString(CL_POOL_MANAGER), '",\n',
            '  "Vault": "', vm.toString(VAULT), '",\n',
            '  "Pump": "', vm.toString(address(pump)), '",\n',
            '  "TokenImplementation": "', vm.toString(pump.tokenImplementation()), '",\n',
            '  "TagAISwapHook": "', vm.toString(address(hook)), '",\n',
            '  "HookSalt": "', vm.toString(uint256(hookSalt)), '",\n',
            '  "previousPump": "0x32b7afeF0Dbf1739c4135784735AbFC2d3b8FA21",\n',
            '  "previousHook": "0x5917E8bb289766FddE79314DcaE626a241950cC1",\n',
            '  "previousTokenImplementation": "0xDfcD039554FC9DE3117a6A367944367F03C6b9Cb"\n',
            "}\n"
        );

        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Addresses written to:", path);
    }

    function mineSalt(address deployer, bytes32 bytecodeHash)
        internal
        pure
        returns (bytes32 salt, address predictedAddress, uint256 iterations)
    {
        for (uint256 i = 0; i < MAX_MINING_ITERATIONS; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
            predictedAddress = address(uint160(uint256(hash)));
            if (uint16(uint160(predictedAddress)) == TARGET_BITMAP) {
                return (salt, predictedAddress, i + 1);
            }
        }
        revert("No valid salt found");
    }
}
