// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Pump12} from "../src/pump12/Pump12.sol";
import {NetNetHook} from "../src/pump12/NetNetHook.sol";
import {Treasury} from "../src/pump12/treasury/Treasury.sol";
import {SToken} from "../src/pump12/staking/SToken.sol";
import {Staking} from "../src/pump12/staking/Staking.sol";
import {Distributor} from "../src/pump12/distributor/Distributor.sol";
import {BondDepository} from "../src/pump12/bond/BondDepository.sol";
import {PremiumSeller} from "../src/pump12/premium/PremiumSeller.sol";
import {PTeam} from "../src/pump12/pteam/PTeam.sol";
import {IndexBondDesk} from "../src/pump12/pteam/IndexBondDesk.sol";
import {IndexFundV1} from "../src/pump12/fund/IndexFundV1.sol";
import {IndexFundFactory} from "../src/pump12/fund/IndexFundFactory.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @title DeployPump12RHScript
/// @notice 仅允许在 Robinhood Chain 主网连接 canonical USDG 与 Uniswap v4 PoolManager。
contract DeployPump12RHScript is Script {
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 public constant RH_CHAIN_ID = 4663;
    uint8 public constant USDG_DECIMALS = 6;
    address public constant CANONICAL_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant CANONICAL_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant CANONICAL_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant BASKET_REGISTRY = 0x1f997dEb6C8Ac7Bb4134Bc7c6bF23F623Cda25C6;
    address public constant BASKET_ROUTE_REGISTRY = 0x1aE3E64F51CCDC87Ff05E8E8242890e7964FF297;
    address public constant BASKET_SWAP_ROUTER = 0x9b5e6b7CC3661737e6A118e0D4f0F89fB1034653;

    function run() external returns (Pump12 pump) {
        validateConfig(CANONICAL_USDG, CANONICAL_POOL_MANAGER);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console2.log("=== Pump12 Robinhood Deployment ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("USDG:", CANONICAL_USDG);
        console2.log("PoolManager:", CANONICAL_POOL_MANAGER);

        vm.startBroadcast(privateKey);
        pump = new Pump12(CANONICAL_USDG, CANONICAL_POOL_MANAGER);
        bytes memory constructorArgs = abi.encode(IPoolManager(CANONICAL_POOL_MANAGER), address(pump), CANONICAL_USDG);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(NetNetHook).creationCode, constructorArgs);
        NetNetHook hook =
            new NetNetHook{salt: salt}(IPoolManager(CANONICAL_POOL_MANAGER), address(pump), CANONICAL_USDG);
        require(address(hook) == predicted, "Pump12: CREATE2 hook mismatch");
        pump.setHook(address(hook));
        pump.setEmissionImplementations(
            address(new Treasury()),
            address(new SToken()),
            address(new Staking()),
            address(new Distributor()),
            address(new BondDepository()),
            address(new PremiumSeller())
        );
        IndexFundV1 indexFundImplementation = new IndexFundV1();
        IndexFundFactory indexFundFactory = new IndexFundFactory(
            address(pump),
            deployer,
            CANONICAL_USDG,
            CANONICAL_POOL_MANAGER,
            CANONICAL_WETH,
            BASKET_REGISTRY,
            BASKET_SWAP_ROUTER,
            BASKET_ROUTE_REGISTRY,
            address(indexFundImplementation)
        );
        pump.setPTeamImplementations(address(new PTeam()), address(new IndexBondDesk()), address(indexFundFactory));
        vm.stopBroadcast();

        console2.log("Pump12:", address(pump));
        console2.log("NetNetHook:", address(hook));
        console2.log("IndexFundFactory:", address(indexFundFactory));
    }

    /// @notice 可在 dry-run、fork 和单元测试中独立调用的部署前检查。
    function validateConfig(address usdg, address poolManager) public view {
        require(block.chainid == RH_CHAIN_ID, "Pump12: unsupported chain");
        require(usdg == CANONICAL_USDG, "Pump12: non-canonical USDG");
        require(usdg.code.length > 0, "Pump12: USDG has no code");

        uint8 actualDecimals;
        try IERC20Metadata(usdg).decimals() returns (uint8 decimals_) {
            actualDecimals = decimals_;
        } catch {
            revert("Pump12: unreadable USDG decimals");
        }
        require(actualDecimals == USDG_DECIMALS, "Pump12: USDG decimals must be 6");

        require(poolManager == CANONICAL_POOL_MANAGER, "Pump12: non-canonical PoolManager");
        require(poolManager.code.length > 0, "Pump12: PoolManager has no code");
    }
}
