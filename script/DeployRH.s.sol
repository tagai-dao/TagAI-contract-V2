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
import {TagAISwapWrapper} from "../src/helper/TagAISwapWrapper.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title DeployRH
 * @notice Robinhood Chain deployment: full Nutbox stack + Pump + TagAISwapHook (Uniswap v4).
 *
 * Config lives in foundry.toml + .env (PRIVATE_KEY only). PoolManager is selected by chainId.
 *
 *   make deploy-rh-testnet   # chain 46630
 *   make deploy-rh-mainnet   # chain 4663
 *
 * Optional override: RH_POOL_MANAGER=0x... in .env
 */
contract DeployRHScript is Script {
    // TagAISwapHook permissions: beforeInitialize, before/afterSwap, swap return deltas
    uint160 internal constant HOOK_FLAGS =
        uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;

    // Uniswap v4 PoolManager on RH
    address internal constant RH_MAINNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_TESTNET_POOL_MANAGER = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;

    // WETH on RH mainnet (testnet: set RH_WETH in .env)
    address internal constant RH_MAINNET_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // Foundry script 里 `new X{salt}` 实际经此工厂 CREATE2，挖 salt 必须用它（不是 EOA / Script）
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address rhPoolManager = _resolvePoolManager();
        address weth = _resolveWeth();

        console.log("=== TagAI V2 RH Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PoolManager:", rhPoolManager);
        console.log("WETH:", weth);
        console.log("");

        require(rhPoolManager.code.length > 0, "PoolManager missing on this chain");

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
        console.log("    Committee: whitelisted Calculator + SCF");

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

        ImportHelper importHelper = new ImportHelper(communityFactory, scf, address(committee), address(ipshare));
        console.log("(6) ImportHelper:", address(importHelper));

        TagAISwapWrapper wrapper =
            new TagAISwapWrapper(address(importHelper), address(ipshare), weth, deployer);
        console.log("(7) TagAISwapWrapper:", address(wrapper));

        vm.stopBroadcast();

        bool isWhitelisted = ICommittee(address(committee)).verifyContract(address(calculator));
        if (isWhitelisted) {
            console.log("(8) VERIFIED: Calculator whitelisted in Committee");
        } else {
            console.log("(8) WARNING: Calculator NOT whitelisted");
        }

        _writeAddresses(
            block.chainid,
            deployer,
            address(committee),
            communityFactory,
            address(calculator),
            scf,
            address(ipshare),
            rhPoolManager,
            address(pump),
            pump.tokenImplementation(),
            address(hook),
            address(importHelper),
            address(wrapper)
        );

        console.log("");
        console.log("=== RH Deployment Complete ===");
    }

    /// @dev Prefer RH_POOL_MANAGER env override; otherwise pick by chainId.
    function _resolvePoolManager() internal view returns (address pm) {
        address overridePm = vm.envOr("RH_POOL_MANAGER", address(0));
        if (overridePm != address(0)) return overridePm;

        if (block.chainid == RH_MAINNET_CHAIN_ID) return RH_MAINNET_POOL_MANAGER;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return RH_TESTNET_POOL_MANAGER;
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_mainnet|rh_testnet");
    }

    /// @dev Mainnet WETH is fixed; testnet requires RH_WETH in .env.
    function _resolveWeth() internal view returns (address weth) {
        if (block.chainid == RH_MAINNET_CHAIN_ID) return RH_MAINNET_WETH;
        if (block.chainid == RH_TESTNET_CHAIN_ID) {
            weth = vm.envOr("RH_WETH", address(0));
            require(weth != address(0), "set RH_WETH for testnet");
            return weth;
        }
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_mainnet|rh_testnet");
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

    function _writeAddresses(
        uint256 chainId,
        address deployer,
        address committee,
        address communityFactory,
        address calculator,
        address scf,
        address ipshare,
        address poolManager,
        address pump,
        address tokenImplementation,
        address hook,
        address importHelper,
        address tagaiSwapWrapper
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
            '  "IPShare": "', vm.toString(ipshare), '",\n',
            '  "PoolManager": "', vm.toString(poolManager), '",\n',
            '  "Pump": "', vm.toString(pump), '",\n',
            '  "TokenImplementation": "', vm.toString(tokenImplementation), '",\n',
            '  "TagAISwapHook": "', vm.toString(hook), '",\n',
            '  "ImportHelper": "', vm.toString(importHelper), '",\n',
            '  "TagAISwapWrapper": "', vm.toString(tagaiSwapWrapper), '"\n',
            "}\n"
        );

        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Addresses written to:", path);
    }
}
