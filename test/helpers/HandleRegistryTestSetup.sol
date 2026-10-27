// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Token} from "../../src/pump/Token.sol";

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

    /// @dev Fill through real capped buys by distinct registered wallets, then consolidate holdings.
    function _fillInnerMarket(Token target, address recipient) internal {
        vm.warp(target.createdAt() + 16);
        uint256 cap = 650_000_000 ether;
        while (target.bondingCurveSupply() < cap) {
            uint256 supply = target.bondingCurveSupply();
            uint256 remaining = cap - supply;
            address account = address(uint160(uint256(keccak256(abi.encode(address(target), supply, "v17-buyer")))));
            _registerHandle(account);
            vm.deal(account, 1000 ether);
            uint256 price = target.bondingCurve().getPrice(supply, 9_000_000 ether);
            (uint256 platform, uint256 salesman) = target.getBuyFeeRatios();
            uint256 denom = 10_000 - platform - salesman;
            uint256 value = remaining <= 9_000_000 ether ? 100 ether : (price * 10_000 + denom - 1) / denom;
            vm.startPrank(account, account);
            uint256 received = target.buyToken{value: value}(0, address(0), 0);
            target.transfer(recipient, received);
            vm.stopPrank();
            assertLe(target.innerMarketBought(account), target.INNER_MARKET_BUY_LIMIT());
        }
        assertTrue(target.listingPending());
    }
}
