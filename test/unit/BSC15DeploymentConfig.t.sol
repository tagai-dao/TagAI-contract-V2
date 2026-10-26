// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "../../script/config/BSC15DeploymentConfig.sol";

contract ConfigMulticallFixture is MC {
    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory results) {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory data) = calls[i].target.call(calls[i].callData);
            require(ok || calls[i].allowFailure, "Multicall3: call failed");
            results[i] = Result(ok, data);
        }
    }
}

contract ConfigReadTarget {
    address constant MC3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    function first() external view returns (uint256) {
        require(msg.sender == MC3, "Direct reads forbidden");
        return 11;
    }

    function second() external view returns (uint256) {
        require(msg.sender == MC3, "Direct reads forbidden");
        return 22;
    }
}

contract ConfigReadProbe {
    function read(address target, uint256 pin) external returns (MC.Result[] memory) {
        MC.Call3[] memory calls = new MC.Call3[](2);
        calls[0] = DC.get(target, "first()");
        calls[1] = DC.get(target, "second()");
        return DC.aggregate(calls, pin);
    }

    function loadFrom(uint256 pin, address previous, uint256 version) external returns (DC.Config memory) {
        return DC.loadFrom(pin, previous, version);
    }

    function pumpCalls(address pump) external pure returns (MC.Call3[] memory) {
        return DC.pumpCalls(pump);
    }
}

contract BSC15DeploymentConfigTest is Test {
    address constant MC3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    ConfigReadProbe probe;
    ConfigReadTarget target;

    function setUp() public {
        vm.etch(MC3, type(ConfigMulticallFixture).runtimeCode);
        vm.roll(123456);
        probe = new ConfigReadProbe();
        target = new ConfigReadTarget();
    }

    function _pinned() internal view returns (MC.Call3[] memory calls) {
        calls = new MC.Call3[](3);
        calls[0] = MC.Call3(MC3, false, abi.encodeCall(MC.getBlockNumber, ()));
        calls[1] = MC.Call3(address(target), false, abi.encodeCall(ConfigReadTarget.first, ()));
        calls[2] = MC.Call3(address(target), false, abi.encodeCall(ConfigReadTarget.second, ()));
    }

    function _results() internal view returns (MC.Result[] memory r) {
        r = new MC.Result[](3);
        r[0] = MC.Result(true, abi.encode(block.number));
        r[1] = MC.Result(true, abi.encode(uint256(11)));
        r[2] = MC.Result(true, abi.encode(uint256(22)));
    }

    function test_batchTargetsMulticallExactSubcallsAndPinnedBlock() public {
        vm.expectCall(MC3, abi.encodeCall(MC.aggregate3, (_pinned())));
        MC.Result[] memory r = probe.read(address(target), block.number);
        assertEq(abi.decode(r[0].returnData, (uint256)), 11);
        assertEq(abi.decode(r[1].returnData, (uint256)), 22);
    }

    function test_rejectsBlockMovementBetweenStages() public {
        vm.roll(123457);
        vm.expectRevert(DC.SnapshotChanged.selector);
        probe.read(address(target), 123456);
    }

    function test_rejectsWrongReportedBlock() public {
        MC.Result[] memory r = _results();
        r[0].returnData = abi.encode(block.number + 1);
        vm.mockCall(MC3, abi.encodeCall(MC.aggregate3, (_pinned())), abi.encode(r));
        vm.expectRevert(DC.SnapshotChanged.selector);
        probe.read(address(target), block.number);
    }

    function test_rejectsMissingRequiredData() public {
        MC.Result[] memory r = _results();
        r[2].returnData = "";
        vm.mockCall(MC3, abi.encodeCall(MC.aggregate3, (_pinned())), abi.encode(r));
        vm.expectRevert(abi.encodeWithSelector(DC.RequiredReadFailed.selector, 1, address(target)));
        probe.read(address(target), block.number);
    }

    function test_rejectsRequiredSubcallFailure() public {
        MC.Result[] memory r = _results();
        r[1].success = false;
        vm.mockCall(MC3, abi.encodeCall(MC.aggregate3, (_pinned())), abi.encode(r));
        vm.expectRevert(abi.encodeWithSelector(DC.RequiredReadFailed.selector, 0, address(target)));
        probe.read(address(target), block.number);
    }

    function test_v17LoadsV16ThroughMulticallAtPinnedBlockAndRejectsWrongVersion() public {
        address previous = 0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8;
        MC.Call3[] memory subcalls = probe.pumpCalls(previous);
        MC.Call3[] memory calls = new MC.Call3[](subcalls.length + 1);
        calls[0] = MC.Call3(MC3, false, abi.encodeCall(MC.getBlockNumber, ()));
        MC.Result[] memory r = new MC.Result[](calls.length);
        r[0] = MC.Result(true, abi.encode(block.number));
        for (uint256 i; i < subcalls.length; ++i) {
            assertEq(subcalls[i].target, previous);
            assertFalse(subcalls[i].allowFailure);
            calls[i + 1] = subcalls[i];
            r[i + 1] = MC.Result(true, abi.encode(uint256(0)));
        }
        assertEq(calls[19].callData, abi.encodeWithSignature("VERSION()"));
        r[19].returnData = abi.encode(uint256(15));
        bytes memory payload = abi.encodeCall(MC.aggregate3, (calls));
        vm.mockCall(MC3, payload, abi.encode(r));
        vm.expectCall(MC3, payload);
        vm.expectRevert("Unexpected previous Pump version");
        probe.loadFrom(block.number, previous, 16);
    }

    function test_exactPreviousPumpConfigurationSubcallSet() public view {
        address p = 0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34;
        string[20] memory names = [
            "owner()",
            "getIPShare()",
            "getFeeReceiver()",
            "getPoolManager()",
            "getVault()",
            "nutboxCommunityFactory()",
            "getCalculator()",
            "erc20StakingFactory()",
            "nutboxCommittee()",
            "nutboxRouter()",
            "basketHookV4()",
            "pancakeV2Factory()",
            "settlementToken()",
            "listingKeeper()",
            "buybackRouter()",
            "createFee()",
            "getFeeRatio()",
            "listingSwapSlippageBps()",
            "VERSION()",
            "tokenImplementation()"
        ];
        MC.Call3[] memory calls = probe.pumpCalls(p);
        assertEq(calls.length, names.length);
        for (uint256 i; i < calls.length; ++i) {
            assertEq(calls[i].target, p);
            assertFalse(calls[i].allowFailure);
            assertEq(calls[i].callData, abi.encodeWithSignature(names[i]));
        }
    }
}
