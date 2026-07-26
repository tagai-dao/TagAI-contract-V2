// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Committee} from "../src/nutbox/Committee.sol";
import {HourlyTickCalculator} from "../src/nutbox/calculators/HourlyTickCalculator.sol";
import {LinearTimeCalculator} from "../src/nutbox/calculators/LinearTimeCalculator.sol";
import {MintableERC20Factory} from "../src/nutbox/community-token/MintableERC20Factory.sol";
import {ERC20StakingFactory} from "../src/nutbox/dapps/erc20-staking/ERC20StakingFactory.sol";
import {ERC20LockingFactory} from "../src/nutbox/dapps/erc20-locking/ERC20LockingFactory.sol";
import {NFTMiningPoolFactory} from "../src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol";
import {IPShare} from "../src/pump/IPShare.sol";
import {Pump} from "../src/pump/Pump.sol";
import {NutboxDeployConfig} from "../src/pump/NutboxDeployConfig.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {ImportHelper} from "../src/helper/ImportHelper.sol";
import {TagAISwapWrapper} from "../src/helper/TagAISwapWrapper.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {ICommittee} from "../src/interfaces/ICommittee.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev 工厂上的 EIP-1167 模板 getter
interface IPoolTemplate {
    function poolTemplate() external view returns (address);
}

interface ICommunityFactoryTemplate {
    function communityTemplate() external view returns (address);
}

/**
 * @title DeployRH
 * @notice Robinhood Chain: Nutbox 全栈 + Pump + Hook + ImportHelper + TagAISwapWrapper。
 *
 *   make deploy-rh-testnet / make deploy-rh-mainnet
 *
 * Optional: RH_POOL_MANAGER, RH_WETH (testnet default known WETH9)
 */
