// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "../../script/config/BSC15DeploymentConfig.sol";

/// @notice Runs exported V19 owner calldata only in a disposable fork; never proposes or signs a Safe transaction.
contract Pump19ActivationForkTest is Test {
    function test_actualDeploymentExportedSafeCalls() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        uint256 pin = vm.envUint("PUMP19_ACTIVATION_BLOCK");
        vm.createSelectFork(rpc, pin);
        assertEq(block.chainid, 56);
        string memory actions = vm.readFile("deployments/56/version19-owner-actions.json");
        address pump = vm.parseJsonAddress(actions, ".Pump");
        address safe = vm.parseJsonAddress(actions, ".safe");
        address router = vm.parseJsonAddress(actions, ".operations[0].target");
        address registry = vm.parseJsonAddress(actions, ".operations[1].target");
        address trader = vm.parseJsonAddress(actions, ".operations[3].target");
        address adapter = vm.parseJsonAddress(actions, ".operations[4].target");
        string memory deployment = vm.readFile("deployments/56/version19.json");
        address hook = vm.parseJsonAddress(deployment, ".TagAISwapHook");
        address previous = vm.parseJsonAddress(deployment, ".PreviousPump");
        address oldHook = vm.parseJsonAddress(deployment, ".preservedV18Configuration.getHookAddress");
        MC.Call3[] memory calls = new MC.Call3[](12);
        calls[0] = DC.get(pump,"VERSION()");
        calls[1] = DC.get(pump,"owner()");
        calls[2] = DC.get(pump,"pendingOwner()");
        calls[3] = DC.call(router,abi.encodeWithSignature("operators(address)",pump));
        calls[4] = DC.call(registry,abi.encodeWithSignature("approvedCreatorForwarders(address)",pump));
        calls[5] = DC.call(trader,abi.encodeWithSignature("pumpEnabled(address)",pump));
        calls[6] = DC.call(adapter,abi.encodeWithSignature("hookPolicies(address)",hook));
        calls[7] = DC.get(previous,"owner()");
        calls[8] = DC.call(router,abi.encodeWithSignature("operators(address)",previous));
        calls[9] = DC.call(registry,abi.encodeWithSignature("approvedCreatorForwarders(address)",previous));
        calls[10] = DC.call(trader,abi.encodeWithSignature("pumpEnabled(address)",previous));
        calls[11] = DC.call(adapter,abi.encodeWithSignature("hookPolicies(address)",oldHook));
        MC.Result[] memory beforeState = DC.aggregate(calls,pin);
        assertEq(abi.decode(beforeState[0].returnData,(uint256)),19);
        assertEq(DC.addr(beforeState,2),safe);
        assertFalse(DC.flag(beforeState,3)); assertFalse(DC.flag(beforeState,4)); assertFalse(DC.flag(beforeState,5));
        assertEq(vm.parseJsonUint(actions,".safeIncludedOperations"),5);
        for(uint256 i;i<5;i++) {
            string memory prefix = string.concat(".operations[",vm.toString(i),"]");
            address target = vm.parseJsonAddress(actions,string.concat(prefix,".target"));
            address sender = vm.parseJsonAddress(actions,string.concat(prefix,".requiredSender"));
            assertEq(sender,safe);
            assertEq(vm.parseJsonString(actions,string.concat(prefix,".value")),"0");
            bytes memory data = vm.parseJsonBytes(actions,string.concat(prefix,".calldata"));
            vm.prank(sender);
            (bool ok,bytes memory reason)=target.call(data);
            if(!ok)assembly("memory-safe"){revert(add(reason,32),mload(reason))}
        }
        MC.Result[] memory afterState = DC.aggregate(calls,pin);
        assertEq(DC.addr(afterState,1),safe); assertEq(DC.addr(afterState,2),address(0));
        assertTrue(DC.flag(afterState,3)); assertTrue(DC.flag(afterState,4)); assertTrue(DC.flag(afterState,5));
        (bytes32 codeHash,uint16 platform,uint16 subject,uint16 buyback)=abi.decode(afterState[6].returnData,(bytes32,uint16,uint16,uint16));
        assertEq(codeHash,hook.codehash);assertEq(platform,30);assertEq(subject,30);assertEq(buyback,30);
        for(uint256 i=7;i<12;i++)assertEq(afterState[i].returnData,beforeState[i].returnData);
    }
}
