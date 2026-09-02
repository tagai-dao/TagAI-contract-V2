// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {HookMiner} from "../../src/utils/HookMiner.sol";
import {NutboxCommunityFeeHook} from "../../src/hook/NutboxCommunityFeeHook.sol";

contract CommunityFeeTokenMock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CommunityFeeCalculatorMock {
    bool public shouldRevert;
    mapping(address => uint256) public totalInjected;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function inject(address community, uint256 amount) external {
        if (shouldRevert) revert("injection failed");
        address token = CommunityFeeCommunityMock(community).getCommunityToken();
        CommunityFeeTokenMock(token).transferFrom(msg.sender, community, amount);
        totalInjected[community] += amount;
    }
}

contract CommunityFeeCommunityMock {
    address public immutable token;
    address public immutable calculator;

    constructor(address token_, address calculator_) {
        token = token_;
        calculator = calculator_;
    }

    function getCommunityToken() external view returns (address) {
        return token;
    }

    function rewardCalculator() external view returns (address) {
        return calculator;
    }
}

contract NutboxCommunityFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160((1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    NutboxCommunityFeeHook internal hook;

    CommunityFeeTokenMock internal quote;
    CommunityFeeTokenMock internal tokenA;
    CommunityFeeTokenMock internal tokenB;
    CommunityFeeCalculatorMock internal calculatorA;
    CommunityFeeCalculatorMock internal calculatorB;
    CommunityFeeCalculatorMock internal calculatorQuote;
    CommunityFeeCommunityMock internal communityA;
    CommunityFeeCommunityMock internal communityB;
    CommunityFeeCommunityMock internal communityQuote;
    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolKey internal keyQuote;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        hook = _deployHook();

        quote = new CommunityFeeTokenMock("Quote", "QUOTE");
        tokenA = new CommunityFeeTokenMock("Token A", "TKNA");
        tokenB = new CommunityFeeTokenMock("Token B", "TKNB");
        calculatorA = new CommunityFeeCalculatorMock();
        calculatorB = new CommunityFeeCalculatorMock();
        calculatorQuote = new CommunityFeeCalculatorMock();
        communityA = new CommunityFeeCommunityMock(address(tokenA), address(calculatorA));
        communityB = new CommunityFeeCommunityMock(address(tokenB), address(calculatorB));
        communityQuote = new CommunityFeeCommunityMock(address(quote), address(calculatorQuote));

        quote.mint(address(this), 1_000_000 ether);
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);
        _approve(quote);
        _approve(tokenA);
        _approve(tokenB);

        keyA = _createPool(quote, tokenA);
        keyB = _createPool(quote, tokenB);
        keyQuote = _createPoolWithFee(quote, tokenA, 500, 10);
        vm.warp(10_000);
    }

    function test_unconfiguredPoolChargesNoFee() public {
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(_pending(keyA), 0);
    }

    function test_onlyOwnerCanConfigurePool() public {
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert("Ownable: caller is not the owner");
        hook.setPoolCommunity(keyA.toId(), address(communityA));
    }

    function test_configuredPoolCachesCommunityTokenAndCalculator() public {
        hook.setPoolCommunity(keyA.toId(), address(communityA));
        (address community, address calculator, address token, uint48 attemptedAt, uint256 pending) =
            hook.poolConfig(keyA.toId());
        assertEq(community, address(communityA));
        assertEq(calculator, address(calculatorA));
        assertEq(token, address(tokenA));
        assertEq(attemptedAt, block.timestamp);
        assertEq(pending, 0);
        assertEq(tokenA.allowance(address(hook), address(calculatorA)), type(uint256).max);
    }

    function test_mismatchedCommunityTokenChargesNoFee() public {
        hook.setPoolCommunity(keyA.toId(), address(communityB));
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(tokenB.balanceOf(address(hook)), 0);
        assertEq(_pending(keyA), 0);
    }

    function test_buyExactInputChargesOnePercentOfTokenOutput() public {
        _configureA();
        BalanceDelta result = _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        uint256 fee = _pending(keyA);
        uint256 userOutput = _positiveTokenDelta(result, keyA, address(tokenA));
        uint256 grossOutput = userOutput + fee;
        assertEq(fee, grossOutput * 100 / 10_000);
        assertEq(tokenA.balanceOf(address(hook)), fee);
    }

    function test_buyExactOutputChargesOnePercentAndPreservesRequestedOutput() public {
        _configureA();
        uint256 requested = 0.5 ether;
        BalanceDelta result = _swap(keyA, _buyDirection(keyA, address(tokenA)), int256(requested));
        assertEq(_positiveTokenDelta(result, keyA, address(tokenA)), requested);
        assertEq(_pending(keyA), requested * 100 / 10_000);
    }

    function test_sellExactInputTakesOnePercentFromSpecifiedTokenInput() public {
        _configureA();
        uint256 specified = 1 ether;
        BalanceDelta result = _swap(keyA, _sellDirection(keyA, address(tokenA)), -int256(specified));
        assertEq(_negativeTokenDelta(result, keyA, address(tokenA)), specified);
        assertEq(_pending(keyA), specified * 100 / 10_000);
    }

    function test_sellExactOutputChargesOnePercentOfActualTokenInput() public {
        _configureA();
        BalanceDelta result = _swap(keyA, _sellDirection(keyA, address(tokenA)), 0.5 ether);
        uint256 fee = _pending(keyA);
        uint256 totalUserInput = _negativeTokenDelta(result, keyA, address(tokenA));
        uint256 swapInput = totalUserInput - fee;
        assertEq(fee, swapInput * 100 / 10_000);
    }

    function test_currency1CommunityTokenCoversAllFourSwapShapes() public {
        assertEq(Currency.unwrap(keyQuote.currency1), address(quote), "test requires community token as currency1");
        hook.setPoolCommunity(keyQuote.toId(), address(communityQuote));

        uint256 pendingBefore = _pending(keyQuote);
        BalanceDelta buyExactIn = _swap(keyQuote, _buyDirection(keyQuote, address(quote)), -1 ether);
        uint256 fee = _pending(keyQuote) - pendingBefore;
        uint256 userOutput = _positiveTokenDelta(buyExactIn, keyQuote, address(quote));
        assertEq(fee, (userOutput + fee) * 100 / 10_000);

        pendingBefore = _pending(keyQuote);
        uint256 requested = 0.5 ether;
        BalanceDelta buyExactOut = _swap(keyQuote, _buyDirection(keyQuote, address(quote)), int256(requested));
        assertEq(_positiveTokenDelta(buyExactOut, keyQuote, address(quote)), requested);
        assertEq(_pending(keyQuote) - pendingBefore, requested * 100 / 10_000);

        pendingBefore = _pending(keyQuote);
        uint256 specified = 1 ether;
        BalanceDelta sellExactIn = _swap(keyQuote, _sellDirection(keyQuote, address(quote)), -int256(specified));
        assertEq(_negativeTokenDelta(sellExactIn, keyQuote, address(quote)), specified);
        assertEq(_pending(keyQuote) - pendingBefore, specified * 100 / 10_000);

        pendingBefore = _pending(keyQuote);
        BalanceDelta sellExactOut = _swap(keyQuote, _sellDirection(keyQuote, address(quote)), 0.5 ether);
        fee = _pending(keyQuote) - pendingBefore;
        uint256 totalInput = _negativeTokenDelta(sellExactOut, keyQuote, address(quote));
        assertEq(fee, (totalInput - fee) * 100 / 10_000);
    }

    function test_accumulatesBothDirectionsAndInjectsOnceAfterTenMinutes() public {
        _configureA();
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        _swap(keyA, _sellDirection(keyA, address(tokenA)), -1 ether);
        uint256 beforeDue = _pending(keyA);
        assertGt(beforeDue, 0);
        assertEq(calculatorA.totalInjected(address(communityA)), 0);

        vm.warp(block.timestamp + 599);
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -0.1 ether);
        assertEq(calculatorA.totalInjected(address(communityA)), 0);

        vm.warp(block.timestamp + 1);
        _swap(keyA, _sellDirection(keyA, address(tokenA)), -0.1 ether);
        uint256 injected = calculatorA.totalInjected(address(communityA));
        assertGt(injected, beforeDue);
        assertEq(_pending(keyA), 0);
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(tokenA.balanceOf(address(communityA)), injected);
    }

    function test_failedInjectionDoesNotRevertSwapAndRetainsFees() public {
        _configureA();
        calculatorA.setShouldRevert(true);
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        vm.warp(block.timestamp + 600);

        _swap(keyA, _sellDirection(keyA, address(tokenA)), -1 ether);
        uint256 pendingAfterFailure = _pending(keyA);
        assertGt(pendingAfterFailure, 0);
        assertEq(calculatorA.totalInjected(address(communityA)), 0);
        assertEq(tokenA.balanceOf(address(hook)), pendingAfterFailure);

        calculatorA.setShouldRevert(false);
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -0.1 ether);
        assertEq(calculatorA.totalInjected(address(communityA)), 0, "failure must throttle retries");
        uint256 pendingBeforeRetry = _pending(keyA);

        (,,, uint48 failedAttemptAt,) = hook.poolConfig(keyA.toId());
        vm.warp(uint256(failedAttemptAt) + 600);
        assertTrue(hook.tryInjectPool(keyA.toId()));
        assertEq(calculatorA.totalInjected(address(communityA)), pendingBeforeRetry);
        assertEq(_pending(keyA), 0);
    }

    function test_multiplePoolsAndTokensAccountAndInjectIndependently() public {
        _configureA();
        hook.setPoolCommunity(keyB.toId(), address(communityB));
        _swap(keyA, _buyDirection(keyA, address(tokenA)), -1 ether);
        _swap(keyB, _sellDirection(keyB, address(tokenB)), -2 ether);
        uint256 pendingA = _pending(keyA);
        uint256 pendingB = _pending(keyB);
        assertGt(pendingA, 0);
        assertEq(pendingB, 0.02 ether);

        vm.warp(block.timestamp + 600);
        assertTrue(hook.tryInjectPool(keyA.toId()));
        assertTrue(hook.tryInjectPool(keyB.toId()));
        assertEq(calculatorA.totalInjected(address(communityA)), pendingA);
        assertEq(calculatorB.totalInjected(address(communityB)), pendingB);
        assertEq(tokenA.balanceOf(address(communityA)), pendingA);
        assertEq(tokenB.balanceOf(address(communityB)), pendingB);
    }

    function test_cannotReconfigureOrDisableWhileFeesPending() public {
        _configureA();
        _swap(keyA, _sellDirection(keyA, address(tokenA)), -1 ether);
        vm.expectRevert(NutboxCommunityFeeHook.PendingFeesExist.selector);
        hook.setPoolCommunity(keyA.toId(), address(0));

        vm.warp(block.timestamp + 600);
        assertTrue(hook.tryInjectPool(keyA.toId()));
        hook.setPoolCommunity(keyA.toId(), address(0));
        assertEq(tokenA.allowance(address(hook), address(calculatorA)), 0, "old calculator approval must be revoked");
        _swap(keyA, _sellDirection(keyA, address(tokenA)), -1 ether);
        assertEq(_pending(keyA), 0, "disabled pool must remain fee-free");
    }

    function test_nonPoolManagerCannotCallSwapHooks() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.expectRevert(NutboxCommunityFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), keyA, params, bytes(""));
    }

    function _configureA() internal {
        hook.setPoolCommunity(keyA.toId(), address(communityA));
    }

    function _deployHook() internal returns (NutboxCommunityFeeHook deployed) {
        bytes memory args = abi.encode(manager, address(this));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NutboxCommunityFeeHook).creationCode, args);
        deployed = new NutboxCommunityFeeHook{salt: salt}(manager, address(this));
        assertEq(address(deployed), predicted);
        assertEq(uint160(address(deployed)) & ((1 << 14) - 1), HOOK_FLAGS);
    }

    function _approve(CommunityFeeTokenMock token) internal {
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
    }

    function _createPool(CommunityFeeTokenMock a, CommunityFeeTokenMock b) internal returns (PoolKey memory poolKey) {
        return _createPoolWithFee(a, b, 3000, 60);
    }

    function _createPoolWithFee(CommunityFeeTokenMock a, CommunityFeeTokenMock b, uint24 fee, int24 tickSpacing)
        internal
        returns (PoolKey memory poolKey)
    {
        (address token0, address token1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: int256(100_000 ether), salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _buyDirection(PoolKey memory poolKey, address token) internal pure returns (bool) {
        return token == Currency.unwrap(poolKey.currency1);
    }

    function _sellDirection(PoolKey memory poolKey, address token) internal pure returns (bool) {
        return token == Currency.unwrap(poolKey.currency0);
    }

    function _pending(PoolKey memory poolKey) internal view returns (uint256 pending) {
        (,,,, pending) = hook.poolConfig(poolKey.toId());
    }

    function _positiveTokenDelta(BalanceDelta delta, PoolKey memory poolKey, address token)
        internal
        pure
        returns (uint256)
    {
        int128 amount = token == Currency.unwrap(poolKey.currency0) ? delta.amount0() : delta.amount1();
        return uint256(uint128(amount));
    }

    function _negativeTokenDelta(BalanceDelta delta, PoolKey memory poolKey, address token)
        internal
        pure
        returns (uint256)
    {
        int128 amount = token == Currency.unwrap(poolKey.currency0) ? delta.amount0() : delta.amount1();
        return uint256(uint128(-amount));
    }
}
