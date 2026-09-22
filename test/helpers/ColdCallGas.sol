// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Rehearse, roll back and cool every touched account before a bounded external call.
/// The estimate includes calldata intrinsic gas; it is not a wallet gas recommendation.
abstract contract ColdCallGas is Test {
    function _coldCallMustFail(address actor, address target, uint256 value, bytes memory payload, uint256 budget)
        internal
    {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(actor, actor);
        (bool ok, bytes memory result) = target.call{value: value}(payload);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < accesses.length; ++i) {
            vm.cool(accesses[i].account);
        }
        vm.cool(target);
        vm.prank(actor, actor);
        (ok,) = target.call{value: value, gas: budget}(payload);
        assertFalse(ok, "expected the bounded transaction to fail");
    }

    function _coldCall(
        string memory label,
        address actor,
        address target,
        uint256 value,
        bytes memory payload,
        uint256 budget
    ) internal returns (bytes memory result, uint256 totalGas) {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(actor, actor);
        (bool ok, bytes memory rehearsal) = target.call{value: value}(payload);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        if (!ok) assembly { revert(add(rehearsal, 32), mload(rehearsal)) }
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < accesses.length; ++i) {
            vm.cool(accesses[i].account);
        }
        vm.cool(target);
        vm.prank(actor, actor);
        (ok, result) = target.call{value: value, gas: budget}(payload);
        Vm.Gas memory used = vm.lastCallGas();
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        totalGas = uint256(used.gasLimit) - used.gasRemaining + 21_000;
        for (uint256 i; i < payload.length; ++i) {
            totalGas += payload[i] == 0 ? 4 : 16;
        }
        emit log_named_uint(label, totalGas);
        assertLt(totalGas, budget + 100_000, "gas regression exceeds test budget");
    }
}
