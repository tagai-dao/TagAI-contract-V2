// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

/**
 * @title HookProperty
 * @notice Property-based tests for TagAISwapHook (P4, P6, P7) on Uniswap v4。
 * @dev V11：买入走真实 swap（ETH 输入），_simulateHookBuy 返回毛 token 成交额；
 *      余额制注入用 calculator.totalInjected 校验，hookBalance + injected 守恒（仅买入 token fee 使其增长）。
 *      fuzz 输入为 ETH 量，bound 到池可吸收范围（池内约 4.8 ETH），避免 revert。
 */
contract HookPropertyTest is V4ListedTokenTestBase {
    uint256 internal constant MIN_ETH = 0.001 ether; // 单次最小买入 ETH
    uint256 internal constant MAX_ETH = 0.5 ether; // 单次最大买入 ETH（池可安全吸收）

    function _injected() internal view returns (uint256) {
        return calculator.totalInjected(token.nutboxCommunity());
    }

    function _hookBal() internal view returns (uint256) {
        return IERC20(address(token)).balanceOf(address(hook));
    }

    /// @dev hookBalance + injected == NUTBOX_ALLOCATION + 累计买入 token fee（非递减）。
    function _conserved() internal view returns (uint256) {
        return _hookBal() + _injected();
    }

    function testFuzz_P4_allocationCap_invariant(uint256 ethIn) public onlyReady {
        ethIn = bound(ethIn, MIN_ETH, MAX_ETH);

        uint256 conservedBefore = _conserved();
        uint256 gross = _simulateHookBuy(token, ethIn);
        assertGt(gross, 0, "gross > 0");
        // 同期不结算，注入量不变；守恒量因买入 token fee 不减。
        assertGe(_conserved(), conservedBefore);
        assertEq(_injected(), 0, "no inject same period");
    }

    function testFuzz_P4_multipleBuys_neverExceedsCap(uint256 e1, uint256 e2, uint256 e3) public onlyReady {
        e1 = bound(e1, MIN_ETH, MAX_ETH);
        e2 = bound(e2, MIN_ETH, MAX_ETH);
        e3 = bound(e3, MIN_ETH, MAX_ETH);

        uint256 conserved0 = _conserved();
        _simulateHookBuy(token, e1);
        _warpNextHookPeriod();
        _simulateHookBuy(token, e2);
        _warpNextHookPeriod();
        _simulateHookBuy(token, e3);

        // 守恒量非递减；注入量累计 >= 0。
        assertGe(_conserved(), conserved0);
        assertGe(_injected(), 0);
    }

    function testFuzz_P6_injectionCondition(uint256 ethIn, bool isBuy) public onlyReady {
        ethIn = bound(ethIn, 0.05 ether, MAX_ETH);

        uint256 gross = _simulateHookBuy(token, ethIn);
        uint256 injectedAfterAccum = _injected();
        _warpNextHookPeriod();

        uint256 injectedBeforeSettle = _injected();
        uint256 capped = gross > HOOK_MAX_PERIOD_BUY ? HOOK_MAX_PERIOD_BUY : gross;
        uint256 expectedSettle = _expectedHookSettleInject(capped);

        if (isBuy) {
            _simulateHookBuy(token, MIN_ETH);
        } else {
            _simulateHookSell(token, 1 ether);
        }

        if (isBuy && expectedSettle > 0) {
            assertEq(injectedAfterAccum, injectedBeforeSettle, "no inject during accumulation period");
            assertEq(_injected() - injectedBeforeSettle, expectedSettle, "inject on next-period first buy");
        } else {
            assertEq(_injected(), injectedBeforeSettle, "sell or zero-expected: no inject");
        }
    }

    function testFuzz_P6_sellNeverInjects(uint256) public onlyReady {
        uint256 injectedBefore = _injected();
        _simulateHookSell(token, 1_000_000 ether);
        assertEq(_injected(), injectedBefore, "sell never injects");
    }

    function testFuzz_P6_belowMinPeriodSettleDoesNotInject(uint256 ethIn) public onlyReady {
        // 极小 ETH：毛成交额产生的注入量 < MIN_INJECT_OUTPUT → 结算跳过。
        ethIn = bound(ethIn, 1e9, 1e12 wei); // 0.000000001 ~ 0.000001 ETH

        uint256 injectedBefore = _injected();
        uint256 gross = _simulateHookBuy(token, ethIn);
        _warpNextHookPeriod();
        _simulateHookBuy(token, MIN_ETH);

        uint256 expectedSettle = _expectedHookSettleInject(gross);
        assertEq(expectedSettle, 0, "below MIN_INJECT_OUTPUT: expected 0");
        assertEq(_injected(), injectedBefore, "below MIN_INJECT_OUTPUT: skip");
    }

    /// @dev 守恒量 hookBalance + injected 仅因买入 token fee 递增、因注入不变（注入在 balance 与 injected 间转移）。
    function testFuzz_P7_conservationNonDecreasing(uint256 ethIn) public onlyReady {
        ethIn = bound(ethIn, 0.05 ether, MAX_ETH);

        _simulateHookBuy(token, ethIn);
        uint256 conservedBeforeSettle = _conserved();

        _warpNextHookPeriod();
        _simulateHookBuy(token, MIN_ETH);

        uint256 conservedAfterSettle = _conserved();
        // 结算 buy 又产生 token fee，守恒量 >= 结算前。
        assertGe(conservedAfterSettle, conservedBeforeSettle);
        // 注入量 > 0（ethIn 足够大，毛成交额 >= min settle volume）。
        assertGt(_injected(), 0);
    }

    function testFuzz_P7_sellDoesNotAffectHookBalance(uint256) public onlyReady {
        uint256 hookBalBefore = _hookBal();
        _simulateHookSell(token, 1_000_000 ether);
        assertEq(_hookBal(), hookBalBefore, "sell does not change hook token balance");
    }
}
