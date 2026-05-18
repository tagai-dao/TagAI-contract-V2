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

/**
 * @title FeeProperty
 * @notice Property tests for fee distribution (P9) and anti-snipe formula (P10).
 */
contract FeePropertyTest is Test {
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

    uint256 constant DIVISOR = 10000;
    uint256 constant ANTI_SNIPE_WINDOW = 15;
    uint256 constant ANTI_SNIPE_FEE_MAX = 8000;
    uint256 constant ANTI_SNIPE_DENOM = 225;

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

        vm.warp(3600);

        vm.startPrank(creator, creator);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(creator);
        token = Token(payable(pump.createToken{value: 0.005 ether}("FEE", bytes32(uint256(1)))));
        vm.stopPrank();
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

    // ═══════════════════════════════════════════════════════════════════
    // P9 - Fee Distribution Correctness
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 9: Fee Distribution
    /// platformFee + deployerFee == totalFee for any swap amount.
    /// platformFee = swapAmount * feeRatio[0] / 10000
    /// deployerFee = totalFee - platformFee = swapAmount * feeRatio[1] / 10000 (with subtraction
    /// absorbing integer-division residue).
    function testFuzz_P9_feeDistributionCorrectness(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e8, 1_000_000 ether);

        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 totalFeeRatio = feeRatio[0] + feeRatio[1];

        uint256 totalFee = (swapAmount * totalFeeRatio) / DIVISOR;
        uint256 platformFee = (swapAmount * feeRatio[0]) / DIVISOR;
        uint256 deployerFee = totalFee - platformFee;

        // platformFee + deployerFee == totalFee (by definition)
        assertEq(platformFee + deployerFee, totalFee);

        // platformFee should be feeRatio[0] BPS of swapAmount
        assertEq(platformFee, (swapAmount * 30) / DIVISOR); // default feeRatio[0] = 30 BPS

        // deployerFee should be feeRatio[1] BPS minus any rounding residue
        uint256 expectedDeployerFee = (swapAmount * 30) / DIVISOR; // default feeRatio[1] = 30 BPS
        // The actual deployerFee is totalFee - platformFee, which absorbs residue
        // So deployerFee may differ from raw computation by at most 1 wei
        assertApproxEqAbs(deployerFee, expectedDeployerFee, 1);
    }

    function testFuzz_P9_feeNeverExceedsSwapAmount(uint256 swapAmount, uint256 platformBPS, uint256 deployerBPS) public {
        platformBPS = bound(platformBPS, 0, 1000);
        deployerBPS = bound(deployerBPS, 0, 1000);
        swapAmount = bound(swapAmount, 1, 1_000_000 ether);

        uint256 totalFee = (swapAmount * (platformBPS + deployerBPS)) / DIVISOR;
        assertLe(totalFee, swapAmount, "Total fee never exceeds swap amount");
    }

    // ═══════════════════════════════════════════════════════════════════
    // P10 - Anti-Snipe Fee Formula
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 10: Anti-Snipe Fee Formula
    /// Within Anti_Snipe_Window (15s), sellsmanFee follows quadratic decay:
    /// sellsmanFee = feeRatio[1] + ((8000 - feeRatio[1]) * remaining² ) / 225
    /// where remaining = 15 - elapsed
    function testFuzz_P10_antiSnipeFormula_withinWindow(uint256 elapsed, uint256 buyAmount) public {
        elapsed = bound(elapsed, 1, ANTI_SNIPE_WINDOW - 1); // 1 to 14 seconds
        buyAmount = bound(buyAmount, 0.01 ether, 1 ether);

        // First buy at supply == 0 — anti-snipe doesn't apply yet
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.01 ether}(0, creator, 0);

        // Now within anti-snipe window (token.createdAt was set during setUp + small offset)
        // Warp to a point where elapsed seconds have passed since createdAt
        vm.warp(token.createdAt() + elapsed);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();

        uint256[2] memory feeRatio = pump.getFeeRatio();
        uint256 expectedPlatform = feeRatio[0]; // 30
        uint256 remaining = ANTI_SNIPE_WINDOW - elapsed;
        uint256 expectedSellsman = feeRatio[1] +
            ((ANTI_SNIPE_FEE_MAX - feeRatio[1]) * remaining * remaining) / ANTI_SNIPE_DENOM;

        assertEq(platformFee, expectedPlatform, "Platform fee should remain at 30 BPS");
        assertEq(sellsmanFee, expectedSellsman, "Sellsman fee should follow quadratic formula");
    }

    function testFuzz_P10_antiSnipeFormula_normalAfterWindow(uint256 elapsed) public {
        elapsed = bound(elapsed, ANTI_SNIPE_WINDOW, 1000); // >= 15 seconds

        // First buy at supply == 0
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.01 ether}(0, creator, 0);

        vm.warp(token.createdAt() + elapsed);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();

        uint256[2] memory feeRatio = pump.getFeeRatio();
        assertEq(platformFee, feeRatio[0]);
        assertEq(sellsmanFee, feeRatio[1]);
    }

    function test_P10_antiSnipeFormula_atZeroElapsed() public {
        // First buy with bondingCurveSupply == 0 — anti-snipe NOT applied
        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();

        uint256[2] memory feeRatio = pump.getFeeRatio();
        // At supply == 0, normal fees apply (no anti-snipe inflation)
        assertEq(platformFee, feeRatio[0]);
        assertEq(sellsmanFee, feeRatio[1]);
    }
}
