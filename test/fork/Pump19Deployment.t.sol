// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployBSCPump19Script} from "../../script/DeployBSCPump19.s.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "../../script/config/BSC15DeploymentConfig.sol";
import {Pump19} from "../../src/pump/Pump19.sol";
import {Token19} from "../../src/pump/Token19.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";

interface ILive19Governance {
    function addOperator(address) external;
    function setCreatorForwarderApproval(address, bool) external;
    function adminAddContract(address) external;
}

/// @dev Real BSC Nutbox/Basket/DEX code. All deployment and owner actions stay in this disposable fork.
contract Pump19DeploymentForkTest is Test {
    address constant PREVIOUS = 0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24;
    address constant HANDLE_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    Pump19 pump;
    DC.Config c;
    uint256 pin;
    address creator;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        pin = vm.envOr("PUMP19_FORK_BLOCK", uint256(131553338));
        vm.createSelectFork(rpc, pin);
        require(block.chainid == 56, "BSC fork required");
        DC.Config memory previous = DC.loadFrom(pin, PREVIOUS, 18);
        // Public test key, funded only in the fork. Never load a deployment wallet for this test.
        vm.setEnv("PRIVATE_KEY_MAIN", "1");
        vm.setEnv("PUMP19_OWNER", vm.toString(previous.owner));
        vm.deal(vm.addr(1), 100 ether);
        DeployBSCPump19Script deployment = new DeployBSCPump19Script();
        TagAISwapHook hook;
        TagAIBuybackRouter buyback;
        (pump, hook, buyback) = deployment.run();
        c = deployment.deploymentConfig();
        assertEq(pump.VERSION(), 19);
        assertEq(pump.getHookAddress(), address(hook));
        assertEq(pump.buybackRouter(), address(buyback));
        assertEq(pump.tokenImplementation().codehash, keccak256(type(Token19).runtimeCode));
        vm.prank(c.owner);
        pump.acceptOwnership();
        vm.prank(c.routerOwner);
        ILive19Governance(c.router).addOperator(address(pump));
        vm.prank(c.registryOwner);
        ILive19Governance(c.basketRegistry).setCreatorForwarderApproval(address(pump), true);
        if (!c.stakingAllowed) {
            vm.prank(c.committeeOwner);
            ILive19Governance(c.committee).adminAddContract(c.stakingFactory);
        }
        if (!c.calculatorAllowed) {
            vm.prank(c.committeeOwner);
            ILive19Governance(c.committee).adminAddContract(c.calculator);
        }
        if (!c.tradeAllowed) {
            vm.prank(c.committeeOwner);
            ILive19Governance(c.committee).adminAddContract(DC.TRADE_FACTORY);
        }
        creator = makeAddr("v19-live-creator");
        vm.deal(creator, 1000 ether);
    }

    function _create() internal returns (Token19 token) {
        MC.Call3[] memory calls = new MC.Call3[](3);
        calls[0] = DC.get(c.committee, "getCreateCommunityFee()");
        calls[1] = DC.get(c.committee, "getCommunitySettingsFee()");
        calls[2] = DC.call(HANDLE_REGISTRY, abi.encodeWithSignature("handleOf(address)", creator));
        MC.Result[] memory r = DC.aggregate(calls, pin);
        assertEq(bytes(abi.decode(r[2].returnData, (string))).length, 0);
        uint256 fee = c.createFee + abi.decode(r[0].returnData, (uint256)) + 3 * abi.decode(r[1].returnData, (uint256));
        IPump.IndexConfig memory index;
        index.name = "V19 live stack";
        index.symbol = "V19I";
        index.constituentAssets = new address[](2);
        index.constituentAssets[0] = c.constituents[0];
        index.constituentAssets[1] = c.constituents[1];
        index.targetWeights = new uint16[](2);
        index.targetWeights[0] = 5000;
        index.targetWeights[1] = 5000;
        index.basketFeeBps = 100;
        index.creatorShareBps = 3000;
        index.retainCommunityOwnership = true;
        IPump.OptionalPoolConfig[] memory optional = new IPump.OptionalPoolConfig[](1);
        optional[0] = IPump.OptionalPoolConfig(DC.TRADE_FACTORY, 8000, "");
        vm.prank(creator, creator);
        token = Token19(
            payable(pump.createToken{value: fee + 0.01 ether}("LIVE19", bytes32(uint256(19)), index, optional))
        );
        assertGt(token.balanceOf(creator), 0);
        assertEq(token.innerMarketBought(creator), token.balanceOf(creator));
    }

    function test_v19_liveDeploymentCreationTradingNutboxAndListing() public {
        Token19 token = _create();
        address community = token.nutboxCommunity();
        HourlyTickCalculator calculator = HourlyTickCalculator(c.calculator);
        assertTrue(calculator.registered(community));
        assertEq(calculator.communityToken(community), address(token));

        address buyer = makeAddr("v19-live-unregistered-buyer");
        vm.deal(buyer, 100 ether);
        // Real first-15s automatic injection must remain compatible with the live calculator.
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.001 ether}(0, creator, 0);
        assertGt(calculator.totalInjected(community), 0);
        vm.warp(token.createdAt() + 16);
        uint256 amount = token.balanceOf(buyer) / 3;
        vm.prank(buyer);
        token.sellToken(amount, 0, creator, 0);
        vm.startPrank(buyer);
        vm.expectRevert(IToken.InnerMarketTransferRestricted.selector);
        token.transfer(creator, 1);
        token.transfer(community, amount);
        token.approve(c.calculator, amount);
        uint256 injectedBefore = calculator.totalInjected(community);
        calculator.inject(community, amount);
        vm.stopPrank();
        assertEq(calculator.totalInjected(community), injectedBefore + amount);

        address direct = makeAddr("v19-live-unregistered-direct");
        vm.deal(direct, 100 ether);
        vm.prank(direct, direct);
        (bool bought,) = address(token).call{value: 0.001 ether}("");
        assertTrue(bought);
        assertGt(token.balanceOf(direct), 0);
        _list(token);
        assertTrue(token.listed());
        assertTrue(pump.listingFinalized(address(token)));
        assertGt(token.indexToken().code.length, 0);
        vm.prank(creator);
        token.transfer(direct, 1);
    }

    function _list(Token19 token) internal {
        uint256 cap = 650_000_000 ether;
        uint256 count;
        while (token.bondingCurveSupply() < cap) {
            uint256 supply = token.bondingCurveSupply();
            address buyer = address(uint160(uint256(keccak256(abi.encode("v19-live-buyer", count++)))));
            vm.deal(buyer, 1000 ether);
            uint256 price = pump.getPrice(supply, 9_000_000 ether);
            (uint256 platform, uint256 salesman) = token.getBuyFeeRatios();
            uint256 value = cap - supply <= 9_000_000 ether
                ? 100 ether
                : (price * 10000 + 9999 - platform - salesman) / (10000 - platform - salesman);
            vm.prank(buyer, buyer);
            token.buyToken{value: value}(0, creator, 0);
            assertLe(token.innerMarketBought(buyer), 10_000_000 ether);
        }
        uint256 budget = token.componentListingNativeBudget();
        MC.Call3[] memory calls = new MC.Call3[](2);
        calls[0] = DC.call(
            c.router,
            abi.encodeWithSignature("quote(address,address,uint256)", address(0), c.constituents[0], budget / 2)
        );
        calls[1] = DC.call(
            c.router,
            abi.encodeWithSignature(
                "quote(address,address,uint256)", address(0), c.constituents[1], budget - budget / 2
            )
        );
        MC.Result[] memory r = DC.aggregate(calls, pin);
        uint256[] memory mins = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            mins[i] = abi.decode(r[i].returnData, (uint256)) * 95 / 100;
            assertGt(mins[i], 0);
        }
        vm.prank(c.keeper);
        pump.finalizeTokenListing(address(token), mins, block.timestamp + 60);
    }
}
