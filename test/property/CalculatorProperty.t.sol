// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/**
 * @title CalculatorProperty
 * @notice Property-based fuzz tests for HourlyTickCalculator (P1, P2, P3).
 *
 * Tested properties:
 * - P1: Bucket Conservation — full vest window releases exactly the injected amount
 * - P2: Composability — F(t0,t2) == F(t0,t1) + F(t1,t2) for any t0 <= t1 <= t2
 * - P3: Monotonicity — calculateReward returns 0 when head <= lastCursor
 */
contract CalculatorPropertyTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    SocialCurationFactory public scf;
    TestERC20 public token;
    Community public community;

    address public feeRecipient;
    address public claimSigner;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant VEST = 168;

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        scf = new SocialCurationFactory(address(communityFactory), claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(scf));

        token = new TestERC20("TestToken", "TT", TOTAL_SUPPLY);

        address communityAddr = communityFactory.createCommunity(
            false,
            address(token),
            address(0),
            bytes(""),
            address(calculator),
            bytes("")
        );
        community = Community(payable(communityAddr));

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("Social Curation", ratios, address(scf), bytes(""));
    }

    // ═══════════════════════════════════════════════════════════════════
    // P1 - Bucket Conservation
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 1: Bucket Conservation
    /// After a full 168-hour vest window, the total released equals the injected amount.
    function testFuzz_P1_bucketConservation(uint256 amount, uint8 startHourOffset) public {
        // Bound amount to be a multiple of VEST so there's no integer truncation
        amount = bound(amount, VEST, 10_000_000) * VEST; // amount is a multiple of 168
        uint256 startTimestamp = (uint256(startHourOffset) + 1) * 3600;

        vm.warp(startTimestamp);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        uint256 endTimestamp = startTimestamp + (VEST * 3600);
        uint256 reward = calculator.calculateReward(address(community), startTimestamp, endTimestamp);

        assertEq(reward, amount, "Full vest window should release exactly the injected amount");
    }

    /// P1 variant: arbitrary amounts (allowing integer truncation)
    function testFuzz_P1_bucketConservation_anyAmount(uint256 amount, uint8 startHourOffset) public {
        amount = bound(amount, VEST, 10_000_000 ether);
        uint256 startTimestamp = (uint256(startHourOffset) + 1) * 3600;

        vm.warp(startTimestamp);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        uint256 endTimestamp = startTimestamp + (VEST * 3600);
        uint256 reward = calculator.calculateReward(address(community), startTimestamp, endTimestamp);

        // Reward should equal floor(amount / 168) * 168 (no dust loss when range covers full vest)
        // For F(start+168) - F(start), F1=amount (fully ended), F(start)=0, so reward=amount
        assertEq(reward, amount, "Full vest reward should equal amount");
    }

    // ═══════════════════════════════════════════════════════════════════
    // P2 - Composability
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 2: Composability
    /// F(t0, t2) == F(t0, t1) + F(t1, t2) for any t0 <= t1 <= t2
    function testFuzz_P2_composability(uint256 amount, uint8 t1HourOffset, uint8 t2HourOffset) public {
        amount = bound(amount, VEST, 1_000_000 ether);

        vm.warp(3600); // inject at hour 1
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        uint256 t0 = 3600;
        uint256 t1 = t0 + (uint256(t1HourOffset) + 1) * 3600;
        uint256 t2 = t1 + (uint256(t2HourOffset) + 1) * 3600;

        // Move time forward enough to be safe for view calls
        vm.warp(t2 + 3600);

        uint256 full = calculator.calculateReward(address(community), t0, t2);
        uint256 first = calculator.calculateReward(address(community), t0, t1);
        uint256 second = calculator.calculateReward(address(community), t1, t2);

        assertEq(full, first + second, "F(t0,t2) must equal F(t0,t1) + F(t1,t2)");
    }

    /// Composability across multiple injections
    function testFuzz_P2_composability_multipleInjects(
        uint256 amount1,
        uint256 amount2,
        uint8 secondInjectHourOffset,
        uint8 t1HourOffset,
        uint8 t2HourOffset
    ) public {
        amount1 = bound(amount1, VEST, 500_000 ether);
        amount2 = bound(amount2, VEST, 500_000 ether);

        token.approve(address(calculator), type(uint256).max);

        vm.warp(3600);
        calculator.inject(address(community), amount1);

        uint256 secondInjectAt = 3600 + (uint256(secondInjectHourOffset) + 1) * 3600;
        vm.warp(secondInjectAt);
        calculator.inject(address(community), amount2);

        uint256 t0 = 3600;
        uint256 t1 = t0 + (uint256(t1HourOffset) + 1) * 3600;
        uint256 t2 = t1 + (uint256(t2HourOffset) + 1) * 3600;

        vm.warp(t2 + 3600);

        uint256 full = calculator.calculateReward(address(community), t0, t2);
        uint256 first = calculator.calculateReward(address(community), t0, t1);
        uint256 second = calculator.calculateReward(address(community), t1, t2);

        assertEq(full, first + second, "Composability holds across multiple injections");
    }

    // ═══════════════════════════════════════════════════════════════════
    // P3 - Monotonicity / Boundary
    // ═══════════════════════════════════════════════════════════════════

    /// Feature: tagai-v2-nutbox-integration, Property 3: Monotonicity
    /// calculateReward returns 0 when head <= lastCursor
    function testFuzz_P3_zeroWhenReversed(uint256 amount, uint256 a, uint256 b) public {
        amount = bound(amount, VEST, 1_000_000 ether);
        a = bound(a, 3600, 1000 * 3600);
        b = bound(b, 0, a); // b <= a

        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        assertEq(calculator.calculateReward(address(community), a, b), 0, "Reversed range should return 0");
    }

    /// Reward must be non-negative (uint256 implies this, but verify it doesn't revert)
    function testFuzz_P3_neverReverts(uint256 amount, uint256 a, uint256 b) public {
        amount = bound(amount, VEST, 1_000_000 ether);
        a = bound(a, 0, 10_000 * 3600);
        b = bound(b, 0, 10_000 * 3600);

        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        // Should never revert regardless of input ordering
        calculator.calculateReward(address(community), a, b);
    }

    /// Reward across a < b interval should be ≤ totalInjected
    function testFuzz_P3_rewardBoundedByTotalInjected(
        uint256 amount,
        uint256 a,
        uint256 b
    ) public {
        amount = bound(amount, VEST, 1_000_000 ether);
        a = bound(a, 0, 1000 * 3600);
        b = bound(b, a + 3600, a + 1000 * 3600);

        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), amount);

        // Fast-forward to allow query
        vm.warp(b + 3600);

        uint256 reward = calculator.calculateReward(address(community), a, b);
        assertLe(reward, amount, "Reward never exceeds total injected");
    }
}
