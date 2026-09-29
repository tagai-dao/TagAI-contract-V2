// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test} from "./PumpVersion13.t.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {Token} from "../../src/pump/Token.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {TradeCuration} from "../../src/nutbox/dapps/trade-curation/TradeCuration.sol";
import {Vm} from "forge-std/Vm.sol";
import {ColdCallGas} from "../helpers/ColdCallGas.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";

interface ICreateOptional {
    function createToken(
        string calldata tick,
        bytes32 salt,
        IPump.IndexConfig calldata config,
        IPump.OptionalPoolConfig[] calldata pools
    ) external payable returns (address);
}

/// @dev Also inherits the V13 lifecycle regression suite against the upgraded Pump.
contract PumpVersion14Test is PumpVersion13Test, ColdCallGas {
    function _enableTrade() internal returns (TradeCurationFactory f) {
        f = new TradeCurationFactory(pump.nutboxCommunityFactory(), makeAddr("officialSigner"));
        committee.adminAddContract(address(f));
        pump.adminSetOptionalPoolFactory(address(f), "Trade Curation", 8000, true);
    }

    function _selection(address f, uint16 ratio) internal pure returns (IPump.OptionalPoolConfig[] memory p) {
        p = new IPump.OptionalPoolConfig[](1);
        p[0] = IPump.OptionalPoolConfig(f, ratio, bytes(""));
    }

    function _create14(IPump.IndexConfig memory c, IPump.OptionalPoolConfig[] memory p, uint256 value)
        internal
        returns (Token)
    {
        vm.prank(creator, creator);
        return Token(payable(pump.createToken{value: value}("V14", bytes32(uint256(14)), c, p)));
    }

    function _lastRatios(Vm.Log[] memory logs) internal pure returns (uint16[] memory ratios) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("AdminSetPoolRatio(address[],uint16[])")) {
                (, ratios) = abi.decode(logs[i].data, (address[], uint16[]));
            }
        }
    }

    function test_tradeAtMaximumAndIndexUnchanged() public {
        TradeCurationFactory f = _enableTrade();
        vm.recordLogs();
        Token t = _create14(_config(), _selection(address(f), 8000), pump.createFee());
        uint16[] memory ratios = _lastRatios(vm.getRecordedLogs());
        assertEq(ratios.length, 3);
        assertEq(ratios[0], 666);
        assertEq(ratios[1], 1334);
        assertEq(ratios[2], 8000);
        (, uint16 weight,) = t.componentAt(0);
        assertEq(weight, 3333);
        Community c = Community(payable(t.nutboxCommunity()));
        TradeCuration pool = TradeCuration(payable(c.activedPools(2)));
        assertEq(pool.community(), address(c));
        assertEq(pool.factory(), address(f));
        assertTrue(f.createdPoolOfCommunity(address(c)));
        assertEq(c.owner(), creator);
        assertEq(pump.VERSION(), 14);
        // Listing/buyback wiring still works with the additional reward pool.
        token = t;
        _list();
        assertTrue(t.listed());
        assertGt(t.indexToken().code.length, 0);
    }

    function test_emptyOptionalPoolsKeepsV13Ratios() public {
        vm.recordLogs();
        _create14(_config(), new IPump.OptionalPoolConfig[](0), pump.createFee());
        uint16[] memory ratios = _lastRatios(vm.getRecordedLogs());
        assertEq(ratios.length, 2);
        assertEq(ratios[0], 3333);
        assertEq(ratios[1], 6667);
    }

    function testFuzz_optionalRatiosSumExactly(uint16 rawRatio, uint16 rawWeight) public {
        TradeCurationFactory f = _enableTrade();
        uint16 ratio = uint16(bound(rawRatio, 1, 8000));
        IPump.IndexConfig memory c = _config();
        c.targetWeights[0] = uint16(bound(rawWeight, 1, 9999));
        c.targetWeights[1] = 10000 - c.targetWeights[0];
        vm.recordLogs();
        _create14(c, _selection(address(f), ratio), pump.createFee());
        uint16[] memory ratios = _lastRatios(vm.getRecordedLogs());
        assertEq(uint256(ratios[0]) + ratios[1] + ratios[2], 10000);
        assertEq(ratios[2], ratio);
        for (uint256 i; i < 2; ++i) {
            assertLt(_distance(uint256(ratios[i]) * 10000, uint256(c.targetWeights[i]) * (10000 - ratio)), 10000);
        }
    }

    function _distance(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function test_optionalPoolChargesExtraSettingsFeeAndPremineOnlyExcess() public {
        TradeCurationFactory f = _enableTrade();
        committee.adminSetCreateCommunityFee(0.001 ether);
        committee.adminSetCommunitySettingsFee(0.002 ether);
        uint256 fixedFee = pump.createFee() + 0.007 ether;
        uint256 receiverBefore = feeReceiver.balance;
        Token t = _create14(_config(), _selection(address(f), 3000), fixedFee);
        assertEq(t.balanceOf(creator), 0);
        assertEq(feeReceiver.balance - receiverBefore, fixedFee);
        assertEq(address(pump).balance, 0);
    }

    function test_insufficientExtraPoolFeeRevertsAtomically() public {
        TradeCurationFactory f = _enableTrade();
        committee.adminSetCommunitySettingsFee(0.002 ether);
        IPump.OptionalPoolConfig[] memory p = _selection(address(f), 3000);
        uint256 value = pump.createFee() + 0.004 ether;
        IPump.IndexConfig memory c = _config();
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InsufficientCreateFee.selector);
        pump.createToken{value: value}("V14", bytes32(uint256(14)), c, p);
        assertFalse(pump.createdTicks("V14"));
    }

    function _reject(IPump.OptionalPoolConfig[] memory p) internal {
        IPump.IndexConfig memory c = _config();
        uint256 value = pump.createFee();
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidOptionalPoolConfig.selector);
        pump.createToken{value: value}("BAD14", bytes32(uint256(140)), c, p);
        assertFalse(pump.createdTicks("BAD14"));
    }

    function test_rejectInvalidDisabledAndUnapprovedFactory() public {
        TradeCurationFactory f = _enableTrade();
        _reject(_selection(address(f), 0));
        _reject(_selection(address(f), 8001));
        _reject(_selection(makeAddr("unknownFactory"), 1000));
        pump.adminSetOptionalPoolFactory(address(f), "Trade", 8000, false);
        _reject(_selection(address(f), 1000));
        pump.adminSetOptionalPoolFactory(address(f), "Trade", 500, true);
        _reject(_selection(address(f), 501));
        committee.adminRemoveContract(address(f));
        _reject(_selection(address(f), 500));
    }

    function test_rejectDuplicateAndCombinedOver80Percent() public {
        TradeCurationFactory f = _enableTrade();
        TradeCurationFactory second = _enableTrade();
        IPump.OptionalPoolConfig[] memory p = new IPump.OptionalPoolConfig[](2);
        p[0] = IPump.OptionalPoolConfig(address(f), 4000, "");
        p[1] = IPump.OptionalPoolConfig(address(f), 4000, "");
        _reject(p);
        p[1] = IPump.OptionalPoolConfig(address(second), 4001, "");
        _reject(p);
        _reject(new IPump.OptionalPoolConfig[](3));
    }

    function test_ownerCanRegisterAnotherPoolTypeWithoutPumpUpgrade() public {
        TradeCurationFactory f = _enableTrade();
        address social = deployCode(
            "SocialCurationFactory.sol:SocialCurationFactory",
            abi.encode(pump.nutboxCommunityFactory(), makeAddr("socialSigner"))
        );
        committee.adminAddContract(social);
        pump.adminSetOptionalPoolFactory(social, "Social Curation", 2000, true);
        IPump.OptionalPoolConfig[] memory p = new IPump.OptionalPoolConfig[](2);
        p[0] = IPump.OptionalPoolConfig(address(f), 6000, "");
        p[1] = IPump.OptionalPoolConfig(social, 2000, "");
        IPump.IndexConfig memory config = _config();
        config.retainCommunityOwnership = false;
        vm.recordLogs();
        Token t = _create14(config, p, pump.createFee());
        uint16[] memory ratios = _lastRatios(vm.getRecordedLogs());
        assertEq(ratios.length, 4);
        assertEq(ratios[2], 6000);
        assertEq(ratios[3], 2000);
        assertEq(Community(payable(t.nutboxCommunity())).owner(), address(0));
        pump.adminSetOptionalPoolFactory(address(f), "Trade", 8000, false);
        assertEq(TradeCuration(payable(Community(payable(t.nutboxCommunity())).activedPools(2))).factory(), address(f));
    }

    function test_onlyOwnerCanConfigurePoolTypes() public {
        vm.prank(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        pump.adminSetOptionalPoolFactory(address(stakingFactory), "Invalid", 8000, true);
        vm.expectRevert(IPump.InvalidOptionalPoolConfig.selector);
        pump.adminSetOptionalPoolFactory(address(stakingFactory), "Invalid", 8001, true);
    }

    function _twoOptional() private returns (IPump.OptionalPoolConfig[] memory p) {
        p = new IPump.OptionalPoolConfig[](2);
        for (uint256 i; i < p.length; ++i) {
            p[i] = IPump.OptionalPoolConfig(address(_enableTrade()), 4000, "");
        }
    }

    function testFuzz_fourComponentsTwoOptionalIndependentAllocationOracle(uint256 seed) public {
        IPump.IndexConfig memory c = _countConfig(4);
        IPump.OptionalPoolConfig[] memory p = _twoOptional();
        uint256 totalOptional = bound(uint256(keccak256(abi.encode(seed, "total"))), 2, 8000);
        p[0].rewardRatio = uint16(bound(uint256(keccak256(abi.encode(seed, "optional"))), 1, totalOptional - 1));
        p[1].rewardRatio = uint16(totalOptional - p[0].rewardRatio);
        uint256 remainingWeight = 10000;
        for (uint256 i; i < 4; ++i) {
            c.targetWeights[i] = uint16(
                i == 3
                    ? remainingWeight
                    : bound(uint256(keccak256(abi.encode(seed, i, "weight"))), 1, remainingWeight - (3 - i))
            );
            remainingWeight -= c.targetWeights[i];
        }
        vm.recordLogs();
        _create14(c, p, pump.createFee());
        uint16[] memory ratios = _lastRatios(vm.getRecordedLogs());
        assertEq(ratios.length, 6);
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 numerator = uint256(c.targetWeights[i]) * (10000 - totalOptional);
            assertGe(ratios[i], numerator / 10000);
            assertLe(ratios[i], (numerator + 9999) / 10000);
            total += ratios[i];
        }
        for (uint256 i; i < p.length; ++i) {
            assertEq(ratios[i + 4], p[i].rewardRatio);
            total += ratios[i + 4];
        }
        assertEq(total, 10000);
    }

    function test_threeValidOptionalPoolsRejectedBeforeAnyCreation() public {
        IPump.OptionalPoolConfig[] memory p = new IPump.OptionalPoolConfig[](3);
        for (uint256 i; i < p.length; ++i) {
            p[i] = IPump.OptionalPoolConfig(address(_enableTrade()), 2000, "");
        }
        uint256 beforeTotal = pump.totalTokens();
        _reject(p);
        assertEq(pump.totalTokens(), beforeTotal);
        assertEq(pump.MAX_OPTIONAL_POOLS(), 2);
    }

    function test_stressFourComponentsTwoOptionalColdCreationAndActualRewards() public {
        IPump.IndexConfig memory c = _countConfig(4);
        c.targetWeights[0] = 1;
        c.targetWeights[1] = 1;
        c.targetWeights[2] = 1;
        c.targetWeights[3] = 9997;
        IPump.OptionalPoolConfig[] memory p = _twoOptional();
        creator = makeAddr("fresh-max-pools-creator");
        vm.deal(creator, 100 ether);
        committee.adminSetCreateCommunityFee(0.001 ether);
        committee.adminSetCommunitySettingsFee(0.001 ether);
        uint256 fee = pump.createFee() + ipshare.createFee() + 0.007 ether;
        bytes memory payload = abi.encodeCall(ICreateOptional.createToken, ("MAX14", bytes32(uint256(144)), c, p));
        (bytes memory result,) = _coldCall(
            "V14 4+2 cold create with IPShare and 1 BNB premine",
            creator,
            address(pump),
            fee + 1 ether,
            payload,
            10_000_000
        );
        Token t = Token(payable(abi.decode(result, (address))));
        Community community = Community(payable(t.nutboxCommunity()));
        assertGt(t.balanceOf(creator), 168_000 ether);
        vm.expectRevert();
        community.activedPools(6);
        // Use real Community accounting, not just emitted ratios. LP mocks have no stakers;
        // both virtual-stake pools must nevertheless receive their exact 40% allocation.
        HourlyTickCalculator calculator = HourlyTickCalculator(pump.getCalculator());
        vm.startPrank(creator, creator);
        t.approve(address(calculator), 168_000 ether);
        calculator.inject(address(community), 168_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 168 hours);
        for (uint256 i; i < p.length; ++i) {
            TradeCuration optional = TradeCuration(payable(community.activedPools(4 + i)));
            optional.harvestRewards();
            assertEq(t.balanceOf(address(optional)), 67_200 ether);
        }
        assertEq(t.balanceOf(address(community)), 33_600 ether, "unclaimed LP allocation stays in Community");
        assertEq(address(pump).balance, 0);
    }

    function test_lastOfSixPoolsFailureRollsBackFeesClonesIPShareAndCanRetry() public {
        IPump.IndexConfig memory c = _countConfig(4);
        IPump.OptionalPoolConfig[] memory p = _twoOptional();
        creator = makeAddr("rollback-max-pools-creator");
        vm.deal(creator, 100 ether);
        committee.adminSetCreateCommunityFee(0.001 ether);
        committee.adminSetCommunitySettingsFee(0.001 ether);
        uint256 fee = pump.createFee() + ipshare.createFee() + 0.007 ether;
        uint256 beforeCreator = creator.balance;
        uint256 beforeRecipient = feeReceiver.balance;
        uint256 beforeTotal = pump.totalTokens();
        address cf = pump.nutboxCommunityFactory();
        address expectedCommunity = vm.computeCreateAddress(cf, vm.getNonce(cf));
        bytes32 salt = bytes32(uint256(145));
        address expectedToken = Clones.predictDeterministicAddress(
            pump.tokenImplementation(), keccak256(abi.encode(creator, salt)), address(pump)
        );
        p[1].meta = hex"01"; // Only the very last pool factory rejects, after all prior deployments.
        vm.prank(creator, creator);
        vm.expectRevert("Unexpected meta");
        pump.createToken{value: fee + 1 ether}("ROLLBACK14", salt, c, p);
        assertEq(creator.balance, beforeCreator);
        assertEq(feeReceiver.balance, beforeRecipient);
        assertEq(pump.totalTokens(), beforeTotal);
        assertFalse(pump.createdTicks("ROLLBACK14"));
        assertFalse(ipshare.ipshareCreated(creator));
        assertEq(expectedToken.code.length, 0);
        assertEq(expectedCommunity.code.length, 0);
        for (uint256 i; i < p.length; ++i) {
            assertFalse(TradeCurationFactory(p[i].factory).createdPoolOfCommunity(expectedCommunity));
        }
        p[1].meta = "";
        vm.prank(creator, creator);
        address deployed = pump.createToken{value: fee + 1 ether}("ROLLBACK14", salt, c, p);
        assertEq(deployed, expectedToken);
        assertEq(Token(payable(deployed)).nutboxCommunity(), expectedCommunity);
        assertTrue(ipshare.ipshareCreated(creator));
    }
}
