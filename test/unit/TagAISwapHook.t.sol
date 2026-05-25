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
    uint256 constant MAX_PERIOD_BUY_VOLUME = 210_000_000 ether;
    uint256 constant PERIOD_LENGTH = 600;
    uint256 constant TIER0_RATIO_PPM = 20_833_333; // volume < 400K hourly equivalent

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
            fee: 0,
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
        (address community, uint96 remaining, address calc) = hook.tokenInfo(address(token));
        assertEq(community, token.nutboxCommunity(), "Community should match");
        assertEq(uint256(remaining), NUTBOX_ALLOCATION, "Remaining should be NUTBOX_ALLOCATION");
        assertEq(calc, address(calculator), "Calculator should match");
    }

    function _warpNextPeriod() internal {
        vm.warp(block.timestamp + PERIOD_LENGTH);
    }

    function _expectedSettleInject(uint256 periodVolume) internal view returns (uint256) {
        (,, uint256 injectAmount) = hook.previewPeriodSettle(periodVolume);
        return injectAmount;
    }

    function _ratioForLookup(uint256 lookupVolume) internal pure returns (uint256) {
        if (lookupVolume < 400_000 ether) return TIER0_RATIO_PPM;
        if (lookupVolume < 800_000 ether) return 10_416_667;
        return 8_888_889;
    }

    // ─── Injection logic via afterSwap ───

    function test_injection_samePeriod_noInjectUntilNextPeriodFirstBuy() public {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

        _simulateBuy(20_000 ether);
        _simulateBuy(30_000 ether);

        (, uint96 remainingSamePeriod,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingSamePeriod), uint256(initialRemaining), "same period should not inject");

        (uint32 periodIndex, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 50_000 ether);
        assertEq(periodIndex, uint32(block.timestamp / PERIOD_LENGTH));

        _warpNextPeriod();
        _simulateBuy(1 ether);

        (, uint96 remainingAfterSettle,) = hook.tokenInfo(address(token));
        uint256 expected = _expectedSettleInject(50_000 ether);
        assertEq(uint256(initialRemaining) - uint256(remainingAfterSettle), expected);
    }

    function test_injection_settleUsesVolumeTimes6ForTier() public {
        // 50K in period → lookup 300K (< 400K) → highest tier ~2.083%
        _simulateBuy(50_000 ether);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _warpNextPeriod();
        _simulateBuy(10_000 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = 50_000 ether * TIER0_RATIO_PPM / RATIO_SCALE;
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expected);
    }

    function test_injection_settleSkipsWhenTotalInjectBelowMinimum() public {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

        // 800 tokens × ~2.083% ≈ 16.67 < 16.8 minimum
        _simulateBuy(800 ether);
        _warpNextPeriod();
        _simulateBuy(1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(initialRemaining), "below-min period settlement skipped");
    }

    function test_injection_doesNotTriggerOnSell() public {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

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

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(initialRemaining), "Sell should not inject");
    }

    function test_injection_periodBuyVolumeCapAt210M() public {
        (, uint96 remainingStart,) = hook.tokenInfo(address(token));

        _simulateBuy(209_000_000 ether);
        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, 209_000_000 ether);

        (, uint96 remainingMid,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingMid), uint256(remainingStart), "same period cap accumulation does not inject");

        _simulateBuy(2_000_000 ether);
        (, periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, MAX_PERIOD_BUY_VOLUME);

        _warpNextPeriod();
        _simulateBuy(1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = _expectedSettleInject(MAX_PERIOD_BUY_VOLUME);
        assertEq(uint256(remainingStart) - uint256(remainingAfter), expected);
    }

    function test_injection_hugeBuyLimitedByPeriodCap() public {
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(200_000_000_000 ether)));

        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));

        (, uint256 periodBuy) = hook.periodState(address(token));
        assertEq(periodBuy, MAX_PERIOD_BUY_VOLUME);

        (, uint96 remainingSamePeriod,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingSamePeriod), uint256(remainingBefore), "cap period does not inject until settle");

        _warpNextPeriod();
        _simulateBuy(1 ether);

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expectedInject = _expectedSettleInject(MAX_PERIOD_BUY_VOLUME);
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
        assertGt(uint256(remainingAfter), 0, "period cap prevents single swap from draining allocation");
    }

    function test_previewPeriodSettle_matchesSettlement() public view {
        (uint256 lookup, uint32 ratio, uint256 injectAmount) = hook.previewPeriodSettle(50_000 ether);
        assertEq(lookup, 300_000 ether);
        assertEq(ratio, uint32(TIER0_RATIO_PPM));
        assertEq(injectAmount, 50_000 ether * TIER0_RATIO_PPM / RATIO_SCALE);
    }

    function _simulateBuy(uint256 boughtAmount) internal {
        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(boughtAmount)));
        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));
    }

    // ─── getHooksRegistrationBitmap ───

    function test_getHooksRegistrationBitmap_correctBits() public {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        // beforeInitialize=0, beforeSwap=6, afterSwap=7, beforeSwapReturnsDelta=10, afterSwapReturnsDelta=11
        uint16 expected = uint16((1 << 0) | (1 << 6) | (1 << 7) | (1 << 10) | (1 << 11));
        assertEq(bitmap, expected);
    }
}
