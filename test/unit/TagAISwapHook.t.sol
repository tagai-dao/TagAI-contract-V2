// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/pump/IPShare.sol";
import "../../src/pump/Pump.sol";
import "../../src/pump/Token.sol";
import "../../src/hook/TagAISwapHook.sol";
import "../mocks/MockCLPoolManager.sol";
import "../mocks/MockVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TagAISwapHookTest
 * @notice Unit tests for TagAISwapHook — registerPool, injection logic, fee distribution.
 */
contract TagAISwapHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    Pump public pump;
    TagAISwapHook public hook;
    Token public token; // listed token

    address public creator;
    address public buyer;
    address public feeRecipient;
    address public claimSigner;

    uint256 constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 constant RATIO_SCALE = 1e9;
    uint256 constant MIN_INJECT_OUTPUT = 168 ether / 10; // 16.8 tokens
    uint256 constant MAX_PERIOD_BUY_VOLUME = 420_000_000 ether;
    uint256 constant PERIOD_LENGTH = 600;
    uint256 constant TIER0_RATIO_PPM = 106_069_772; // 10-min volume < 26.7k (T0)
    uint256 constant TIER1_RATIO_PPM = 53_034_886; // 10-min volume < 93.2k (T1)
    uint256 constant DIVISOR = 10000;
    uint256 constant IPSHARE_FEE_BPS = 30;
    uint256 constant DIRECTIONAL_FEE_BPS = 30;

    function setUp() public {
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        vm.deal(creator, 1000 ether);
        vm.deal(buyer, 1000 ether);
        vm.deal(address(this), 1000 ether);

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = _deployCommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(communityFactory);
        scf = _deploySocialCurationFactory(communityFactory, claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);

        mockPoolManager = new MockCLPoolManager();
        mockVault = new MockVault();

        ipshare = new IPShare(feeRecipient);
        pump = new Pump(address(ipshare), feeRecipient);
        pump.adminSetPoolManager(address(mockPoolManager));
        pump.adminSetVault(address(mockVault));

        hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));

        // Fund mock vault for fee collection
        vm.deal(address(mockVault), 100 ether);

        vm.warp(3600);

        // Create and list a token
        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("HOOK", bytes32(uint256(1)));
        token = Token(payable(tokenAddr));
        vm.stopPrank();

        // Fill bonding curve to trigger listing
        _fillBondingCurve();
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "CF deploy failed");
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "SCF deploy failed");
        return d;
    }

    function _fillBondingCurve() internal {
        uint256 BONDING_CAP = 650_000_000 ether;
        vm.startPrank(buyer, buyer);
        vm.warp(block.timestamp + 16);
        for (uint256 i = 0; i < 100 && !token.listed(); i++) {
            uint256 remaining = BONDING_CAP - token.bondingCurveSupply();
            if (remaining == 0) break;
            uint256 buyAmount = 5 ether;
            if (buyer.balance < buyAmount) {
                vm.deal(buyer, 1000 ether);
            }
            try token.buyToken{value: buyAmount}(0, creator, 0) {} catch {
                vm.deal(buyer, 5000 ether);
                try token.buyToken{value: 500 ether}(0, creator, 0) {} catch {
                    break;
                }
            }
        }
        vm.stopPrank();
    }

    function _buildPoolKey() internal view returns (PoolKey memory) {
        uint16 hookBitmap = IHooks(address(hook)).getHooksRegistrationBitmap();
        bytes32 parameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), int24(60));
        return PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(token)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(mockPoolManager)),
            fee: 3000,
            parameters: parameters
        });
    }

    // ─── registerPool ───

    function test_registerPool_revertsIfNotTokenCaller() public {
        // Direct call from rando, even if it knows a registered token, should fail
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        hook.registerPool(PoolId.wrap(bytes32(uint256(99))), address(token));
    }

    function test_registerPool_revertsIfTokenNotCreatedByPump() public {
        // A random address claims to be a token but Pump doesn't know it
        address fakeToken = makeAddr("fakeToken");
        vm.prank(fakeToken);
        vm.expectRevert();
        hook.registerPool(PoolId.wrap(bytes32(uint256(99))), fakeToken);
    }

    function test_registerPool_succeededDuringListing() public {
        // The token was listed in setUp(), so registerPool was called
        (address community, address calc) = hook.tokenInfo(address(token));
        assertEq(community, token.nutboxCommunity(), "Community should match");
        assertEq(calc, address(calculator), "Calculator should match");
        assertEq(IERC20(address(token)).balanceOf(address(hook)), NUTBOX_ALLOCATION, "Hook holds listing allocation");
    }

    function _warpNextPeriod() internal {
        vm.warp(block.timestamp + PERIOD_LENGTH);
    }

    function _hookBal() internal view returns (uint256) {
        return IERC20(address(token)).balanceOf(address(hook));
    }

    function _expectedSettleInject(uint256 periodVolume) internal view returns (uint256) {
        (,, uint256 injectAmount) = hook.previewPeriodSettle(periodVolume);
        return injectAmount;
    }

    function _ratioForLookup(uint256 lookupVolume) internal pure returns (uint256) {
        if (lookupVolume < 26_700 ether) return TIER0_RATIO_PPM;
        if (lookupVolume < 93_200 ether) return TIER1_RATIO_PPM;
        return 31_517_443;
    }

    // ─── Injection logic via afterSwap ───

    function test_injection_samePeriod_noInjectUntilNextPeriodFirstBuy() public {
        uint256 initialBal = _hookBal();

        _simulateBuy(20_000 ether);
        _simulateBuy(30_000 ether);

        // Same period: no inject, but buy directional token fees accrue on Hook
        uint256 feesAccrued = _directionalTokenFee(20_000 ether) + _directionalTokenFee(30_000 ether);
        assertEq(_hookBal(), initialBal + feesAccrued, "same period: fees only, no inject");

        (uint32 periodIndex, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 50_000 ether);
        assertEq(periodIndex, uint32(block.timestamp / PERIOD_LENGTH));

        _warpNextPeriod();
        uint256 balBeforeSettle = _hookBal();
        _simulateBuy(1 ether);

        uint256 expected = _expectedSettleInject(50_000 ether);
        uint256 triggerFee = _directionalTokenFee(1 ether);
        assertEq(balBeforeSettle + triggerFee - _hookBal(), expected);
    }

    function test_injection_settleUsesDirectPeriodVolumeForTier() public {
        // 50K in period → T1 (< 93.2K) → ratio 5.3035%
        _simulateBuy(50_000 ether);

        uint256 balBefore = _hookBal();
        _warpNextPeriod();
        _simulateBuy(10_000 ether);

        uint256 expected = 50_000 ether * TIER1_RATIO_PPM / RATIO_SCALE;
        uint256 triggerFee = _directionalTokenFee(10_000 ether);
        assertEq(balBefore + triggerFee - _hookBal(), expected);
    }

    function test_injection_settleSkipsWhenTotalInjectBelowMinimum() public {
        uint256 initialBal = _hookBal();

        // 50 tokens × ~10.6% ≈ 5.3 < 16.8 minimum
        _simulateBuy(50 ether);
        _warpNextPeriod();
        _simulateBuy(1 ether);

        uint256 feesAccrued = _directionalTokenFee(50 ether) + _directionalTokenFee(1 ether);
        assertEq(_hookBal(), initialBal + feesAccrued, "below-min period settlement skipped; fees remain");
    }

    function test_injection_doesNotTriggerOnSell() public {
        uint256 initialBal = _hookBal();

        PoolKey memory poolKey = _buildPoolKey();
        // zeroForOne=false means Token→ETH (sell)
        ICLPoolManager.SwapParams memory sellParams = ICLPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(10_000 ether),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, int128(int256(10_000 ether)));

        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, sellParams, delta, bytes(""));

        assertEq(_hookBal(), initialBal, "Sell should not inject");
    }

    function test_injection_periodBuyVolumeCapAt420M() public {
        uint256 balStart = _hookBal();

        _simulateBuy(419_000_000 ether);
        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 419_000_000 ether);

        uint256 fee1 = _directionalTokenFee(419_000_000 ether);
        assertEq(_hookBal(), balStart + fee1, "same period cap accumulation does not inject");

        _simulateBuy(2_000_000 ether);
        (, periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, MAX_PERIOD_BUY_VOLUME);

        uint256 fee2 = _directionalTokenFee(2_000_000 ether);
        _warpNextPeriod();
        uint256 balBeforeSettle = _hookBal();
        _simulateBuy(1 ether);

        uint256 expected = _expectedSettleInject(MAX_PERIOD_BUY_VOLUME);
        uint256 triggerFee = _directionalTokenFee(1 ether);
        assertEq(balBeforeSettle + triggerFee - _hookBal(), expected);
        // sanity: fees from capped period remain on hook until settle
        assertEq(balBeforeSettle, balStart + fee1 + fee2);
    }

    function test_injection_hugeBuyLimitedByPeriodCap() public {
        uint256 balBefore = _hookBal();
        uint256 hugeBuy = 200_000_000_000 ether;

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(hugeBuy)));

        _fundVaultForBuyFee(hugeBuy);
        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));

        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, MAX_PERIOD_BUY_VOLUME);

        uint256 feeHuge = _directionalTokenFee(hugeBuy);
        assertEq(_hookBal(), balBefore + feeHuge, "cap period does not inject until settle");

        _warpNextPeriod();
        uint256 balBeforeSettle = _hookBal();
        _simulateBuy(1 ether);

        uint256 expectedInject = _expectedSettleInject(MAX_PERIOD_BUY_VOLUME);
        uint256 triggerFee = _directionalTokenFee(1 ether);
        assertEq(balBeforeSettle + triggerFee - _hookBal(), expectedInject);
        assertGt(_hookBal(), 0, "period cap prevents single settle from draining full inventory");
    }

    /// @dev External top-ups increase Hook balance and continue to fund period settlements.
    function test_injection_externalTopUp_continuesDistribution() public {
        // Drain some inventory via a large qualifying period settle.
        _simulateBuy(MAX_PERIOD_BUY_VOLUME);
        _warpNextPeriod();
        _simulateBuy(1 ether);

        uint256 balAfterFirst = _hookBal();
        // Inventory shrinks vs listing allocation + fees from the two buys, after settle.
        assertTrue(balAfterFirst < NUTBOX_ALLOCATION + _directionalTokenFee(MAX_PERIOD_BUY_VOLUME), "first settle consumed inventory");

        // Clear the leftover 1-ether accumulator from the settle-trigger buy (below MIN → no inject).
        _warpNextPeriod();
        _simulateBuy(1 ether);
        _warpNextPeriod();

        // Top up from an external source (simulate continued funding).
        uint256 topUp = 1_000_000 ether;
        deal(address(token), address(hook), _hookBal() + topUp);

        _simulateBuy(50_000 ether);
        _warpNextPeriod();
        uint256 balBeforeSecond = _hookBal();
        _simulateBuy(1 ether);

        uint256 expected = _expectedSettleInject(50_000 ether);
        uint256 triggerFee = _directionalTokenFee(1 ether);
        assertEq(balBeforeSecond + triggerFee - _hookBal(), expected, "top-up balance is distributable");
    }

    /// @dev Balance below MIN_INJECT_OUTPUT is not injected even when period settle would otherwise qualify.
    function test_injection_skipsWhenBalanceBelowMinimum() public {
        // Accumulate volume, then leave only dust on Hook before settle trigger.
        _simulateBuy(50_000 ether);
        deal(address(token), address(hook), 10 ether);
        assertEq(_hookBal(), 10 ether);

        _warpNextPeriod();
        // Trigger buy adds tiny directional fee; settle inject capped to dust+fee still < MIN → skip
        uint256 balBefore = _hookBal();
        _simulateBuy(1 ether);
        assertEq(_hookBal(), balBefore + _directionalTokenFee(1 ether), "dust below MIN must stay on Hook");
    }

    function test_previewPeriodSettle_matchesSettlement() public view {
        (uint256 lookup, uint32 ratio, uint256 injectAmount) = hook.previewPeriodSettle(50_000 ether);
        assertEq(lookup, 50_000 ether);
        assertEq(ratio, uint32(TIER1_RATIO_PPM));
        assertEq(injectAmount, 50_000 ether * TIER1_RATIO_PPM / RATIO_SCALE);
    }

    function _directionalTokenFee(uint256 boughtAmount) internal pure returns (uint256) {
        return (boughtAmount * DIRECTIONAL_FEE_BPS) / DIVISOR;
    }

    function _fundVaultForBuyFee(uint256 boughtAmount) internal {
        uint256 fee = _directionalTokenFee(boughtAmount);
        if (fee == 0) return;
        deal(address(token), address(mockVault), IERC20(address(token)).balanceOf(address(mockVault)) + fee);
    }

    function _simulateBuy(uint256 boughtAmount) internal {
        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(boughtAmount)));
        _fundVaultForBuyFee(boughtAmount);
        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));
    }

    // ─── Post-list hardcoded fees ───

    function test_buy_takesDirectionalTokenFeeIntoHook() public {
        uint256 bought = 100_000 ether;
        uint256 expectedFee = _directionalTokenFee(bought);
        uint256 hookBefore = _hookBal();

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether, // exact-in ETH → ethSpecified; fee collected in afterSwap
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(bought)));

        _fundVaultForBuyFee(bought);
        vm.prank(address(mockPoolManager));
        (, int128 afterDelta) = hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));

        assertEq(uint256(uint128(afterDelta)), expectedFee, "afterSwap must return token fee delta");
        assertEq(_hookBal(), hookBefore + expectedFee, "directional token fee stays on Hook");
    }

    function test_buy_bnbSideOnlyChargesIpshare_noPlatformFromFeeRatio() public {
        uint256 ethIn = 10 ether;
        uint256 expectedIpshare = (ethIn * IPSHARE_FEE_BPS) / DIVISOR;

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethIn),
            sqrtPriceLimitX96: 0
        });

        // feeRecipient is also IPShare treasury in this suite — assert via event, not balance.
        vm.expectEmit(true, true, false, true, address(hook));
        emit TagAISwapHook.SwapFeeCollected(poolKey.toId(), address(token), 0, expectedIpshare);

        vm.prank(address(mockPoolManager));
        (, BeforeSwapDelta bsd,) = hook.beforeSwap(address(0), poolKey, buyParams, bytes(""));

        int128 specifiedFee = BeforeSwapDeltaLibrary.getSpecifiedDelta(bsd);
        assertEq(uint256(uint128(specifiedFee)), expectedIpshare, "buy BNB leg = IPShare 30 BPS only");
    }

    function test_sell_splitsPlatformAndIpshareOnSameGrossBnb() public {
        uint256 bnbOut = 10 ether;
        uint256 expectedIpshare = (bnbOut * IPSHARE_FEE_BPS) / DIVISOR;
        uint256 expectedPlatform = (bnbOut * DIRECTIONAL_FEE_BPS) / DIVISOR;
        uint256 expectedTotal = expectedIpshare + expectedPlatform; // 60 BPS, same base

        PoolKey memory poolKey = _buildPoolKey();
        // Exact-in sell: token specified, ETH unspecified -> afterSwap collects BNB fees
        ICLPoolManager.SwapParams memory sellParams = ICLPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(100_000 ether),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(int128(int256(bnbOut)), int128(int256(100_000 ether)));

        vm.expectEmit(true, true, false, true, address(hook));
        emit TagAISwapHook.SwapFeeCollected(poolKey.toId(), address(token), expectedPlatform, expectedIpshare);

        vm.prank(address(mockPoolManager));
        (, int128 afterDelta) = hook.afterSwap(address(0), poolKey, sellParams, delta, bytes(""));

        assertEq(uint256(uint128(afterDelta)), expectedTotal, "sell afterSwap delta = 60 BPS");
    }

    function test_hook_doesNotUsePumpFeeRatio() public {
        // Change pump feeRatio; Hook must ignore it and keep hardcoded 30/30.
        uint256[2] memory newRatio = [uint256(100), uint256(100)];
        pump.adminChangeFeeRatio(newRatio);

        uint256 ethIn = 5 ether;
        uint256 expectedIpshare = (ethIn * IPSHARE_FEE_BPS) / DIVISOR; // still 30, not 100

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethIn),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPoolManager));
        (, BeforeSwapDelta bsd,) = hook.beforeSwap(address(0), poolKey, buyParams, bytes(""));
        int128 specifiedFee = BeforeSwapDeltaLibrary.getSpecifiedDelta(bsd);
        assertEq(uint256(uint128(specifiedFee)), expectedIpshare, "Hook ignores pump feeRatio");
    }

    // ─── getHooksRegistrationBitmap ───

    function test_getHooksRegistrationBitmap_correctBits() public {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        // beforeInitialize=0, beforeSwap=6, afterSwap=7, beforeSwapReturnsDelta=10, afterSwapReturnsDelta=11
        uint16 expected = uint16((1 << 0) | (1 << 6) | (1 << 7) | (1 << 10) | (1 << 11));
        assertEq(bitmap, expected);
    }
}
