// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest} from "./Pump13Mainnet.t.sol";
import {DeployBSCPump13Script} from "../../script/DeployBSCPump13.s.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {Token} from "../../src/pump/Token.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

interface DeploymentOwner {
    function transferOwnership(address) external;
    function acceptOwnership() external;
    function approvedCreatorForwarders(address) external view returns (bool);
}

/// @dev Runs the actual deploy script inside a local fork. Key 1 is a public test key,
/// funded only with vm.deal; this test never submits any RPC transaction.
contract Pump13DeploymentForkTest is Pump13MainnetForkTest {
    function test_deployment_allRouterDefaultsHaveRoutesAndConstructorApproval() public {
        NutboxRouter defaultRouter = new NutboxRouter(
            Config.wrappedNative(),
            Config.pancakeV3Router(),
            _one(Config.pancakeV2Router()),
            _one(Config.pancakeV2Factory()),
            _one(Config.pancakeV3Factory()),
            new address[](0),
            _one(MANAGER),
            Config.initialConfig()
        );
        address[] memory defaults = Config.constituentAssets();
        Pump defaultPump = new Pump(IPSHARE, platform, defaults);
        assertEq(defaults.length, 16);
        for (uint256 i; i < defaults.length; ++i) {
            assertTrue(defaultPump.approvedConstituent(defaults[i]));
            assertTrue(defaultRouter.hasRoute(Config.wrappedNative(), defaults[i]));
            assertTrue(defaultRouter.hasRoute(Config.settlementToken(), defaults[i]));
            defaultRouter.validateRoute(Config.wrappedNative(), defaults[i]);
            defaultRouter.validateRoute(Config.settlementToken(), defaults[i]);
            assertGt(defaultRouter.quote(Config.wrappedNative(), defaults[i], 0.001 ether), 0);
        }
    }

    function test_deployment_scriptCreatesConfiguredStackAndExecutesBuyback() public {
        address deployer = vm.addr(1);
        vm.deal(deployer, 100 ether);
        router.transferOwnership(deployer);
        vm.prank(deployer);
        router.acceptOwnership();
        DeploymentOwner(address(registry)).transferOwnership(deployer);
        vm.prank(deployer);
        DeploymentOwner(address(registry)).acceptOwnership();
        vm.setEnv("PRIVATE_KEY_MAIN", "1");
        vm.setEnv("PUMP13_OWNER", vm.toString(deployer));
        vm.setEnv("IP_SHARE", vm.toString(IPSHARE));
        vm.setEnv("FEE_RECEIVER", vm.toString(platform));
        vm.setEnv("CL_POOL_MANAGER", vm.toString(MANAGER));
        vm.setEnv("VAULT", vm.toString(VAULT));
        vm.setEnv("COMMUNITY_FACTORY", vm.toString(COMMUNITY_FACTORY));
        vm.setEnv("CALCULATOR", vm.toString(address(calculator)));
        vm.setEnv("ERC20_STAKING_FACTORY", vm.toString(STAKING_FACTORY));
        vm.setEnv("COMMITTEE", vm.toString(COMMITTEE));
        vm.setEnv("NUTBOX_ROUTER", vm.toString(address(router)));
        vm.setEnv("BASKET_HOOK_V4", vm.toString(basketHook));
        vm.setEnv("PANCAKE_V2_FACTORY", vm.toString(Config.pancakeV2Factory()));
        vm.setEnv("SETTLEMENT_TOKEN", vm.toString(Config.settlementToken()));
        vm.setEnv("BASKET_SWAP_ROUTER_V4", vm.toString(address(basketRouter)));
        vm.setEnv("PUMP13_LISTING_KEEPER", vm.toString(keeper));
        // Foundry's standard deterministic CREATE2 deployment proxy.
        vm.setEnv("CREATE2_DEPLOYER", "0x4e59b44847b379578588920cA78FbF26c0B4956C");
        DeployBSCPump13Script deployment = new DeployBSCPump13Script();
        TagAIBuybackRouter buyback;
        (pump, hook, buyback) = deployment.run();
        assertEq(pump.owner(), deployer);
        address[] memory defaults = Config.constituentAssets();
        assertEq(defaults.length, 16);
        for (uint256 i; i < defaults.length; ++i) {
            assertTrue(pump.approvedConstituent(defaults[i]));
        }
        assertFalse(pump.approvedConstituent(Config.settlementToken()));
        assertFalse(pump.approvedConstituent(Config.wrappedNative()));
        assertEq(pump.listingKeeper(), keeper);
        assertEq(pump.buybackRouter(), address(buyback));
        assertEq(uint16(uint160(address(hook))), 0x0CC1);
        assertTrue(router.operators(address(pump)));
        assertTrue(DeploymentOwner(address(registry)).approvedCreatorForwarders(address(pump)));
        Token t = _create(_config(2, 4, true));
        _fill(t);
        _list(t);
        _buyT(t, 1 ether);
        BasketTradeData memory data;
        data.legMins = new uint256[](4);
        data.legSqrtPriceLimitsX96 = new uint160[](0);
        data.allowFailedLegs = new bool[](4);
        for (uint256 i; i < 4; ++i) {
            data.legMins[i] = 1;
        }
        assertGt(hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, abi.encode(data))), 0);
        assertGt(t.claimBuybackReward(creator), 0);
    }
}
