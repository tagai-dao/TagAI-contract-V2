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
    function test_bscInfrastructureReadyAtConstructionAndKeeperRemainsOwnerManaged() public {
        Pump p = new Pump(address(1), address(2), new address[](0), address(0));
        assertEq(p.getPoolManager(), 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
        assertEq(p.getVault(), 0x238a358808379702088667322f80aC48bAd5e6c4);
        assertEq(p.nutboxCommunityFactory(), 0x5597e814399906095ecaA5769A40394F58E5E0Cf);
        assertEq(p.getCalculator(), 0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d);
        assertEq(p.erc20StakingFactory(), 0xDc3f940ac6Da516d5C9cc59c8AFE0F85A576E2A4);
        assertEq(p.nutboxCommittee(), 0xe10F967DD356504EDB731612789D0D0f0ba2929f);
        assertEq(p.nutboxRouter(), 0x72dc4F38A7E4159e97d826a6ab594748C6b68f17);
        assertEq(p.basketHookV4(), 0x76983475f199C58d7BbA975220593c1c8B25f75e);
        assertEq(p.pancakeV2Factory(), 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
        assertEq(p.settlementToken(), 0x55d398326f99059fF775485246999027B3197955);
        assertEq(p.listingKeeper(), 0x8047FcC508446E2673195B8125d3388defc23688);
        assertEq(p.getHookAddress(), address(0));
        assertEq(p.buybackRouter(), address(0));
        vm.prank(address(42));
        vm.expectRevert("Ownable: caller is not the owner");
        p.adminSetListingKeeper(address(43));
        p.adminSetListingKeeper(address(43));
        assertEq(p.listingKeeper(), address(43));
    }

    function test_existingTemplateReusedWithoutDeployingAnotherToken() public {
        Pump first = new Pump(address(1), address(2), new address[](0), address(0));
        address template = first.tokenImplementation();
        assertGt(template.code.length, 0);
        assertEq(vm.getNonce(address(first)), 2);
        bytes32 originalCodeHash = template.codehash;
        Pump second = new Pump(address(1), address(2), new address[](0), template);
        assertEq(second.tokenImplementation(), template);
        assertEq(vm.getNonce(address(second)), 1, "reuse must not CREATE another Token");
        assertEq(template.codehash, originalCodeHash);
        assertEq(first.totalTokens(), 0);
        assertEq(second.totalTokens(), 0);
    }

    function test_existingTemplateWithoutCodeRejected() public {
        vm.expectRevert(IPump.InvalidTokenImplementation.selector);
        new Pump(address(1), address(2), new address[](0), address(42));
    }

    function _assets(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(new BootstrapAsset());
        }
    }

    function test_sixteenAssetsApprovedInConstructorWithEvents() public {
        address[] memory a = _assets(16);
        vm.recordLogs();
        Pump p = new Pump(address(1), address(2), a, address(0));
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
        Pump p = new Pump(address(1), address(2), new address[](0), address(0));
        assertFalse(p.approvedConstituent(address(42)));
    }

    function test_zeroOrEOAAssetRejected() public {
        address[] memory a = new address[](1);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a, address(0));
        a[0] = address(42);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a, address(0));
    }

    function test_duplicateAssetRejected() public {
        address[] memory a = _assets(2);
        a[1] = a[0];
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        new Pump(address(1), address(2), a, address(0));
    }
}
