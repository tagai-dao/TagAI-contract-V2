// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Shared BSC mainnet fork setup + swap helpers for fork integration tests.
abstract contract BSCForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address internal constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address internal constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address internal constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    uint16 internal constant TARGET_HOOK_BITMAP = 0x0CC1;

    uint256 internal constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 internal constant BONDING_CURVE_TOTAL = 650_000_000 ether;
    uint256 internal constant MIN_INJECT_AMOUNT = 8400 ether;
    uint256 internal constant LISTING_ETH_AMOUNT = 19 ether;
    uint256 internal constant EXTERNAL_SELLABLE = BONDING_CURVE_TOTAL + NUTBOX_ALLOCATION;

    int24 internal constant LISTING_TICK_LOWER = -887220;
    int24 internal constant LISTING_TICK_UPPER = 191940;
    uint256 internal constant MAX_LISTING_DUST = 1 ether;

    HourlyTickCalculator internal calculator;
    Pump internal pump;
    TagAISwapHook internal hook;
    CLPoolManagerRouter internal router;

    address internal creator;
    address internal buyer;
    address internal buyer2;

    bool internal forkReady;

    function setUp() public virtual {
        if (block.chainid != 56) {
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length == 0) {
                forkReady = false;
                return;
            }
            vm.createSelectFork(rpc);
        }

        if (block.chainid != 56) {
            forkReady = false;
            return;
        }

        forkReady = true;
        creator = makeAddr("forkCreator");
        buyer = makeAddr("forkBuyer");
        buyer2 = makeAddr("forkBuyer2");

        _deployProductionStack();
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function _deployProductionStack() internal {
        calculator = new HourlyTickCalculator(COMMUNITY_FACTORY);

        pump = new Pump(IPSHARE, FEE_RECEIVER);
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);

        hook = _deployHookWithValidBitmap();

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(COMMUNITY_FACTORY, address(calculator), SOCIAL_CURATION_FACTORY, COMMITTEE);

        router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));

        _whitelistCalculator();
    }

    function _deployHookWithValidBitmap() internal returns (TagAISwapHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode,
            abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        address deployer = address(this);
        (bytes32 salt, address predicted,) = _mineHookSalt(deployer, bytecodeHash);

        deployed = new TagAISwapHook{salt: salt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            address(pump)
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

    function _whitelistCalculator() internal {
        address committeeOwner = Ownable(COMMITTEE).owner();
        vm.prank(committeeOwner);
        ICommittee(COMMITTEE).adminAddContract(address(calculator));
    }

    function _createAndListToken(string memory tick) internal returns (Token token) {
        _ensureCreatorIPShare();

        uint256 nutboxFees = ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee();
        uint256 ipshareFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 totalFee = pump.createFee() + nutboxFees + ipshareFee + 1 ether;

        vm.deal(creator, totalFee + 8000 ether);

        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: totalFee}(tick, keccak256(abi.encodePacked(tick, block.timestamp)));
        token = Token(payable(tokenAddr));

        _fillBondingCurve(token, buyer);
        assertTrue(token.listed(), "listing failed on real PCS V4");
    }

    /// @dev 无预挖 + 单账号买满曲线 + Hook 150M 归集，确定性 800M。
    function _createAndListForWhale(string memory tick, address whale) internal returns (Token token) {
        _ensureCreatorIPShare();

        uint256 nutboxFees = ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee();
        uint256 ipshareFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 totalFixedFee = pump.createFee() + nutboxFees + ipshareFee;

        vm.deal(creator, totalFixedFee);
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: totalFixedFee}(
            tick, keccak256(abi.encodePacked("whale", tick, block.timestamp))
        );
        token = Token(payable(tokenAddr));

        _fillBondingCurveFull(token, whale);
        assertTrue(token.listed(), "listing failed on real PCS V4");
        assertEq(token.bondingCurveSupply(), BONDING_CURVE_TOTAL, "curve fully sold");
        assertEq(IERC20(tokenAddr).balanceOf(whale), BONDING_CURVE_TOTAL, "whale holds 650M");

        vm.prank(address(hook));
        IERC20(tokenAddr).transfer(whale, NUTBOX_ALLOCATION);

        assertEq(IERC20(tokenAddr).balanceOf(whale), EXTERNAL_SELLABLE, "whale holds exactly 800M");
        assertEq(IERC20(tokenAddr).balanceOf(address(hook)), 0, "hook emptied");
        assertLe(IERC20(tokenAddr).balanceOf(tokenAddr), MAX_LISTING_DUST, "listing dust <= 1 token");
    }

    function _ensureCreatorIPShare() internal {
        if (IIPShare(IPSHARE).ipshareCreated(creator)) return;

        uint256 fee = IIPShare(IPSHARE).createFee();
        vm.deal(creator, fee);
        vm.prank(creator, creator);
        IIPShare(IPSHARE).createShare{value: fee}(creator);
    }

    function _fillBondingCurve(Token token, address actor) internal {
        vm.startPrank(actor, actor);
        vm.warp(block.timestamp + 16);

        for (uint256 i = 0; i < 250 && !token.listed(); i++) {
            if (token.bondingCurveSupply() >= BONDING_CURVE_TOTAL) break;

            uint256 buyEth = 10 ether;
            if (actor.balance < buyEth) vm.deal(actor, buyEth + 100 ether);

            try token.buyToken{value: buyEth}(0, creator, 500) {} catch {
                try token.buyToken{value: 100 ether}(0, creator, 1000) {} catch {
                    try token.buyToken{value: 500 ether}(0, creator, 2000) {} catch {
                        break;
                    }
                }
            }
        }
        vm.stopPrank();
    }

    function _fillBondingCurveFull(Token token, address trader) internal {
        vm.startPrank(trader, trader);
        vm.warp(block.timestamp + 16);
        vm.deal(trader, 50_000 ether);

        for (uint256 i = 0; i < 1000 && !token.listed(); i++) {
            if (token.bondingCurveSupply() >= BONDING_CURVE_TOTAL) break;

            uint256 ethIn = 20 ether;
            if (i % 7 == 0) ethIn = 500 ether;
            else if (i % 3 == 0) ethIn = 100 ether;

            if (trader.balance < ethIn + 1 ether) vm.deal(trader, ethIn + 5000 ether);

            try token.buyToken{value: ethIn}(0, creator, 8000) {} catch {
                try token.buyToken{value: ethIn * 2}(0, creator, 9000) {} catch {
                    try token.buyToken{value: ethIn / 2}(0, creator, 9000) {} catch {
                        break;
                    }
                }
            }
        }
        vm.stopPrank();
    }

    function _swapBuyExactIn(PoolKey memory poolKey, address actor, uint256 ethIn)
        internal
        returns (uint256 tokensReceived)
    {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 tokenBefore = IERC20(tokenAddr).balanceOf(actor);

        vm.deal(actor, actor.balance + ethIn);
        vm.prank(actor);
        router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        tokensReceived = IERC20(tokenAddr).balanceOf(actor) - tokenBefore;
    }

    function _swapSellExactIn(PoolKey memory poolKey, address actor, uint256 tokenIn)
        internal
        returns (uint256 bnbReceived)
    {
        bnbReceived = _swapSellExactIn(poolKey, actor, tokenIn, TickMath.getSqrtRatioAtTick(LISTING_TICK_UPPER));
    }

    function _swapSellExactIn(PoolKey memory poolKey, address actor, uint256 tokenIn, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 bnbReceived)
    {
        uint256 balBefore = actor.balance;

        vm.prank(actor);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(router), tokenIn);

        vm.prank(actor);
        router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        bnbReceived = actor.balance - balBefore;
    }

    function _swapSellAll(PoolKey memory poolKey, address actor)
        internal
        returns (uint256 totalBnb, uint256 totalSold, uint256 rounds)
    {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 chunk = 50_000_000 ether;
        uint256 remaining = IERC20(tokenAddr).balanceOf(actor);
        uint160 priceLimit = TickMath.getSqrtRatioAtTick(LISTING_TICK_UPPER);

        while (remaining > MAX_LISTING_DUST && rounds < 200) {
            uint256 sellAmt = remaining > chunk ? chunk : remaining;
            uint256 tokenBefore = IERC20(tokenAddr).balanceOf(actor);
            uint256 received;
            try this._swapSellExactInExternal(poolKey, actor, sellAmt, priceLimit) returns (uint256 r) {
                received = r;
            } catch {
                if (sellAmt <= 1 ether) break;
                chunk = sellAmt / 2;
                continue;
            }
            uint256 tokenAfter = IERC20(tokenAddr).balanceOf(actor);
            uint256 actuallySold = tokenBefore - tokenAfter;
            if (actuallySold == 0) {
                if (sellAmt <= 1 ether) break;
                chunk = sellAmt / 2;
                continue;
            }
            totalBnb += received;
            totalSold += actuallySold;
            remaining = tokenAfter;
            rounds++;
        }
    }

    function _swapSellExactInExternal(PoolKey memory poolKey, address actor, uint256 tokenIn, uint160 sqrtPriceLimitX96)
        external
        returns (uint256)
    {
        require(msg.sender == address(this));
        return _swapSellExactIn(poolKey, actor, tokenIn, sqrtPriceLimitX96);
    }

    function _estimatePoolReserves(PoolKey memory poolKey)
        internal
        view
        returns (uint256 bnbInPool, uint256 tokenInPool)
    {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPrice,,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        uint128 liquidity = ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId);
        if (liquidity == 0) return (0, 0);

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(LISTING_TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(LISTING_TICK_UPPER);

        if (sqrtPrice <= sqrtLower) {
            bnbInPool = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPrice >= sqrtUpper) {
            tokenInPool = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else {
            bnbInPool = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtUpper, liquidity, false);
            tokenInPool = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidity, false);
        }
    }

    function _logPoolReserves(PoolKey memory poolKey, string memory label) internal view {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        (uint256 bnbAmt, uint256 tokenAmt) = _estimatePoolReserves(poolKey);
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPrice, int24 tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        uint128 liquidity = ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolId);

        // 该 token 仅在本 pool 使用，vault 余额即池内真实 token 存量
        uint256 vaultTokenBal = IERC20(tokenAddr).balanceOf(VAULT);
        uint256 contractDust = IERC20(tokenAddr).balanceOf(tokenAddr);

        console2.log("=== Pool balances:", label, "===");
        console2.log("  tick:", tick);
        console2.log("  liquidity:", liquidity);
        console2.log("  sqrtPriceX96:", sqrtPrice);
        console2.log("  vault token (actual, wei):", vaultTokenBal);
        console2.log("  vault token (actual, tokens):", vaultTokenBal / 1e18);
        console2.log("  token contract dust:", contractDust);
        console2.log("  active LP BNB est (wei):", bnbAmt);
        console2.log("  active LP BNB est (ether):", bnbAmt / 1e18);
        console2.log("  active LP token est (tokens):", tokenAmt / 1e18);
    }

    function _buildPoolKey(address tokenAddr) internal view returns (PoolKey memory) {
        uint16 hookBitmap = IHooks(address(hook)).getHooksRegistrationBitmap();
        bytes32 parameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), int24(60));

        return PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(tokenAddr),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: 0,
            parameters: parameters
        });
    }
}
