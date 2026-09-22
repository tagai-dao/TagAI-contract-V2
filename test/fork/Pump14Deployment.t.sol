// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13BuybackForkTest} from "./Pump13Buyback.t.sol";
import {ForkOwner, ForkRegistry, ForkBasketRouter} from "./Pump13Mainnet.t.sol";
import {ColdCallGas} from "../helpers/ColdCallGas.sol";
import {ICreateOptional} from "../unit/PumpVersion14.t.sol";
import {DeployBSCPump14Script, IPump14SocialSigner} from "../../script/DeployBSCPump14.s.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

interface Deployment14Registry {
    function approvedCreatorForwarders(address) external view returns (bool);
}

interface Deployment14Hook {
    function basketRegistry() external view returns (address);
}

interface Deployment14Fees {
    function adminSetCreateCommunityFee(uint256) external;
    function adminSetCommunitySettingsFee(uint256) external;
}

/// @dev Runs the real deployment script against already deployed V13 infrastructure.
/// Key 1 and vm.deal are local test fixtures. No transactions are submitted to the RPC.
contract Pump14DeploymentForkTest is Pump13BuybackForkTest, ColdCallGas {
    Pump previous;
    TradeCurationFactory tradeFactory;
    TagAIBuybackRouter buyback;
    address expectedOwner;
    address expectedSigner;
    uint256 constant GAS_BUDGET = 16_777_216;

    function setUp() public override {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("PUMP14_FORK_BLOCK", uint256(123329493)));
        previous = Pump(payable(0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa));
        expectedOwner = previous.owner();
        expectedSigner = IPump14SocialSigner(0xc4674D3fBbD201Ea401a8B7e7285F956178593D8).claimSigner();
        keeper = previous.listingKeeper();
        platform = previous.getFeeReceiver();
        creator = makeAddr("deployment14-fresh-creator");
        vm.deal(creator, 100_000 ether);
        vm.deal(address(this), 100_000 ether);
        vm.deal(vm.addr(1), 100 ether);
        router = NutboxRouter(payable(previous.nutboxRouter()));
        basketHook = previous.basketHookV4();
        registry = ForkRegistry(Deployment14Hook(basketHook).basketRegistry());
        basketRouter = ForkBasketRouter(address(TagAIBuybackRouter(previous.buybackRouter()).basketRouter()));
        calculator = HourlyTickCalculator(previous.getCalculator());
        Config.AssetConfig[] memory catalog = Config.assetConfigs();
        for (uint256 i; i < catalog.length; ++i) {
            assets.push(catalog[i]);
        }

        vm.setEnv("PRIVATE_KEY_MAIN", "1");
        vm.setEnv("IP_SHARE", vm.toString(previous.getIPShare()));
        vm.setEnv("FEE_RECEIVER", vm.toString(platform));
        vm.setEnv("CL_POOL_MANAGER", vm.toString(previous.getPoolManager()));
        vm.setEnv("VAULT", vm.toString(previous.getVault()));
        vm.setEnv("COMMUNITY_FACTORY", vm.toString(previous.nutboxCommunityFactory()));
        vm.setEnv("CALCULATOR", vm.toString(address(calculator)));
        vm.setEnv("ERC20_STAKING_FACTORY", vm.toString(previous.erc20StakingFactory()));
        vm.setEnv("COMMITTEE", vm.toString(previous.nutboxCommittee()));
        vm.setEnv("NUTBOX_ROUTER", vm.toString(address(router)));
        vm.setEnv("BASKET_HOOK_V4", vm.toString(basketHook));
        vm.setEnv("PANCAKE_V2_FACTORY", vm.toString(previous.pancakeV2Factory()));
        vm.setEnv("SETTLEMENT_TOKEN", vm.toString(previous.settlementToken()));
        vm.setEnv("BASKET_SWAP_ROUTER_V4", vm.toString(address(basketRouter)));
        vm.setEnv("CREATE2_DEPLOYER", "0x4e59b44847b379578588920cA78FbF26c0B4956C");
        // Leave the V14 role/template overrides unset: verify the script's on-chain defaults.
        DeployBSCPump14Script deployment = new DeployBSCPump14Script();
        (pump, hook, buyback) = deployment.run();
        tradeFactory = deployment.deployedTradeFactory();
    }

    function _finishGovernance() private {
        assertEq(pump.owner(), vm.addr(1));
        assertEq(pump.pendingOwner(), expectedOwner);
        assertEq(tradeFactory.pendingOwner(), expectedOwner);
        assertEq(tradeFactory.claimSigner(), expectedSigner);
        assertEq(pump.listingKeeper(), keeper);
        assertEq(pump.getPoolManager(), previous.getPoolManager());
        assertEq(pump.getVault(), previous.getVault());
        assertEq(pump.nutboxCommunityFactory(), previous.nutboxCommunityFactory());
        assertEq(pump.getCalculator(), previous.getCalculator());
        assertEq(pump.erc20StakingFactory(), previous.erc20StakingFactory());
        assertEq(pump.nutboxCommittee(), previous.nutboxCommittee());
        assertEq(pump.nutboxRouter(), previous.nutboxRouter());
        assertEq(pump.basketHookV4(), previous.basketHookV4());
        assertEq(pump.pancakeV2Factory(), previous.pancakeV2Factory());
        assertEq(pump.settlementToken(), previous.settlementToken());
        assertEq(pump.tokenImplementation(), previous.tokenImplementation());
        assertEq(pump.MAX_OPTIONAL_POOLS(), 2);
        assertEq(uint16(uint160(address(hook))), 0x0CC1);
        assertEq(address(hook.pump()), address(pump));
        assertEq(address(buyback.pump()), address(pump));
        assertEq(pump.buybackRouter(), address(buyback));
        assertFalse(ICommittee(COMMITTEE).verifyContract(address(tradeFactory)));
        assertFalse(router.operators(address(pump)));
        assertFalse(Deployment14Registry(address(registry)).approvedCreatorForwarders(address(pump)));

        vm.startPrank(expectedOwner);
        pump.acceptOwnership();
        tradeFactory.acceptOwnership();
        vm.stopPrank();
        vm.prank(ForkOwner(COMMITTEE).owner());
        ICommittee(COMMITTEE).adminAddContract(address(tradeFactory));
        vm.prank(router.owner());
        router.addOperator(address(pump));
        vm.prank(ForkOwner(address(registry)).owner());
        registry.setCreatorForwarderApproval(address(pump), true);

        assertEq(pump.owner(), expectedOwner);
        assertEq(tradeFactory.owner(), expectedOwner);
        assertEq(pump.pendingOwner(), address(0));
        assertTrue(ICommittee(COMMITTEE).verifyContract(address(tradeFactory)));
        assertTrue(ICommittee(COMMITTEE).verifyContract(previous.erc20StakingFactory()));
        assertTrue(ICommittee(COMMITTEE).verifyContract(address(calculator)));
        assertTrue(router.operators(address(pump)));
        assertTrue(Deployment14Registry(address(registry)).approvedCreatorForwarders(address(pump)));
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(pump.approvedConstituent(assets[i].token));
            router.validateRoute(address(0), assets[i].token);
            router.validateRoute(previous.settlementToken(), assets[i].token);
        }
    }

    function _coldCreate(uint256 start, uint256 count, bool largeMetadata) private returns (Token t) {
        IPump.IndexConfig memory c = _config(start, 4, true);
        IPump.OptionalPoolConfig[] memory options = new IPump.OptionalPoolConfig[](count);
        if (largeMetadata) {
            c.name = "1234567890123456789012345678901234567890123456789012345678901234";
            c.symbol = "1234567890123456";
            vm.startPrank(ForkOwner(COMMITTEE).owner());
            Deployment14Fees(COMMITTEE).adminSetCreateCommunityFee(0.001 ether);
            Deployment14Fees(COMMITTEE).adminSetCommunitySettingsFee(0.001 ether);
            vm.stopPrank();
        }
        for (uint256 i; i < count; ++i) {
            TradeCurationFactory f = i == 0 ? tradeFactory : new TradeCurationFactory(COMMUNITY_FACTORY, expectedSigner);
            vm.prank(ForkOwner(COMMITTEE).owner());
            ICommittee(COMMITTEE).adminAddContract(address(f));
            vm.prank(expectedOwner);
            pump.adminSetOptionalPoolFactory(address(f), largeMetadata ? c.name : "Trade Curation", 8000, true);
            options[i] = IPump.OptionalPoolConfig(address(f), uint16(8000 / count), "");
        }
        uint256 value = pump.createFee() + IIPShare(IPSHARE).createFee() + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * (4 + count) + 1 ether;
        bytes memory payload =
            abi.encodeCall(ICreateOptional.createToken, ("DEPLOY14", bytes32(uint256(1414)), c, options));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
        }
        (bytes memory result, uint256 gasUsed) = _coldCall(
            "Live V13 infrastructure cold creation incl intrinsic",
            creator,
            address(pump),
            value,
            payload,
            GAS_BUDGET - intrinsic - 2300
        );
        assertLt(gasUsed, GAS_BUDGET);
        t = Token(payable(abi.decode(result, (address))));
        assertTrue(pump.createdTokens(address(t)));
        assertFalse(previous.createdTokens(address(t)));
        assertEq(t.listingHook(), address(hook));
        ICommunity community = ICommunity(t.nutboxCommunity());
        if (count > 0) assertTrue(community.activedPools(3 + count) != address(0));
        vm.expectRevert();
        community.activedPools(4 + count);
    }

    function test_deployment14_scriptGovernanceSixPoolsAndRealBuyback() public {
        _finishGovernance();
        Token t = _coldCreate(0, 2, true);
        _fill(t);
        _list(t);
        _buyT(t, 1 ether);
        uint256 amount = hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, _legs(t)));
        assertGt(amount, 0);
        assertGt(t.claimBuybackReward(creator), 0);
        _assertNoAdapterResidue();
    }

    function test_deployment14_fourStockComponentsSixPoolsColdBudget() public {
        _finishGovernance();
        _coldCreate(2, 2, true);
    }

    function test_deployment14_noOptionalPoolsStillLists() public {
        _finishGovernance();
        Token t = _coldCreate(0, 0, false);
        _fill(t);
        _list(t);
    }
}
