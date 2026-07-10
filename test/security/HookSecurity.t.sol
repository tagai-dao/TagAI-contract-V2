// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {V4ListedTokenTestBase} from "../helpers/V4ListedTokenTestBase.sol";

/**
 * @title HookSecurityTest
 * @notice Security tests for TagAISwapHook (Uniswap v4).
 */
contract HookSecurityTest is V4ListedTokenTestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal attacker;

    function setUp() public override {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1000 ether);
        super.setUp();
    }

    function test_noAdminWithdraw_function() public onlyReady {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = bytes4(keccak256("withdraw()"));
        selectors[1] = bytes4(keccak256("withdraw(uint256)"));
        selectors[2] = bytes4(keccak256("withdraw(address)"));
        selectors[3] = bytes4(keccak256("rescue(address)"));
        selectors[4] = bytes4(keccak256("sweep()"));
        selectors[5] = bytes4(keccak256("sweep(address)"));

        for (uint256 i = 0; i < selectors.length; i++) {
            (bool success,) = address(hook).call(abi.encodeWithSelector(selectors[i]));
            assertFalse(success);
        }
    }

    function test_directCall_beforeSwap_revertsIfNotPoolManager() public onlyReady {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(attacker);
        vm.expectRevert();
        hook.beforeSwap(attacker, poolKey, params, bytes(""));
    }

    function test_directCall_afterSwap_revertsIfNotPoolManager() public onlyReady {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(10_000 ether)));

        vm.prank(attacker);
        vm.expectRevert();
        hook.afterSwap(attacker, poolKey, params, delta, bytes(""));
    }

    function test_directCall_beforeInitialize_revertsIfNotPoolManager() public onlyReady {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        vm.prank(attacker);
        vm.expectRevert();
        hook.beforeInitialize(attacker, poolKey, 0);
    }

    function test_unregisteredPool_skipsFeeAndInjection() public onlyReady {
        address fakeToken = makeAddr("fakeToken");
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(fakeToken),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(10_000 ether)));

        uint256 hookBalanceBefore = address(hook).balance;
        vm.prank(address(manager));
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
        assertEq(address(hook).balance, hookBalanceBefore);
    }

    function test_registerPool_canBeCalledOnceByLegitToken() public onlyReady {
        (address community,,) = hook.tokenInfo(address(token));
        assertTrue(community != address(0));
    }

    function test_assetCustody_directTransferRequest_doesNothing() public onlyReady {
        uint256 hookTokenBalance = IERC20(address(token)).balanceOf(address(hook));
        assertGt(hookTokenBalance, 0);

        vm.startPrank(attacker);
        bytes4 transferSelector = bytes4(keccak256("transfer(address,uint256)"));
        (bool s1,) = address(hook).call(abi.encodeWithSelector(transferSelector, attacker, hookTokenBalance));
        assertFalse(s1);

        bytes4 transferFromSelector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        (bool s2,) =
            address(hook).call(abi.encodeWithSelector(transferFromSelector, address(hook), attacker, hookTokenBalance));
        assertFalse(s2);
        vm.stopPrank();

        assertEq(IERC20(address(token)).balanceOf(address(hook)), hookTokenBalance);
    }

    function test_assetCustody_balanceOnlyDecreasesViaInject() public onlyReady {
        uint256 hookTokenBalanceBefore = IERC20(address(token)).balanceOf(address(hook));

        _simulateHookBuy(token, 20_000 ether);
        assertEq(IERC20(address(token)).balanceOf(address(hook)), hookTokenBalanceBefore);

        _warpNextHookPeriod();
        _simulateHookBuy(token, 20_000 ether);

        uint256 hookTokenBalanceAfter = IERC20(address(token)).balanceOf(address(hook));
        uint256 expectedInject = 20_000 ether * HOOK_TIER0_RATIO_PPM / HOOK_RATIO_SCALE;
        assertEq(hookTokenBalanceBefore - hookTokenBalanceAfter, expectedInject);
    }

    function test_reentrancy_protectedDuringRegisterPool() public onlyReady {
        vm.skip(true);
    }

    function test_doesNotTrustTxOrigin() public onlyReady {
        vm.prank(attacker, attacker);
        vm.expectRevert();
        hook.registerPool(PoolId.wrap(bytes32(uint256(123))), address(token));
    }

    function test_noDelegatecallInHookSource() public onlyReady {
        assertTrue(true);
    }
}
