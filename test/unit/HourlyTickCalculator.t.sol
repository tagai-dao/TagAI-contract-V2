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
 * @title HourlyTickCalculatorTest
 * @notice Unit tests for HourlyTickCalculator covering inject, calculateReward, rewardHead, and edge cases.
 */
contract HourlyTickCalculatorTest is Test {
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

    // ─── setDistributionEra ───

    function test_setDistributionEra_revertsIfNotFactory() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(HourlyTickCalculator.OnlyFactory.selector);
        calculator.setDistributionEra(address(community), bytes(""));
    }

    // ─── inject ───

    function test_inject_revertsIfCommunityNotRegistered() public {
        address fakeCommunity = makeAddr("fakeCommunity");
        token.approve(address(calculator), type(uint256).max);
        vm.expectRevert(HourlyTickCalculator.CommunityNotRegistered.selector);
        calculator.inject(fakeCommunity, 168_000 ether);
    }

    function test_inject_revertsIfZeroAmount() public {
        token.approve(address(calculator), type(uint256).max);
        vm.expectRevert(HourlyTickCalculator.ZeroAmount.selector);
        calculator.inject(address(community), 0);
    }

    function test_inject_singleHour_increasesTotalInjected() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);
        assertEq(calculator.totalInjected(address(community)), 168_000 ether);
    }

    function test_inject_sameHourMerge() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 100_000 ether);
        calculator.inject(address(community), 68_000 ether);
        assertEq(calculator.totalInjected(address(community)), 168_000 ether);
    }

    function test_inject_differentHours() public {
        token.approve(address(calculator), type(uint256).max);

        vm.warp(3600); // hour 1
        calculator.inject(address(community), 168_000 ether);

        vm.warp(2 * 3600); // hour 2
        calculator.inject(address(community), 168_000 ether);

        assertEq(calculator.totalInjected(address(community)), 336_000 ether);
    }

    // ─── calculateReward ───

    function test_calculateReward_zeroWhenNoInjections() public {
        assertEq(calculator.calculateReward(address(community), 0, 100 * 3600), 0);
    }

    function test_calculateReward_zeroForReversedRange() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        // head < lastCursor
        assertEq(calculator.calculateReward(address(community), 100 * 3600, 50 * 3600), 0);
    }

    function test_calculateReward_zeroWhenEqual() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        assertEq(calculator.calculateReward(address(community), 50 * 3600, 50 * 3600), 0);
    }

    function test_calculateReward_fullVest_releasesAllTokens() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        // From hour 1 to hour 169 (full vest window)
        uint256 reward = calculator.calculateReward(address(community), 3600, 169 * 3600);
        assertEq(reward, 168_000 ether);
    }

    function test_calculateReward_partialVest() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        // Half vest: 84 hours after injection start
        uint256 reward = calculator.calculateReward(address(community), 3600, 85 * 3600);
        // Expected: 168_000 * 84 / 168 = 84_000
        assertEq(reward, 84_000 ether);
    }

    // ─── rewardHead ───

    function test_rewardHead_returnsHourAlignedTimestamp() public {
        vm.warp(3600 + 500); // hour 1 + 500 seconds
        assertEq(calculator.rewardHead(), 3600);
    }

    function test_rewardHead_atExactHour() public {
        vm.warp(7200); // exactly hour 2
        assertEq(calculator.rewardHead(), 7200);
    }

    function test_rewardHead_atZero() public {
        vm.warp(500); // before hour 1
        assertEq(calculator.rewardHead(), 0);
    }

    // ─── getStartCursor ───

    function test_getStartCursor_zeroWhenNoInjections() public {
        assertEq(calculator.getStartCursor(address(community)), 0);
    }

    function test_getStartCursor_returnsFirstInjectionTimestamp() public {
        vm.warp(5 * 3600); // hour 5
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        assertEq(calculator.getStartCursor(address(community)), 5 * 3600);
    }

    // ─── getCurrentRewardRate ───

    function test_getCurrentRewardRate_zeroWhenNoActiveInjections() public {
        assertEq(calculator.getCurrentRewardRate(address(community)), 0);
    }

    function test_getCurrentRewardRate_singleActiveInjection() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        // Move to next hour so injection becomes active
        vm.warp(2 * 3600);
        assertEq(calculator.getCurrentRewardRate(address(community)), 168_000 ether / VEST);
    }

    function test_getCurrentRewardRate_zeroAfterFullVest() public {
        vm.warp(3600);
        token.approve(address(calculator), type(uint256).max);
        calculator.inject(address(community), 168_000 ether);

        // Move past the vest window
        vm.warp((1 + VEST + 1) * 3600);
        assertEq(calculator.getCurrentRewardRate(address(community)), 0);
    }
}