contract DeployRHScript is Script {
    uint160 internal constant HOOK_FLAGS =
        uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;

    address internal constant RH_MAINNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_TESTNET_POOL_MANAGER = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;
    address internal constant RH_MAINNET_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_TESTNET_WETH = 0x37E402B8081eFcE1D82A09a066512278006e4691;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev 汇总部署地址，避免 run() 局部变量过多导致 stack too deep
    struct Addrs {
        address committee;
        address communityFactory;
        address communityTemplate;
        address hourlyTick;
        address linearTime;
        address mintableFactory;
        address scf;
        address socialCurationTemplate;
        address stakingFactory;
        address stakingTemplate;
        address lockingFactory;
        address lockingTemplate;
        address nftMiningFactory;
        address nftMiningTemplate;
        address ipshare;
        address poolManager;
        address weth;
        address pump;
        address tokenImplementation;
        address hook;
        address importHelper;
        address wrapper;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        Addrs memory a;
        a.poolManager = _resolvePoolManager();
        a.weth = _resolveWeth();

        console.log("=== TagAI V2 RH Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PoolManager:", a.poolManager);
        console.log("WETH:", a.weth);
        require(a.poolManager.code.length > 0, "PoolManager missing on this chain");

        vm.startBroadcast(pk);
        _deployNutbox(a, deployer);
        _deployPumpAndHelpers(a, deployer);
        vm.stopBroadcast();

        _logWhitelist(a);
        _writeAddresses(block.chainid, deployer, a);
        console.log("=== RH Deployment Complete ===");
    }

    /// @dev Committee + CF + calculators + mintable + pool factories + whitelist
    function _deployNutbox(Addrs memory a, address deployer) internal {
        Committee committee = new Committee(payable(deployer));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        a.committee = address(committee);
        console.log("(1) Committee:", a.committee);

        a.communityFactory = _deployCommunityFactory(a.committee);
        console.log("    CommunityFactory:", a.communityFactory);

        a.hourlyTick = address(new HourlyTickCalculator(a.communityFactory));
        console.log("    HourlyTickCalculator:", a.hourlyTick);

        a.linearTime = address(new LinearTimeCalculator(a.communityFactory));
        console.log("    LinearTimeCalculator:", a.linearTime);

        a.mintableFactory = address(new MintableERC20Factory());
        console.log("    MintableERC20Factory:", a.mintableFactory);

        a.scf = _deploySocialCurationFactory(a.communityFactory, deployer);
        console.log("    SocialCurationFactory:", a.scf);

        a.stakingFactory = address(new ERC20StakingFactory(a.communityFactory));
        console.log("    ERC20StakingFactory:", a.stakingFactory);

        a.lockingFactory = address(new ERC20LockingFactory(a.communityFactory));
        console.log("    ERC20LockingFactory:", a.lockingFactory);

        a.nftMiningFactory = address(new NFTMiningPoolFactory(a.communityFactory));
        console.log("    NFTMiningPoolFactory:", a.nftMiningFactory);

        // 读取工厂构造时部署的 EIP-1167 模板地址
        a.communityTemplate = ICommunityFactoryTemplate(a.communityFactory).communityTemplate();
        a.socialCurationTemplate = IPoolTemplate(a.scf).poolTemplate();
        a.stakingTemplate = IPoolTemplate(a.stakingFactory).poolTemplate();
        a.lockingTemplate = IPoolTemplate(a.lockingFactory).poolTemplate();
        a.nftMiningTemplate = IPoolTemplate(a.nftMiningFactory).poolTemplate();
        console.log("    CommunityTemplate:", a.communityTemplate);
        console.log("    SocialCurationTemplate:", a.socialCurationTemplate);
        console.log("    ERC20StakingTemplate:", a.stakingTemplate);
        console.log("    ERC20LockingTemplate:", a.lockingTemplate);
        console.log("    NFTMiningPoolTemplate:", a.nftMiningTemplate);

        committee.adminAddContract(a.hourlyTick);
        committee.adminAddContract(a.linearTime);
        committee.adminAddContract(a.mintableFactory);
        committee.adminAddContract(a.scf);
        committee.adminAddContract(a.stakingFactory);
        committee.adminAddContract(a.lockingFactory);
        committee.adminAddContract(a.nftMiningFactory);
        console.log("    Committee: whitelisted calculators + mintable + SCF + staking + locking + NFT mining");
    }

    /// @dev IPShare + Pump + Hook + ImportHelper + Wrapper（Pump 默认 HourlyTick）
    function _deployPumpAndHelpers(Addrs memory a, address deployer) internal {
        IPShare ipshare = new IPShare(deployer);
        ipshare.adminStartTrade();
        a.ipshare = address(ipshare);
        console.log("(2) IPShare:", a.ipshare);

        NutboxDeployConfig memory cfg = NutboxDeployConfig({
            communityFactory: a.communityFactory,
            calculator: a.hourlyTick,
            socialCurationFactory: a.scf,
            committee: a.committee,
            poolManager: a.poolManager
        });
        Pump pump = new Pump(a.ipshare, deployer, cfg);
        a.pump = address(pump);
        a.tokenImplementation = pump.tokenImplementation();
        console.log("(3) Pump:", a.pump);
        console.log("    TokenImplementation:", a.tokenImplementation);

        a.hook = address(_deployHook(IPoolManager(a.poolManager), a.pump));
        console.log("(4) TagAISwapHook:", a.hook);

        pump.adminSetHookAddress(a.hook);
        console.log("(5) Pump.hookAddress set");

        a.importHelper = address(new ImportHelper(a.communityFactory, a.scf, a.committee, a.ipshare));
        console.log("(6) ImportHelper:", a.importHelper);

        a.wrapper = address(new TagAISwapWrapper(a.importHelper, a.ipshare, a.weth, deployer));
        console.log("(7) TagAISwapWrapper:", a.wrapper);
    }

    function _logWhitelist(Addrs memory a) internal view {
        _assertWhitelisted(a.committee, a.hourlyTick, "HourlyTick");
        _assertWhitelisted(a.committee, a.linearTime, "LinearTime");
        _assertWhitelisted(a.committee, a.mintableFactory, "MintableERC20Factory");
        _assertWhitelisted(a.committee, a.scf, "SocialCurationFactory");
        _assertWhitelisted(a.committee, a.stakingFactory, "ERC20StakingFactory");
        _assertWhitelisted(a.committee, a.lockingFactory, "ERC20LockingFactory");
        _assertWhitelisted(a.committee, a.nftMiningFactory, "NFTMiningPoolFactory");
    }

    function _assertWhitelisted(address committee, address c, string memory label) internal view {
        if (ICommittee(committee).verifyContract(c)) {
            console.log("  OK whitelist:", label);
        } else {
            console.log("  WARN not whitelisted:", label);
        }
    }

    function _resolvePoolManager() internal view returns (address pm) {
        address overridePm = vm.envOr("RH_POOL_MANAGER", address(0));
        if (overridePm != address(0)) return overridePm;
        if (block.chainid == RH_MAINNET_CHAIN_ID) return RH_MAINNET_POOL_MANAGER;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return RH_TESTNET_POOL_MANAGER;
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_mainnet|rh_testnet");
    }

    function _resolveWeth() internal view returns (address) {
        if (block.chainid == RH_MAINNET_CHAIN_ID) return RH_MAINNET_WETH;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return vm.envOr("RH_WETH", RH_TESTNET_WETH);
        revert("unsupported chain: use FOUNDRY_PROFILE=rh_mainnet|rh_testnet");
    }

    function _deployHook(IPoolManager poolManager, address pumpAddr)
        internal
        returns (TagAISwapHook deployed)
    {
        bytes memory constructorArgs = abi.encode(poolManager, pumpAddr);
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

    function _deploySocialCurationFactory(address _communityFactory, address _claimSigner)
        internal
        returns (address)
    {
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

    function _writeAddresses(uint256 chainId, address deployer, Addrs memory a) internal {
        string memory chainIdStr = vm.toString(chainId);
        string memory dir = string.concat("deployments/", chainIdStr);
        string memory path = string.concat(dir, "/addresses.json");

        string memory json = string.concat("{\n  \"chainId\": ", chainIdStr, ",\n");
        json = string.concat(json, '  "deployer": "', vm.toString(deployer), '",\n');
        json = string.concat(json, '  "Committee": "', vm.toString(a.committee), '",\n');
        json = string.concat(json, '  "CommunityFactory": "', vm.toString(a.communityFactory), '",\n');
        json = string.concat(json, '  "CommunityTemplate": "', vm.toString(a.communityTemplate), '",\n');
        json = string.concat(json, '  "HourlyTickCalculator": "', vm.toString(a.hourlyTick), '",\n');
        json = string.concat(json, '  "LinearTimeCalculator": "', vm.toString(a.linearTime), '",\n');
        json = string.concat(json, '  "MintableERC20Factory": "', vm.toString(a.mintableFactory), '",\n');
        json = string.concat(json, '  "SocialCurationFactory": "', vm.toString(a.scf), '",\n');
        json = string.concat(json, '  "SocialCurationTemplate": "', vm.toString(a.socialCurationTemplate), '",\n');
        json = string.concat(json, '  "ERC20StakingFactory": "', vm.toString(a.stakingFactory), '",\n');
        json = string.concat(json, '  "ERC20StakingTemplate": "', vm.toString(a.stakingTemplate), '",\n');
        json = string.concat(json, '  "ERC20LockingFactory": "', vm.toString(a.lockingFactory), '",\n');
        json = string.concat(json, '  "ERC20LockingTemplate": "', vm.toString(a.lockingTemplate), '",\n');
        json = string.concat(json, '  "NFTMiningPoolFactory": "', vm.toString(a.nftMiningFactory), '",\n');
        json = string.concat(json, '  "NFTMiningPoolTemplate": "', vm.toString(a.nftMiningTemplate), '",\n');
        json = string.concat(json, '  "IPShare": "', vm.toString(a.ipshare), '",\n');
        json = string.concat(json, '  "PoolManager": "', vm.toString(a.poolManager), '",\n');
        json = string.concat(json, '  "WETH": "', vm.toString(a.weth), '",\n');
        json = string.concat(json, '  "Pump": "', vm.toString(a.pump), '",\n');
        json = string.concat(json, '  "TokenImplementation": "', vm.toString(a.tokenImplementation), '",\n');
        json = string.concat(json, '  "TagAISwapHook": "', vm.toString(a.hook), '",\n');
        json = string.concat(json, '  "ImportHelper": "', vm.toString(a.importHelper), '",\n');
        json = string.concat(json, '  "TagAISwapWrapper": "', vm.toString(a.wrapper), '"\n}\n');

        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Addresses written to:", path);
    }
}
