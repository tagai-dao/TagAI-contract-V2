// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {UsdG} from "../../../src/pump12/libraries/UsdG.sol";

contract UsdGHarness {
    function toWad(uint256 raw6) external pure returns (uint256) {
        return UsdG.toWad(raw6);
    }

    function toRaw6(uint256 wad) external pure returns (uint256) {
        return UsdG.toRaw6(wad);
    }

    function toRaw6Up(uint256 wad) external pure returns (uint256) {
        return UsdG.toRaw6Up(wad);
    }
}

contract UsdGTest is Test {
    UsdGHarness internal harness;

    function setUp() public {
        harness = new UsdGHarness();
    }

    function test_constants() public pure {
        assertEq(UsdG.WAD, 1e18);
        assertEq(UsdG.RAW_SCALE, 1e6);
        assertEq(UsdG.WAD_PER_RAW, 1e12);
    }

    function test_toWad_oneUSDG() public view {
        assertEq(harness.toWad(1e6), 1e18);
    }

    function test_toRaw6_externalPaymentRoundsDown() public view {
        assertEq(harness.toRaw6(0), 0);
        assertEq(harness.toRaw6(1), 0);
        assertEq(harness.toRaw6(1e12 - 1), 0);
        assertEq(harness.toRaw6(1e12), 1);
        assertEq(harness.toRaw6(1e12 + 1), 1);
    }

    function test_toRaw6Up_protocolAccountingRoundsUp() public view {
        assertEq(harness.toRaw6Up(0), 0);
        assertEq(harness.toRaw6Up(1), 1);
        assertEq(harness.toRaw6Up(1e12 - 1), 1);
        assertEq(harness.toRaw6Up(1e12), 1);
        assertEq(harness.toRaw6Up(1e12 + 1), 2);
    }

    function testFuzz_rawRoundTrip(uint256 raw6) public view {
        raw6 = bound(raw6, 0, type(uint256).max / UsdG.WAD_PER_RAW);
        uint256 wad = harness.toWad(raw6);

        assertEq(harness.toRaw6(wad), raw6);
        assertEq(harness.toRaw6Up(wad), raw6);
    }
}
