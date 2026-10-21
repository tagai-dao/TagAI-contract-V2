// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHandleRegistry} from "../../src/interfaces/IHandleRegistry.sol";

contract MockHandleRegistry is IHandleRegistry {
    mapping(address => string) public handleOf;

    function setHandle(address account, string calldata handle) external {
        handleOf[account] = handle;
    }
}

abstract contract HandleRegistryTestSetup is Test {
    address internal constant HANDLE_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function _setUpHandleRegistry() internal {
        vm.etch(HANDLE_REGISTRY, type(MockHandleRegistry).runtimeCode);
        _registerHandle(makeAddr("creator"));
        _registerHandle(makeAddr("buyer"));
    }

    function _registerHandle(address account) internal {
        MockHandleRegistry(HANDLE_REGISTRY).setHandle(account, "registered");
    }
}
