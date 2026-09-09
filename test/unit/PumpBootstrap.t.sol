// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";

contract BootstrapAsset is ERC20 {
    constructor() ERC20("Asset", "A") {}
}

contract PumpBootstrapTest is Test {
    function _assets(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(new BootstrapAsset());
        }
    }

    function test_sixteenAssetsApprovedInConstructorWithEvents() public {
        address[] memory a = _assets(16);
        vm.recordLogs();
        Pump p = new Pump(address(1), address(2), a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(p) && logs[i].topics[0] == keccak256("ConstituentApprovalSet(address,bool)"))
            {
                assertTrue(abi.decode(logs[i].data, (bool)));
                assertEq(address(uint160(uint256(logs[i].topics[1]))), a[count++]);
            }
        }
        assertEq(count, 16);
        for (uint256 i; i < a.length; ++i) {
            assertTrue(p.approvedConstituent(a[i]));
        }
        assertEq(p.MAX_COMPONENTS(), 4);
        assertFalse(p.approvedConstituent(address(42)));
        assertEq(p.owner(), address(this));
        p.adminSetConstituentApproval(a[0], false);
        assertFalse(p.approvedConstituent(a[0]));
        assertTrue(p.approvedConstituent(a[1]));
        vm.prank(address(42));
        vm.expectRevert("Ownable: caller is not the owner");
        p.adminSetConstituentApproval(a[0], true);
    }

    function test_defaultCatalogExactlyMatchesRouterAssets() public pure {
        Config.AssetConfig[] memory sources = Config.assetConfigs();
        address[] memory a = Config.constituentAssets();
        assertEq(a.length, sources.length);
        assertEq(a.length, 16);
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i], sources[i].token);
            assertTrue(a[i] != Config.settlementToken() && a[i] != Config.wrappedNative());
        }
    }

    function test_emptyBootstrapAllowedForCustomDeployment() public {
        Pump p = new Pump(address(1), address(2), new address[](0));
        assertFalse(p.approvedConstituent(address(42)));
    }

    function test_zeroOrEOAAssetRejected() public {
        address[] memory a = new address[](1);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a);
        a[0] = address(42);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a);
    }

    function test_duplicateAssetRejected() public {
        address[] memory a = _assets(2);
        a[1] = a[0];
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a);
    }
}
