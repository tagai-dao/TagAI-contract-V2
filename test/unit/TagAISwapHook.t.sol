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
    uint256 constant FIRST_HOUR_RATIO_PPM = 1_000_000; // 0.1%
    uint256 constant MIN_INJECT_OUTPUT = 168 ether / 10; // 16.8 tokens
    uint256 constant MAX_HOURLY_BUY_VOLUME = 420_000_000 ether;

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

    // ─── Injection logic via afterSwap ───

    function test_injection_decreasesRemainingOnBuy() public {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));
        assertEq(uint256(initialRemaining), NUTBOX_ALLOCATION);

        // Simulate a buy swap (zeroForOne=true, ETH→Token)
        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        // delta.amount1() < 0 means tokens leaving pool to buyer
        // 20_000 tokens * 0.1% = 20 ether (above 16.8 ether minimum inject output)
        BalanceDelta delta = toBalanceDelta(-1 ether, -int128(int256(20_000 ether)));

        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = 20_000 ether * FIRST_HOUR_RATIO_PPM / RATIO_SCALE;
        assertEq(uint256(initialRemaining) - uint256(remainingAfter), expected);
        assertEq(hook.getCurrentHourRatioPpm(address(token)), uint32(FIRST_HOUR_RATIO_PPM));
    }

    function test_injection_skipsWhenOutputBelowMinimum() public {
        (, uint96 initialRemaining,) = hook.tokenInfo(address(token));

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: 0
        });
        // 1000 tokens * 0.1% = 1 token < 16.8 minimum inject output
        BalanceDelta delta = toBalanceDelta(-0.01 ether, -int128(int256(1000 ether)));

        vm.prank(address(mockPoolManager));
        hook.afterSwap(address(0), poolKey, buyParams, delta, bytes(""));

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingAfter), uint256(initialRemaining), "Below-min output should not inject");
    }

    function test_injection_usesTierFromLastNonZeroHour() public {
        uint32 hour = uint32(block.timestamp / 3600);

        // Hour 1: accumulate 300k buy volume (< 400k → 2.083% for next hour)
        _simulateBuy(300_000 ether);

        // Hour 2: ratio locked from hour 1 volume
        vm.warp((uint256(hour) + 1) * 3600);
        (, uint96 remainingBefore,) = hook.tokenInfo(address(token));
        assertEq(hook.getCurrentHourRatioPpm(address(token)), 20_833_333);

        _simulateBuy(10_000 ether);
        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expected = 10_000 ether * 20_833_333 / RATIO_SCALE;
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expected);
    }

    function test_injection_skipsEmptyHourUsesLastNonZeroVolume() public {
        uint32 hour = uint32(block.timestamp / 3600);

        _simulateBuy(300_000 ether);
        vm.warp((uint256(hour) + 1) * 3600);
        _simulateBuy(20_000 ether); // lock ratio for hour 2 (inject output > 16.8)

        // Hour 3: no trades in hour 2, still use 300k tier
        vm.warp((uint256(hour) + 2) * 3600);
        assertEq(hook.getCurrentHourRatioPpm(address(token)), 20_833_333);
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

    function test_injection_hourlyBuyVolumeCapAt420M() public {
        (, uint96 remainingStart,) = hook.tokenInfo(address(token));

        // First buy: 419M (under cap)
        _simulateBuy(419_000_000 ether);
        (,, uint256 hourBuy,) = hook.hourlyState(address(token));
        assertEq(hourBuy, 419_000_000 ether);

        (, uint96 remainingMid,) = hook.tokenInfo(address(token));
        uint256 inject1 = uint256(remainingStart) - uint256(remainingMid);
        assertEq(inject1, 419_000_000 ether * FIRST_HOUR_RATIO_PPM / RATIO_SCALE);

        // Second buy: +2M → only 1M counts toward injection (hits 420M cap)
        _simulateBuy(2_000_000 ether);
        (,, hourBuy,) = hook.hourlyState(address(token));
        assertEq(hourBuy, MAX_HOURLY_BUY_VOLUME);

        (, uint96 remainingAfterPartial,) = hook.tokenInfo(address(token));
        uint256 inject2 = uint256(remainingMid) - uint256(remainingAfterPartial);
        assertEq(inject2, 1_000_000 ether * FIRST_HOUR_RATIO_PPM / RATIO_SCALE);

        // Third buy: cap already reached → no further injection
        _simulateBuy(100_000 ether);
        (,, hourBuy,) = hook.hourlyState(address(token));
        assertEq(hourBuy, MAX_HOURLY_BUY_VOLUME);

        (, uint96 remainingEnd,) = hook.tokenInfo(address(token));
        assertEq(uint256(remainingEnd), uint256(remainingAfterPartial));
    }

    function test_injection_hugeBuyLimitedByHourlyCapNotFullBoughtAmount() public {
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

        (, uint96 remainingAfter,) = hook.tokenInfo(address(token));
        uint256 expectedInject = MAX_HOURLY_BUY_VOLUME * FIRST_HOUR_RATIO_PPM / RATIO_SCALE;
        assertEq(uint256(remainingBefore) - uint256(remainingAfter), expectedInject);
        assertGt(uint256(remainingAfter), 0, "hourly cap prevents single swap from draining allocation");

        (,, uint256 hourBuy,) = hook.hourlyState(address(token));
        assertEq(hourBuy, MAX_HOURLY_BUY_VOLUME);
    }

    // ─── getHooksRegistrationBitmap ───

    function test_getHooksRegistrationBitmap_correctBits() public {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        // beforeInitialize=0, beforeSwap=6, afterSwap=7, beforeSwapReturnsDelta=10, afterSwapReturnsDelta=11
        uint16 expected = uint16((1 << 0) | (1 << 6) | (1 << 7) | (1 << 10) | (1 << 11));
        assertEq(bitmap, expected);
    }
}
