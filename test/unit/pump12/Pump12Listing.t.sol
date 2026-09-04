// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {Token12} from "../../../src/pump12/Token12.sol";
import {NetNetHook} from "../../../src/pump12/NetNetHook.sol";
import {PermanentLiquidityVault} from "../../../src/pump12/PermanentLiquidityVault.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract ListingTestUsdG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Pump12ListingTest is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    address internal indexToken = makeAddr("indexToken");
    address internal pTeamHolder = makeAddr("pTeamHolder");

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    Pump12 internal pump;
    NetNetHook internal hook;
    Token12 internal token;

    function setUp() public {
        vm.chainId(RH_CHAIN_ID);

        ListingTestUsdG usdgImplementation = new ListingTestUsdG();
        vm.etch(USDG, address(usdgImplementation).code);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), POOL_MANAGER);
        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);

        vm.prank(tagAI);
        pump = new Pump12(USDG, POOL_MANAGER);
        hook = _deployHook();
        vm.prank(tagAI);
        pump.setHook(address(hook));

        vm.prank(creator);
        token = Token12(pump.createToken(_params()));

        ListingTestUsdG(USDG).mint(buyer, 30_000e6);
        vm.prank(buyer);
        ListingTestUsdG(USDG).approve(address(token), type(uint256).max);
    }

    function test_listRevertsBeforeCurveIsFull() public {
        vm.expectRevert(Pump12.CurveNotComplete.selector);
        pump.list(address(token));
    }

    function test_listLocksBasePOLAndPreservesFeeLiabilities() public {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);

        uint256 feeLiabilities = token.claimableTagAI() + token.claimableCreator();
        (PoolId poolId, address vaultAddress) = pump.list(address(token));
        PermanentLiquidityVault vault = PermanentLiquidityVault(vaultAddress);

        assertTrue(token.listed());
        assertEq(token.curveReserveRaw(), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(token)), feeLiabilities);
        assertEq(token.liquidityVault(), vaultAddress);
        assertEq(token.v4PoolId(), PoolId.unwrap(poolId));
        assertEq(token.initialAnchor(), token.curveEndPrice());
        assertEq(token.listTime(), block.timestamp);

        assertTrue(vault.initialized());
        assertGt(vault.lockedLiquidity(), 0);
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(poolId));
        assertApproxEqAbs(vault.polTokenInventory(), vault.tokenUsed(), 1);

        (uint128 positionLiquidity,,) =
            manager.getPositionInfo(poolId, vaultAddress, vault.TICK_LOWER(), vault.TICK_UPPER(), vault.BASE_LP_SALT());
        assertEq(positionLiquidity, vault.lockedLiquidity());
        assertEq(hook.poolToken(poolId), address(token));
    }

    function test_baseVaultHasNoLiquidityRemovalOrTokenRecoverySurface() public {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);
        (, address vaultAddress) = pump.list(address(token));

        (bool removeOk,) = vaultAddress.call(abi.encodeWithSignature("decreaseLiquidity(uint128)", uint128(1)));
        (bool collectOk,) = vaultAddress.call(abi.encodeWithSignature("collect(address)", address(this)));
        (bool recoverOk,) =
            vaultAddress.call(abi.encodeWithSignature("recoverToken(address,address)", USDG, address(this)));

        assertFalse(removeOk);
        assertFalse(collectOk);
        assertFalse(recoverOk);
    }

    function test_hookCollectsUsdGOnBuyAndSellAndPreservesThreeWayAccounting() public {
        (PoolId poolId, address vaultAddress) = _fillAndList();
        PoolKey memory key = _poolKey();
        PermanentLiquidityVault vault = PermanentLiquidityVault(vaultAddress);
        uint256 polTokensBefore = vault.polTokenInventory();

        ListingTestUsdG(USDG).mint(trader, 1_000e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);

        uint256 grossBuyInput = 100e6;
        uint256 tokenBefore = token.balanceOf(trader);
        vm.prank(trader);
        _swap(key, _usdgIsCurrency0(), -int256(grossBuyInput));

        assertGt(token.balanceOf(trader), tokenBefore);
        assertLt(vault.polTokenInventory(), polTokensBefore);
        assertEq(ListingTestUsdG(USDG).balanceOf(trader), 900e6);
        assertEq(hook.claimableTagAI(poolId), 500_000);
        assertEq(hook.claimableCreator(poolId), 1_000_000);
        assertEq(hook.pendingUSDG(poolId), 3_500_000);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 3_500_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), 5e6);

        uint256 tokenToSell = (token.balanceOf(trader) - tokenBefore) / 2;
        vm.prank(trader);
        token.approve(address(swapRouter), tokenToSell);
        uint256 usdgBeforeSell = ListingTestUsdG(USDG).balanceOf(trader);
        uint256 hookBeforeSell = ListingTestUsdG(USDG).balanceOf(address(hook));

        vm.prank(trader);
        BalanceDelta sellDelta = _swap(key, !_usdgIsCurrency0(), -int256(tokenToSell));

        uint256 netOutput = ListingTestUsdG(USDG).balanceOf(trader) - usdgBeforeSell;
        uint256 sellFee = ListingTestUsdG(USDG).balanceOf(address(hook)) - hookBeforeSell;
        uint256 grossOutput = netOutput + sellFee;
        assertEq(sellFee, grossOutput * 500 / 10_000);
        assertEq(
            hook.claimableTagAI(poolId) + hook.claimableCreator(poolId) + hook.pendingUSDG(poolId),
            ListingTestUsdG(USDG).balanceOf(address(hook))
        );
        assertTrue(BalanceDelta.unwrap(sellDelta) != 0);
    }

    function test_addPendingIsPoolScopedAndNeverEligible() public {
        (PoolId poolId,) = _fillAndList();
        ListingTestUsdG(USDG).mint(trader, 77e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 77e6);

        vm.prank(trader);
        uint256 received = hook.addPendingUSDG(poolId, 77e6);

        assertEq(received, 77e6);
        assertEq(hook.pendingUSDG(poolId), 77e6);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 0);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), 77e6);

        vm.expectRevert(NetNetHook.PoolNotRegistered.selector);
        hook.addPendingUSDG(PoolId.wrap(bytes32(uint256(123))), 1);
    }

    function test_feeClaimsDoNotConsumeBurnNetPending() public {
        (PoolId poolId,) = _fillAndList();
        PoolKey memory key = _poolKey();
        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 100e6);
        _swap(key, _usdgIsCurrency0(), -int256(100e6));
        vm.stopPrank();

        uint256 pendingBefore = hook.pendingUSDG(poolId);
        hook.claimTagAIFees(poolId);
        hook.claimCreatorFees(poolId);

        assertEq(ListingTestUsdG(USDG).balanceOf(tagAI), 500_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(creatorFeeRecipient), 1_000_000);
        assertEq(hook.pendingUSDG(poolId), pendingBefore);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), pendingBefore);
    }

    function test_officialPoolRejectsExactOutput() public {
        _fillAndList();
        PoolKey memory key = _poolKey();

        ListingTestUsdG(USDG).mint(trader, 1_000e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);

        vm.prank(trader);
        vm.expectRevert();
        _swap(key, _usdgIsCurrency0(), int256(1e18));
    }

    function test_hookSupportsReverseTokenUsdGAddressOrder() public {
        Token12 reverseToken;
        for (uint256 i = 1; i < 100; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = pump.predictTokenAddress(creator, salt);
            if (predicted < USDG) {
                vm.prank(creator);
                reverseToken = Token12(pump.createToken(_params(salt, "P12R")));
                break;
            }
        }
        assertTrue(address(reverseToken) != address(0), "reverse-order salt not found");

        vm.prank(buyer);
        ListingTestUsdG(USDG).approve(address(reverseToken), type(uint256).max);
        vm.prank(buyer);
        reverseToken.buy(20_000e6, 750_000_000e18);
        (PoolId reversePoolId,) = pump.list(address(reverseToken));

        PoolKey memory key = _poolKey(address(reverseToken));
        assertEq(Currency.unwrap(key.currency1), USDG);
        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 100e6);
        vm.prank(trader);
        _swap(key, false, -int256(100e6));

        assertGt(reverseToken.balanceOf(trader), 0);
        assertEq(hook.claimableTagAI(reversePoolId), 500_000);
        assertEq(hook.claimableCreator(reversePoolId), 1_000_000);
        assertEq(hook.pendingUSDG(reversePoolId), 3_500_000);
    }

    function _fillAndList() internal returns (PoolId poolId, address vault) {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);
        return pump.list(address(token));
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        return _poolKey(address(token));
    }

    function _poolKey(address tokenAddress) internal view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(tokenAddress);
        Currency usdgCurrency = Currency.wrap(USDG);
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    function _usdgIsCurrency0() internal view returns (bool) {
        return USDG < address(token);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _deployHook() internal returns (NetNetHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(pump), USDG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NetNetHook).creationCode, constructorArgs);
        deployed = new NetNetHook{salt: salt}(manager, address(pump), USDG);
        assertEq(address(deployed), predicted);
    }

    function _params() internal view returns (Pump12.CreateParams memory p) {
        return _params(bytes32("listing"), "P12L");
    }

    function _params(bytes32 salt, string memory symbol) internal view returns (Pump12.CreateParams memory p) {
        p = Pump12.CreateParams({
            name: "Pump12 Listing",
            symbol: symbol,
            salt: salt,
            totalFeeBps: 500,
            creatorShareBps: 2_000,
            creatorFeeRecipient: creatorFeeRecipient,
            indexToken: indexToken,
            pTeamHolder: pTeamHolder
        });
    }
}
