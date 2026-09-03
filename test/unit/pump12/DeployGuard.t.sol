// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {DeployPump12RHScript} from "../../../script/DeployPump12RH.s.sol";

contract MockUsdG6 {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MockUsdG18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockPoolManagerCode {}

contract DeployGuardTest is Test {
    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    DeployPump12RHScript internal script;

    function setUp() public {
        vm.chainId(RH_CHAIN_ID);
        _etchUsdG6();
        _etchPoolManager();
        script = new DeployPump12RHScript();
    }

    function test_constructorAcceptsCanonicalRobinhoodConfig() public {
        Pump12 pump = new Pump12(USDG, POOL_MANAGER);

        assertEq(pump.usdg(), USDG);
        assertEq(pump.poolManager(), POOL_MANAGER);
    }

    function test_constructorRejectsWrongChain() public {
        vm.chainId(31337);

        vm.expectRevert(abi.encodeWithSelector(Pump12.UnsupportedChain.selector, 31337));
        new Pump12(USDG, POOL_MANAGER);
    }

    function test_constructorRejectsNonCanonicalUsdG() public {
        address fakeUsdG = address(new MockUsdG6());

        vm.expectRevert(abi.encodeWithSelector(Pump12.InvalidUsdG.selector, fakeUsdG));
        new Pump12(fakeUsdG, POOL_MANAGER);
    }

    function test_constructorRejectsUsdGWithoutCode() public {
        vm.etch(USDG, bytes(""));

        vm.expectRevert(abi.encodeWithSelector(Pump12.UsdGHasNoCode.selector, USDG));
        new Pump12(USDG, POOL_MANAGER);
    }

    function test_constructorRejectsWrongUsdGDecimals() public {
        MockUsdG18 mock = new MockUsdG18();
        vm.etch(USDG, address(mock).code);

        vm.expectRevert(abi.encodeWithSelector(Pump12.InvalidUsdGDecimals.selector, 18));
        new Pump12(USDG, POOL_MANAGER);
    }

    function test_constructorRejectsNonCanonicalPoolManager() public {
        address fakePoolManager = address(new MockPoolManagerCode());

        vm.expectRevert(abi.encodeWithSelector(Pump12.InvalidPoolManager.selector, fakePoolManager));
        new Pump12(USDG, fakePoolManager);
    }

    function test_constructorRejectsPoolManagerWithoutCode() public {
        vm.etch(POOL_MANAGER, bytes(""));

        vm.expectRevert(abi.encodeWithSelector(Pump12.PoolManagerHasNoCode.selector, POOL_MANAGER));
        new Pump12(USDG, POOL_MANAGER);
    }

    function test_scriptRejectsWrongChain() public {
        vm.chainId(31337);

        vm.expectRevert("Pump12: unsupported chain");
        script.validateConfig(USDG, POOL_MANAGER);
    }

    function test_scriptRejectsNonCanonicalUsdG() public {
        address fakeUsdG = address(new MockUsdG6());

        vm.expectRevert("Pump12: non-canonical USDG");
        script.validateConfig(fakeUsdG, POOL_MANAGER);
    }

    function test_scriptRejectsUsdGWithoutCode() public {
        vm.etch(USDG, bytes(""));

        vm.expectRevert("Pump12: USDG has no code");
        script.validateConfig(USDG, POOL_MANAGER);
    }

    function test_scriptRejectsWrongUsdGDecimals() public {
        MockUsdG18 mock = new MockUsdG18();
        vm.etch(USDG, address(mock).code);

        vm.expectRevert("Pump12: USDG decimals must be 6");
        script.validateConfig(USDG, POOL_MANAGER);
    }

    function test_scriptRejectsNonCanonicalPoolManager() public {
        address fakePoolManager = address(new MockPoolManagerCode());

        vm.expectRevert("Pump12: non-canonical PoolManager");
        script.validateConfig(USDG, fakePoolManager);
    }

    function test_scriptRejectsPoolManagerWithoutCode() public {
        vm.etch(POOL_MANAGER, bytes(""));

        vm.expectRevert("Pump12: PoolManager has no code");
        script.validateConfig(USDG, POOL_MANAGER);
    }

    function _etchUsdG6() internal {
        MockUsdG6 mock = new MockUsdG6();
        vm.etch(USDG, address(mock).code);
    }

    function _etchPoolManager() internal {
        MockPoolManagerCode mock = new MockPoolManagerCode();
        vm.etch(POOL_MANAGER, address(mock).code);
    }
}
