// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../src/pump/Token.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title FullLifecycleTest
 * @notice End-to-end: createToken → fill curve → list → Hook Nutbox settlement (Uniswap v4)。
 * @dev V11 余额制注入：注入量用 calculator.totalInjected 校验。
 */
contract FullLifecycleTest is V4PumpTestBase {
    address internal buyer1;
    address internal buyer2;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public override {
        buyer1 = makeAddr("buyer1");
        buyer2 = makeAddr("buyer2");
        vm.deal(buyer1, 1000 ether);
        vm.deal(buyer2, 1000 ether);
        super.setUp();
    }

    function _injected(Token t) internal view returns (uint256) {
        return calculator.totalInjected(t.nutboxCommunity());
    }

    function test_fullLifecycle_createAndList() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("TEST", bytes32(uint256(1)));
        Token t = Token(payable(tokenAddr));

        assertTrue(pump.createdTokens(tokenAddr));
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY);
        assertFalse(t.listed());
        assertTrue(t.nutboxCommunity() != address(0));

        _fillBondingCurveUntilListed(t, buyer1);
        assertTrue(t.listed());
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY);
    }

    function test_hookInjection_decreasesOnBuy() public onlyReady {
        Token t = _createAndListToken("HOOK1");
        assertEq(t.balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox allocation");

        uint256 injected0 = _injected(t);
        uint256 gross = _simulateHookBuy(t, 0.5 ether);
        assertEq(_injected(t), injected0, "same period: no inject");

        _warpNextHookPeriod();
        _simulateHookBuy(t, 0.01 ether);

        (,, uint256 injectAmount) = hook.previewPeriodSettle(gross);
        if (injectAmount >= HOOK_MIN_INJECT_OUTPUT) {
            assertEq(_injected(t) - injected0, injectAmount, "inject on next-period first buy");
        }
    }

    function test_hookInjection_unchangedOnSell() public onlyReady {
        Token t = _createAndListToken("HOOK2");
        uint256 injected0 = _injected(t);
        _simulateHookSell(t, 10_000 ether);
        assertEq(_injected(t), injected0, "sell never injects");
    }

    function test_totalSupply_invariant() public onlyReady {
        Token t = _createAndListToken("SUPPLY");
        assertEq(IERC20(address(t)).totalSupply(), TOTAL_SUPPLY);
    }

    function test_multipleBuySwaps_monotonicInject() public onlyReady {
        Token t = _createAndListToken("MONO");
        uint256 prevInjected = _injected(t);

        for (uint256 i = 0; i < 5; i++) {
            _simulateHookBuy(t, 0.3 ether);
            _warpNextHookPeriod();
            _simulateHookBuy(t, 0.01 ether); // settle prior period
            uint256 currentInjected = _injected(t);
            assertGe(currentInjected, prevInjected, "inject is monotonic non-decreasing");
            prevInjected = currentInjected;
        }
    }

    function test_buyBelowMinimum_noInject() public onlyReady {
        Token t = _createAndListToken("SMALL");
        uint256 injected0 = _injected(t);
        // 极小 ETH：毛成交额产生的注入量 < MIN_INJECT_OUTPUT → 结算跳过。
        uint256 gross = _simulateHookBuy(t, 1e10 wei);
        _warpNextHookPeriod();
        _simulateHookBuy(t, 0.01 ether);
        assertEq(_injected(t), injected0, "below MIN_INJECT_OUTPUT: skip");
        assertLt(gross, _minPeriodVolumeForSettle(), "gross below min settle volume");
    }
}
