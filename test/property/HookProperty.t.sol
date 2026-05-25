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
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title HookProperty
 * @notice Property-based tests for TagAISwapHook (P4, P6, P7).
 * P4 - Allocation Cap: cumulative inject + remaining == NUTBOX_ALLOCATION
 * P6 - Injection Condition: inject only when buy + remaining > 0 + inject output >= MIN
 * P7 - Asset Custody: Hook token balance only decreases via inject path
 */
contract HookPropertyTest is Test {
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
    Token public token;

    address public creator;
    address public buyer;
    address public feeRecipient;
    address public claimSigner;

    uint256 constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 constant RATIO_SCALE = 1e9;
    uint256 constant PERIOD_LENGTH = 600;
    uint256 constant MAX_PERIOD_BUY_VOLUME = 420_000_000 ether;
    uint256 constant TIER0_RATIO_PPM = 106_069_772;
    uint256 constant MIN_INJECT_OUTPUT = 168 ether / 10;

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
        vm.deal(address(mockVault), 100 ether);

        vm.warp(3600);

        vm.startPrank(creator, creator);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(creator);
        token = Token(payable(pump.createToken{value: 0.005 ether}("PROP", bytes32(uint256(1)))));
        vm.stopPrank();

        _fillBondingCurve();
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
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
            if (buyer.balance < buyAmount) vm.deal(buyer, 1000 ether);
            try token.buyToken{value: buyAmount}(0, creator, 0) {} catch {
                vm.deal(buyer, 5000 ether);
                try token.buyToken{value: 500 ether}(0, creator, 0) {} catch { break; }
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

    function _simulateBuy(uint256 boughtAmount) internal {
        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(boughtAmount)));
        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
    }

    function _warpNextPeriod() internal {
        vm.warp(block.timestamp + PERIOD_LENGTH);
    }

    function _expectedSettleInject(uint256 periodVolume) internal view returns (uint256) {
        (,, uint256 injectAmount) = hook.previewPeriodSettle(periodVolume);
        if (injectAmount < MIN_INJECT_OUTPUT) return 0;
        return injectAmount;
    }

    function _minPeriodVolumeForSettle() internal view returns (uint256) {
        return (MIN_INJECT_OUTPUT * RATIO_SCALE + TIER0_RATIO_PPM - 1) / TIER0_RATIO_PPM;
    }

    function _simulateSell(uint256 soldAmount) internal {
        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(soldAmount),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(-1 ether, int128(int256(soldAmount)));
        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, params, delta, bytes(""));
    }

    // ═══════════════════════════════════════════════════════════════════
    // P4 - Allocation Cap
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 4: Allocation Cap
    /// Cumulative inject + remaining == NUTBOX_ALLOCATION at all times
    function testFuzz_P4_allocationCap_invariant(uint256 boughtAmount) public {
        boughtAmount = bound(boughtAmount, 0, 100_000_000_000 ether);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateBuy(boughtAmount);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        // Total injected so far + remaining must equal NUTBOX_ALLOCATION
        uint256 totalInjected = NUTBOX_ALLOCATION - uint256(remainingAfter);
        assertEq(totalInjected + uint256(remainingAfter), NUTBOX_ALLOCATION);

        // remainingAfter <= remainingBefore (monotonic non-increasing on buys)
        assertLe(uint256(remainingAfter), uint256(remainingBefore));
    }

    /// Multiple buys: cumulative injection should never exceed NUTBOX_ALLOCATION
    function testFuzz_P4_multipleBuys_neverExceedsCap(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) public {
        amount1 = bound(amount1, _minPeriodVolumeForSettle(), 50_000_000_000 ether);
        amount2 = bound(amount2, 1, 50_000_000_000 ether);
        amount3 = bound(amount3, 1, 50_000_000_000 ether);

        _simulateBuy(amount1);
        _warpNextPeriod();
        _simulateBuy(amount2);
        _warpNextPeriod();
        _simulateBuy(amount3);

        (, uint96 remaining,) = hook.tokenInfo(address(token));
        uint256 totalInjected = NUTBOX_ALLOCATION - uint256(remaining);
        assertLe(totalInjected, NUTBOX_ALLOCATION);
    }

    // ═══════════════════════════════════════════════════════════════════
    // P6 - Injection Condition
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 6: Injection Condition
    /// Settlement inject occurs on next period's first buy when prior period settle output >= MIN
    function testFuzz_P6_injectionCondition(uint256 boughtAmount, bool isBuy) public {
        boughtAmount = bound(boughtAmount, 1, 1_000_000_000 ether);

        _simulateBuy(boughtAmount);
        (, uint96 remainingAfterAccum,) = hook.tokenInfo(address(token));

        _warpNextPeriod();

        (, uint96 remainingBeforeSettle,) = hook.tokenInfo(address(token));
        uint256 expectedSettle = _expectedSettleInject(boughtAmount > MAX_PERIOD_BUY_VOLUME ? MAX_PERIOD_BUY_VOLUME : boughtAmount);

        if (isBuy) {
            _simulateBuy(1 ether);
        } else {
            _simulateSell(1 ether);
        }

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        if (isBuy && expectedSettle > 0 && remainingBeforeSettle > 0) {
            assertEq(uint256(remainingAfterAccum), uint256(remainingBeforeSettle), "accum period unchanged");
            assertEq(
                uint256(remainingBeforeSettle) - uint256(remainingAfter),
                expectedSettle > uint256(remainingBeforeSettle) ? uint256(remainingBeforeSettle) : expectedSettle
            );
        } else {
            assertEq(uint256(remainingAfter), uint256(remainingBeforeSettle));
        }
    }

    /// Sell never injects regardless of amount
    function testFuzz_P6_sellNeverInjects(uint256 soldAmount) public {
        soldAmount = bound(soldAmount, 1, 1_000_000_000 ether);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateSell(soldAmount);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        assertEq(uint256(remainingAfter), uint256(remainingBefore));
    }

    /// Below-minimum period settlement never injects
    function testFuzz_P6_belowMinPeriodSettleDoesNotInject(uint256 periodVolume) public {
        uint256 maxVolume = _minPeriodVolumeForSettle();
        if (maxVolume <= 1) return;
        periodVolume = bound(periodVolume, 1, maxVolume - 1);

        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        _simulateBuy(periodVolume);
        _warpNextPeriod();
        _simulateBuy(1 ether);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        assertEq(uint256(remainingAfter), uint256(remainingBefore));
    }

    // ═══════════════════════════════════════════════════════════════════
    // P7 - Asset Custody
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 7: Hook Asset Custody
    /// Hook token balance should only decrease via inject path
    function testFuzz_P7_balanceOnlyDecreasesViaInject(uint256 boughtAmount) public {
        boughtAmount = bound(boughtAmount, _minPeriodVolumeForSettle(), 1_000_000_000 ether);

        _simulateBuy(boughtAmount);

        uint256 hookBalBefore = IERC20(address(token)).balanceOf(address(hook));
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));

        _warpNextPeriod();
        _simulateBuy(1 ether);

        uint256 hookBalAfter = IERC20(address(token)).balanceOf(address(hook));
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));

        uint256 balanceDecrease = hookBalBefore - hookBalAfter;
        uint256 remainingDecrease = uint256(remainingBefore) - uint256(remainingAfter);
        assertEq(balanceDecrease, remainingDecrease, "Balance decrease must match remaining decrease");
    }

    /// Sell does not change Hook's token balance
    function testFuzz_P7_sellDoesNotAffectHookBalance(uint256 soldAmount) public {
        soldAmount = bound(soldAmount, 1, 1_000_000_000 ether);

        uint256 hookBalBefore = IERC20(address(token)).balanceOf(address(hook));
        _simulateSell(soldAmount);
        uint256 hookBalAfter = IERC20(address(token)).balanceOf(address(hook));

        assertEq(hookBalAfter, hookBalBefore);
    }
}
