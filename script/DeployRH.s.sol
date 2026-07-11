// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Committee} from "../src/nutbox/Committee.sol";
import {HourlyTickCalculator} from "../src/nutbox/calculators/HourlyTickCalculator.sol";
import {IPShare} from "../src/pump/IPShare.sol";
import {Pump} from "../src/pump/Pump.sol";
import {NutboxDeployConfig} from "../src/pump/NutboxDeployConfig.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title DeployRH
 * @notice Robinhood Chain test deployment: full Nutbox stack + Pump + TagAISwapHook (Uniswap v4).
 *
 * Usage (RH testnet 46630):
 *   RH_RPC_URL=https://rpc.testnet.chain.robinhood.com \
 *   RH_POOL_MANAGER=0x552815eF68E6eb418A3d65D0AA1043d93204F612 \
 *   PRIVATE_KEY=0x... \
 *   forge script script/DeployRH.s.sol:DeployRHScript --rpc-url $RH_RPC_URL --broadcast
 *
 * Pump constructor receives Nutbox addresses for testing. For production, hardcode real addresses in Pump.sol.
 */
contract DeployRHScript is Script {
    // TagAISwapHook permissions: beforeInitialize, before/afterSwap, swap return deltas
    uint160 internal constant HOOK_FLAGS =
        uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    // RH testnet PoolManager552 (override via RH_POOL_MANAGER env)
    address internal constant DEFAULT_RH_POOL_MANAGER = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;

    // Foundry script 里 `new X{salt}` 实际经此工厂 CREATE2，挖 salt 必须用它（不是 EOA / Script）
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address rhPoolManager = vm.envOr("RH_POOL_MANAGER", DEFAULT_RH_POOL_MANAGER);

        console.log("=== TagAI V2 RH Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PoolManager:", rhPoolManager);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ─── (1) Nutbox stack ───────────────────────────────────────────────────
        Committee committee = new Committee(payable(deployer));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        console.log("(1) Committee:", address(committee));

        address communityFactory = _deployCommunityFactory(address(committee));
        console.log("    CommunityFactory:", communityFactory);

        HourlyTickCalculator calculator = new HourlyTickCalculator(communityFactory);
        console.log("    HourlyTickCalculator:", address(calculator));

        address scf = _deploySocialCurationFactory(communityFactory, deployer);
        console.log("    SocialCurationFactory:", scf);


        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);
        console.log("    Committee: whitelisted Calculator + SCF + DFX");

        // ─── (2) IPShare ────────────────────────────────────────────────────────
        IPShare ipshare = new IPShare(deployer);
        ipshare.adminStartTrade();
        console.log("(2) IPShare:", address(ipshare));

        // ─── (3) Pump (Nutbox + PM via constructor for test deploy) ─────────────
        NutboxDeployConfig memory cfg = NutboxDeployConfig({
            communityFactory: communityFactory,
            calculator: address(calculator),
            socialCurationFactory: scf,
            committee: address(committee),
            poolManager: rhPoolManager
        });
        Pump pump = new Pump(address(ipshare), deployer, cfg);
        console.log("(3) Pump:", address(pump));

        // ─── (4) TagAISwapHook (CREATE2 mined flags) ────────────────────────────
        TagAISwapHook hook = _deployHook(IPoolManager(rhPoolManager), address(pump));
        console.log("(4) TagAISwapHook:", address(hook));

        pump.adminSetHookAddress(address(hook));
        console.log("(5) Pump.hookAddress set");

        ImportHelper importHelper = new ImportHelper(communityFactory, scf, address(committee));
        console.log("(6) ImportHelper:", address(importHelper));

        vm.stopBroadcast();

        bool isWhitelisted = ICommittee(address(committee)).verifyContract(address(calculator));
        if (isWhitelisted) {
            console.log("(7) VERIFIED: Calculator whitelisted in Committee");
        } else {
            console.log("(7) WARNING: Calculator NOT whitelisted");
        }

        _writeAddresses(
            block.chainid,
            deployer,
            address(committee),
            communityFactory,
            address(calculator),
            scf,
            dfxFactory,
            address(ipshare),
            rhPoolManager,
            address(pump),
            pump.tokenImplementation(),
            address(hook),
            address(importHelper)
        );

        console.log("");
        console.log("=== RH Deployment Complete ===");
    }

    function _deployHook(IPoolManager poolManager, address pumpAddr)
        internal
        returns (TagAISwapHook deployed)
    {
        bytes memory constructorArgs = abi.encode(poolManager, pumpAddr);
        // salt 按 Create2Deployer 挖；与 forge script 广播时的 CREATE2 路径一致
        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(TagAISwapHook).creationCode,
            constructorArgs
        );
        deployed = new TagAISwapHook{salt: salt}(poolManager, pumpAddr);
        require(address(deployed) == predicted, "CREATE2 hook address mismatch");
        require(uint160(address(deployed)) & ((1 << 14) - 1) == HOOK_FLAGS, "invalid hook flags");
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "CommunityFactory deployment failed");
        return deployed;
    }

    function _deploySocialCurationFactory(address _communityFactory, address _claimSigner) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_communityFactory, _claimSigner)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "SocialCurationFactory deployment failed");
        return deployed;
    }

    function _deployDFXStarScoreStakingFactory(address _communityFactory) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("DFXStarScoreStakingFactory.sol:DFXStarScoreStakingFactory"),
            abi.encode(_communityFactory)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "DFXStarScoreStakingFactory deployment failed");
        return deployed;
    }

    function _writeAddresses(
        uint256 chainId,
        address deployer,
        address committee,
        address communityFactory,
        address calculator,
        address scf,
        address dfxFactory,
        address ipshare,
        address poolManager,
        address pump,
        address tokenImplementation,
        address hook,
        address importHelper
    ) internal {
        string memory chainIdStr = vm.toString(chainId);
        string memory dir = string.concat("deployments/", chainIdStr);
        string memory path = string.concat(dir, "/addresses.json");

        string memory json = string.concat(
            "{\n",
            '  "chainId": ', chainIdStr, ',\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "Committee": "', vm.toString(committee), '",\n',
            '  "CommunityFactory": "', vm.toString(communityFactory), '",\n',
            '  "HourlyTickCalculator": "', vm.toString(calculator), '",\n',
            '  "SocialCurationFactory": "', vm.toString(scf), '",\n',
            '  "DFXStarScoreStakingFactory": "', vm.toString(dfxFactory), '",\n',
            '  "IPShare": "', vm.toString(ipshare), '",\n',
            '  "PoolManager": "', vm.toString(poolManager), '",\n',
            '  "Pump": "', vm.toString(pump), '",\n',
            '  "TokenImplementation": "', vm.toString(tokenImplementation), '",\n',
            '  "TagAISwapHook": "', vm.toString(hook), '",\n',
            '  "ImportHelper": "', vm.toString(importHelper), '"\n',
            "}\n"
        );

        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Addresses written to:", path);
    }
}
