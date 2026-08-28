// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XSpaceStoreHook} from "../../src/hook/XSpaceStoreHook.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

/// @dev Shared BSC mainnet fork setup for XSpaceStoreHook + external token pool.
abstract contract BSCForkXSpaceStoreBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal constant XSPACE_TOKEN = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address internal constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    uint16 internal constant TARGET_HOOK_BITMAP = 0x0CC1;
    uint256 internal constant FEE_DIVISOR = 10000;
    uint256 internal constant HOOK_FEE_BPS = 60;
    uint256 internal constant PLATFORM_FEE_BPS = 30;
    uint256 internal constant IPSHARE_FEE_BPS = 30;

    uint256 internal constant BNB_USD = 600e18;

    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;

    XSpaceStoreHook internal hook;
    CLPoolManagerRouter internal router;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal lpProvider;
    address internal trader;
    address internal ipshareSubject;

    uint160 internal initialSqrtPriceX96;
    uint128 internal seededLiquidity;

    bool internal forkReady;

    function setUp() public virtual {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkReady = false;
            return;
        }

        vm.createSelectFork(rpc);
        if (block.chainid != 56) {
            forkReady = false;
            return;
        }

        forkReady = true;

        lpProvider = makeAddr("xspaceLpProvider");
        trader = makeAddr("xspaceTrader");
        ipshareSubject = makeAddr("xspaceIpshareSubject");

        hook = _deployHookWithValidBitmap();
        router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));

        poolKey = _buildPoolKey();
        poolId = poolKey.toId();

        initialSqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);
        ICLPoolManager(CL_POOL_MANAGER).initialize(poolKey, initialSqrtPriceX96);

        _ensureIPShare(ipshareSubject);
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function _deployHookWithValidBitmap() internal returns (XSpaceStoreHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(XSpaceStoreHook).creationCode,
            abi.encode(
                ICLPoolManager(CL_POOL_MANAGER),
                IVault(VAULT),
                XSPACE_TOKEN,
                FEE_RECEIVER,
                IPSHARE
            )
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        address deployer = address(this);
        (bytes32 salt, address predicted,) = _mineHookSalt(deployer, bytecodeHash);

        deployed = new XSpaceStoreHook{salt: salt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            XSPACE_TOKEN,
            FEE_RECEIVER,
            IPSHARE
        );

        assertEq(address(deployed), predicted, "CREATE2 hook address mismatch");
        assertEq(uint16(uint160(address(deployed))), TARGET_HOOK_BITMAP, "invalid hook bitmap");
    }

    function _mineHookSalt(address deployer, bytes32 bytecodeHash)
        internal
        pure
        returns (bytes32 salt, address predicted, uint256 iterations)
    {
        for (uint256 i = 0; i < 100_000_000; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
            predicted = address(uint160(uint256(hash)));
            if (uint16(uint160(predicted)) == TARGET_HOOK_BITMAP) {
                return (salt, predicted, i + 1);
            }
        }
        revert("hook salt not found");
    }

    function _buildPoolKey() internal view returns (PoolKey memory key) {
        uint16 hookBitmap = hook.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hook.TICK_SPACING());

        key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(XSPACE_TOKEN),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: hook.RECOMMENDED_LP_FEE_PIPS(),
            parameters: parameters
        });
    }

    function _ensureIPShare(address subject) internal {
        if (IIPShare(IPSHARE).ipshareCreated(subject)) return;

        uint256 fee = IIPShare(IPSHARE).createFee();
        vm.deal(subject, fee);
        vm.prank(subject, subject);
        IIPShare(IPSHARE).createShare{value: fee}(subject);
    }

    /// @dev Top up `account` to at least `amount`. Prefer `deal(adjust=false)`; fall back to whale transfer.
    function _fundToken(address account, uint256 amount) internal {
        uint256 balance = IERC20(XSPACE_TOKEN).balanceOf(account);
        if (balance >= amount) return;

        uint256 target = amount;
        deal(XSPACE_TOKEN, account, target, false);

        balance = IERC20(XSPACE_TOKEN).balanceOf(account);
        if (balance >= amount) {
            assertEq(balance, amount, "token funding failed");
            return;
        }

        uint256 deficit = amount - balance;
        address holder = _findTokenHolder(deficit);
        vm.prank(holder);
        IERC20(XSPACE_TOKEN).transfer(account, deficit);
        assertEq(IERC20(XSPACE_TOKEN).balanceOf(account), amount, "token funding failed");
    }

    function _findTokenHolder(uint256 minAmount) internal view returns (address holder) {
        address[4] memory candidates = [
            0x8894E0a0c962CB723c1976a4421c95949bE2D4E3,
            0x28C6c06298d514Db089934071355E5743bf21d60,
            0x21a31Ee1afC51d94C2eFcCAa2092aD1028285549,
            0xDFd5293D8e347dFe59E90eFd55b2956a1343963d
        ];

        for (uint256 i = 0; i < candidates.length; i++) {
            if (IERC20(XSPACE_TOKEN).balanceOf(candidates[i]) >= minAmount) {
                return candidates[i];
            }
        }
        revert("no token holder with sufficient balance");
    }

    function _seedLiquidity(uint256 amount0, uint256 amount1)
        internal
        returns (uint128 liquidity, uint256 spentEth, uint256 spentToken)
    {
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(TICK_UPPER);

        liquidity = _liquidityForAmounts(initialSqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1);
        (spentEth, spentToken) = _amountsForLiquidity(initialSqrtPriceX96, sqrtLower, sqrtUpper, liquidity);

        _fundToken(lpProvider, spentToken);
        vm.deal(lpProvider, spentEth);

        vm.startPrank(lpProvider);
        IERC20(XSPACE_TOKEN).approve(address(router), type(uint256).max);
        (BalanceDelta delta,) = router.modifyPosition{value: spentEth}(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();

        assertEq(uint256(uint128(-delta.amount0())), spentEth, "add LP eth delta");
        assertEq(uint256(uint128(-delta.amount1())), spentToken, "add LP token delta");
        assertEq(ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId), liquidity, "pool liquidity after add");

        seededLiquidity = liquidity;
    }

    function _hookFeeOnEthSpecified(uint256 ethSpecified) internal pure returns (uint256) {
        return (ethSpecified * HOOK_FEE_BPS) / FEE_DIVISOR;
    }

    function _hookFeeOnEthGrossFromNet(uint256 ethNet) internal pure returns (uint256) {
        return (ethNet * HOOK_FEE_BPS) / (FEE_DIVISOR - HOOK_FEE_BPS);
    }

    function _expectedIPShareValueCapture(uint256 ipshareFee, uint256 supplyBefore)
        internal
        view
        returns (uint256 protocolFee, uint256 subjectFee, uint256 sharesMinted)
    {
        IPShare ipshareContract = IPShare(payable(IPSHARE));
        protocolFee = (ipshareFee * ipshareContract.protocolFeePercent()) / FEE_DIVISOR;
        subjectFee = (ipshareFee * ipshareContract.subjectFeePercent()) / FEE_DIVISOR;
        uint256 curveFunds = ipshareFee - protocolFee - subjectFee;
        sharesMinted = IIPShare(IPSHARE).getBuyAmountByValue(supplyBefore, curveFunds);
    }

    function _liquidityForAmounts(
        uint160 sqrtP,
        uint160 sqrtA,
        uint160 sqrtB,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        if (sqrtP <= sqrtA) {
            liquidity = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 liquidity0 = _liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 liquidity1 = _liquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtA), uint256(sqrtB), FixedPoint96.Q96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA));
    }

    function _amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return _amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity, true);
    }

    function _amountsForLiquidity(
        uint160 sqrtP,
        uint160 sqrtA,
        uint160 sqrtB,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    // ─── USD price helpers (token priced in USD; pool is BNB/token) ─────────────

    /// @dev tokens per 1 BNB in 1e18 fixed-point.
    function _tokensPerBnbWad(uint256 tokenUsd) internal pure returns (uint256) {
        return FullMath.mulDiv(BNB_USD, 1e18, tokenUsd);
    }

    function _sqrtPriceX96FromTokenUsd(uint256 tokenUsd) internal pure returns (uint160) {
        uint256 priceWad = _tokensPerBnbWad(tokenUsd);
        uint256 ratioX192 = FullMath.mulDiv(priceWad, uint256(1) << 192, 1e18);
        return uint160(_sqrt(ratioX192));
    }

    function _tokenUsdFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // priceRatio = token/BNB with 18-decimal currencies (same scale as _tokensPerBnbWad).
        uint256 tokensPerBnbWad = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 192);
        return FullMath.mulDiv(BNB_USD, 1e18, tokensPerBnbWad);
    }

    function _alignTick(int24 tick) internal pure returns (int24) {
        int24 spacing = 10;
        int24 r = tick % spacing;
        if (r == 0) return tick;
        if (tick < 0) return tick - r;
        return tick - r;
    }

    /// @dev Higher token USD price → fewer tokens per BNB → lower tick.
    function _tickFromTokenUsd(uint256 tokenUsd) internal pure returns (int24) {
        return _alignTick(TickMath.getTickAtSqrtRatio(_sqrtPriceX96FromTokenUsd(tokenUsd)));
    }

    function _currentSqrtPrice() internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
    }

    function _currentTokenUsd() internal view returns (uint256) {
        return _tokenUsdFromSqrtPrice(_currentSqrtPrice());
    }

    function _addLiquidityAtTicks(int24 tickLower, int24 tickUpper, uint256 amount0Budget, uint256 amount1Budget)
        internal
        returns (uint128 liquidity, uint256 spentEth, uint256 spentToken)
    {
        uint160 sqrtPrice = _currentSqrtPrice();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity = _liquidityForAmounts(sqrtPrice, sqrtLower, sqrtUpper, amount0Budget, amount1Budget);
        (spentEth, spentToken) = _amountsForLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity);

        _fundToken(lpProvider, spentToken);
        vm.deal(lpProvider, spentEth);

        vm.startPrank(lpProvider);
        IERC20(XSPACE_TOKEN).approve(address(router), type(uint256).max);
        (BalanceDelta delta,) = router.modifyPosition{value: spentEth}(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();

        assertEq(uint256(uint128(-delta.amount0())), spentEth, "add LP eth delta");
        assertEq(uint256(uint128(-delta.amount1())), spentToken, "add LP token delta");
    }

    function _removeLiquidityAtTicks(int24 tickLower, int24 tickUpper, uint128 liquidityToRemove)
        internal
        returns (uint256 ethOut, uint256 tokenOut)
    {
        uint256 ethBefore = lpProvider.balance;
        uint256 tokenBefore = IERC20(XSPACE_TOKEN).balanceOf(lpProvider);

        vm.prank(lpProvider);
        (BalanceDelta delta,) = router.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        ethOut = uint256(uint128(delta.amount0()));
        tokenOut = uint256(uint128(delta.amount1()));
        assertEq(ethOut, lpProvider.balance - ethBefore, "remove eth received");
        assertEq(tokenOut, IERC20(XSPACE_TOKEN).balanceOf(lpProvider) - tokenBefore, "remove token received");
    }

    function _swapBuyExactEth(address actor, uint256 ethIn) internal returns (BalanceDelta delta) {
        vm.deal(actor, ethIn);
        vm.prank(actor);
        delta = router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
    }

    function _swapSellExactToken(address actor, uint256 tokenIn) internal returns (BalanceDelta delta) {
        vm.startPrank(actor);
        IERC20(XSPACE_TOKEN).approve(address(router), tokenIn);
        delta = router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
        vm.stopPrank();
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
