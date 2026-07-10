// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title TokenProperty
 * @notice Property tests for Token (P5: Free Trade, P8: Total Supply Invariant).
 */
contract TokenPropertyTest is V4PumpTestBase {
    Token public token;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public override {
        super.setUp();
        if (!envReady) return;
        token = _createToken("PROP");
        vm.warp(block.timestamp + 16);
    }

    function testFuzz_P5_buyTokenNeverRevertsForSignatureReason(uint256 buyAmount) public onlyReady {
        buyAmount = bound(buyAmount, 0.01 ether, 5 ether);
        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) {} catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            assertTrue(
                selector != bytes4(keccak256("InvalidSignature()"))
                    && selector != bytes4(keccak256("InvalidGatePermission()"))
            );
        }
    }

    function testFuzz_P5_sellTokenNeverRevertsForSignatureReason(uint256 buyAmount, uint256 sellFraction)
        public
        onlyReady
    {
        buyAmount = bound(buyAmount, 0.5 ether, 3 ether);
        sellFraction = bound(sellFraction, 1, 100);
        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) returns (uint256 received) {
            uint256 sellAmount = (received * sellFraction) / 100;
            if (sellAmount < 1e8 || token.listed()) return;

            vm.prank(buyer, buyer);
            try token.sellToken(sellAmount, 0, creator, 0) {} catch (bytes memory reason) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                assertTrue(
                    selector != bytes4(keccak256("InvalidSignature()"))
                        && selector != bytes4(keccak256("InvalidGatePermission()"))
                );
            }
        } catch {}
    }

    function testFuzz_P8_totalSupplyInvariant_afterBuy(uint256 buyAmount) public onlyReady {
        buyAmount = bound(buyAmount, 0.01 ether, 5 ether);
        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) {} catch {}
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }

    function testFuzz_P8_totalSupplyInvariant_afterBuyAndSell(uint256 buyAmount, uint256 sellFraction)
        public
        onlyReady
    {
        buyAmount = bound(buyAmount, 0.5 ether, 3 ether);
        sellFraction = bound(sellFraction, 10, 90);
        if (token.listed()) {
            vm.skip(true);
            return;
        }

        vm.prank(buyer, buyer);
        try token.buyToken{value: buyAmount}(0, creator, 0) returns (uint256 received) {
            if (!token.listed() && (received * sellFraction) / 100 >= 1e8) {
                vm.prank(buyer, buyer);
                try token.sellToken((received * sellFraction) / 100, 0, creator, 0) {} catch {}
            }
        } catch {}
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }
}
