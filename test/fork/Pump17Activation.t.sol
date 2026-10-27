// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "../../script/config/BSC15DeploymentConfig.sol";

/// @notice Executes the exact exported activation calldata only in a disposable fork.
/// @dev Validates target privileges/state transitions; does not simulate Safe signatures or send proposals.
contract Pump17ActivationForkTest is Test {
    function test_exportedActivationCallsSucceedOnDeployedMainnetContracts() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envOr("PUMP17_ACTIVATION_BLOCK", uint256(129862871));
        vm.createSelectFork(rpc, pin);
        assertEq(block.chainid, 56);
        string memory actions = vm.readFile("deployments/56/version17-owner-actions.json");
        address pump = vm.parseJsonAddress(actions, ".Pump");
        address safe = 0x871fb7006C5964B21695Ba20006021777A26146C;
        address router = vm.parseJsonAddress(actions, ".operations[0].target");
        address registry = vm.parseJsonAddress(actions, ".operations[1].target");
        MC.Call3[] memory reads = new MC.Call3[](5);
        reads[0] = DC.get(pump, "VERSION()");
        reads[1] = DC.get(pump, "owner()");
        reads[2] = DC.get(pump, "pendingOwner()");
        reads[3] = DC.call(router, abi.encodeWithSignature("operators(address)", pump));
        reads[4] = DC.call(registry, abi.encodeWithSignature("approvedCreatorForwarders(address)", pump));
        MC.Result[] memory beforeState = DC.aggregate(reads, pin);
        assertEq(abi.decode(beforeState[0].returnData, (uint256)), 17);
        assertEq(DC.addr(beforeState, 2), safe);
        assertFalse(DC.flag(beforeState, 3));
        assertFalse(DC.flag(beforeState, 4));
        for (uint256 i; i < 3; ++i) {
            string memory prefix = string.concat(".operations[", vm.toString(i), "]");
            address target = vm.parseJsonAddress(actions, string.concat(prefix, ".target"));
            address sender = vm.parseJsonAddress(actions, string.concat(prefix, ".requiredSender"));
            assertEq(sender, safe);
            assertEq(vm.parseJsonString(actions, string.concat(prefix, ".value")), "0");
            bytes memory data = vm.parseJsonBytes(actions, string.concat(prefix, ".calldata"));
            vm.prank(safe);
            (bool ok, bytes memory reason) = target.call(data);
            if (!ok) assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        MC.Result[] memory afterState = DC.aggregate(reads, pin);
        assertEq(DC.addr(afterState, 1), safe);
        assertEq(DC.addr(afterState, 2), address(0));
        assertTrue(DC.flag(afterState, 3));
        assertTrue(DC.flag(afterState, 4));
        assertEq(block.number, pin);
    }
}
