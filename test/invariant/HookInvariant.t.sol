// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {Token} from "../../src/pump/Token.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

contract AttackerHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TagAISwapHook public hook;
    Token public token;
    address public attacker;

    constructor(TagAISwapHook _hook, Token _token, address _attacker) {
        hook = _hook;
        token = _token;
        attacker = _attacker;
    }

    function tryTransfer(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000 ether);
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        vm.prank(attacker);
        (bool success,) = address(hook).call(abi.encodeWithSelector(selector, attacker, amount));
        assertFalse(success);
    }

    function tryRegisterPool(uint256 poolIdSeed) external {
        vm.prank(attacker);
        try hook.registerPool(PoolId.wrap(bytes32(poolIdSeed)), address(token)) {} catch {}
    }

    function tryDirectCallback(uint256 mode) external {
        mode = mode % 3;
        if (mode == 0) {
            vm.prank(attacker);
            try hook.beforeInitialize(attacker, _emptyKey(), 0) {} catch {}
        }
    }

    function _emptyKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

/**
 * @title HookInvariantTest
 * @notice Attacker calls must not drain Hook token balance (Uniswap v4 stack).
 */
contract HookInvariantTest is StdInvariant, V4ListedTokenTestBase {
    AttackerHandler public handler;
    address internal attacker;
    uint256 public initialHookBalance;

    function setUp() public override {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1000 ether);
        super.setUp();
        if (!envReady) return;

        initialHookBalance = IERC20(address(token)).balanceOf(address(hook));
        handler = new AttackerHandler(hook, token, attacker);
        targetContract(address(handler));
    }

    function invariant_P7_hookBalanceUnchangedByAttacker() public {
        assertEq(IERC20(address(token)).balanceOf(address(hook)), initialHookBalance);
    }
}
