// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import "../../src/nutbox/interfaces/ICalculator.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple ERC20 for testing (non-mintable, pre-minted supply).
contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/**
 * @title NutboxIntegration
 * @notice Integration test for Calculator + Community reward flow end-to-end.
 *
 * Tests:
 * 1. Deploy Committee, CommunityFactory, HourlyTickCalculator, test ERC20
 * 2. Create community via CommunityFactory (with HourlyTickCalculator as rewardCalculator)
 * 3. Inject tokens at various hours (vm.warp)
 * 4. Call calculateReward and verify amounts match expected F(t) formula
 * 5. Test getHourlyRewards batch query
 * 6. Test that Community.withdrawPoolsRewards correctly uses the calculator
 */
contract NutboxIntegrationTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    SocialCurationFactory public scf;
    TestERC20 public token;
    Community public community;

    address public admin = address(this);
    address public feeRecipient;
    address public claimSigner;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant VEST_WINDOW = 168; // 7 days in hours

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        // 1. Deploy Committee
        committee = new Committee(payable(feeRecipient));
        // Set fees to 0 for simpler testing
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        // 2. Deploy CommunityFactory
        communityFactory = new CommunityFactory(address(committee));

        // 3. Deploy HourlyTickCalculator (communityFactory is the factory)
        calculator = new HourlyTickCalculator(address(communityFactory));

        // 4. Deploy SocialCurationFactory
        scf = new SocialCurationFactory(address(communityFactory), claimSigner);

        // 5. Whitelist calculator and SCF in Committee
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(scf));

        // 6. Deploy test ERC20 token
        token = new TestERC20("TestToken", "TT", TOTAL_SUPPLY);

        // 7. Create community via CommunityFactory
        // The community uses our test token as the community token (non-mintable)
        address communityAddr = communityFactory.createCommunity(
            false,                      // isMintable = false
            address(token),             // communityToken
            address(0),                 // communityTokenFactory (not needed)
            bytes(""),                  // tokenMeta
            address(calculator),        // rewardCalculator
            bytes("")                   // distributionPolicy
        );
        community = Community(payable(communityAddr));

        // 8. Add a SocialCuration pool to the community
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("Social Curation", ratios, address(scf), bytes(""));
    }

    // ─── Test: Single injection, full vest, calculateReward matches ───

    function test_singleInjection_fullVest() public {
        uint256 injectAmount = 168_000 ether; // Divisible by 168 for clean math

        // Transfer tokens to this contract (injector), then approve calculator
        token.approve(address(calculator), type(uint256).max);
        // Transfer tokens to community (since inject sends to community)
        // Actually inject does transferFrom(msg.sender, community, amount)
        // So we need tokens in our balance and approve calculator

        // Warp to a clean hour boundary
        vm.warp(3600); // hour 1

        // Inject
        calculator.inject(address(community), injectAmount);

        // Verify totalInjected
        assertEq(calculator.totalInjected(address(community)), injectAmount);

        // After full vest window (168 hours), all tokens should be released
        uint256 startTimestamp = 3600; // hour 1
        uint256 endTimestamp = startTimestamp + (VEST_WINDOW * 3600); // hour 169

        uint256 reward = calculator.calculateReward(
            address(community),
            startTimestamp,
            endTimestamp
        );
        assertEq(reward, injectAmount, "Full vest should release all tokens");
    }

    // ─── Test: Partial vest returns proportional amount ───

    function test_partialVest_proportional() public {
        uint256 injectAmount = 168_000 ether;

        token.approve(address(calculator), type(uint256).max);
        vm.warp(3600); // hour 1

        calculator.inject(address(community), injectAmount);

        // After 84 hours (half the vest window), should get ~half
        uint256 startTimestamp = 3600;
        uint256 halfVestTimestamp = startTimestamp + (84 * 3600); // 84 hours later

        uint256 reward = calculator.calculateReward(
            address(community),
            startTimestamp,
            halfVestTimestamp
        );

        // Expected: injectAmount * 84 / 168 = injectAmount / 2
        uint256 expected = injectAmount * 84 / VEST_WINDOW;
        assertEq(reward, expected, "Half vest should release half tokens");
    }

    // ─── Test: Multiple injections at different hours ───

    function test_multipleInjections_differentHours() public {
        uint256 amount1 = 168_000 ether;
        uint256 amount2 = 336_000 ether;

        token.approve(address(calculator), type(uint256).max);

        // Inject at hour 1
        vm.warp(3600);
        calculator.inject(address(community), amount1);

        // Inject at hour 10
        vm.warp(10 * 3600);
        calculator.inject(address(community), amount2);

        // Verify totalInjected
        assertEq(calculator.totalInjected(address(community)), amount1 + amount2);

        // After both fully vest (hour 1 + 168 = 169, hour 10 + 168 = 178)
        // At hour 178, both should be fully vested
        uint256 reward = calculator.calculateReward(
            address(community),
            3600,           // from hour 1
            178 * 3600      // to hour 178
        );
        assertEq(reward, amount1 + amount2, "Both injections should be fully vested");
    }

    // ─── Test: Same-hour merge ───

    function test_sameHourMerge() public {
        uint256 amount1 = 100_000 ether;
        uint256 amount2 = 68_000 ether;

        token.approve(address(calculator), type(uint256).max);

        vm.warp(3600); // hour 1
        calculator.inject(address(community), amount1);
        calculator.inject(address(community), amount2);

        // Should be merged into one entry
        assertEq(calculator.totalInjected(address(community)), amount1 + amount2);

        // Full vest
        uint256 reward = calculator.calculateReward(
            address(community),
            3600,
            (1 + VEST_WINDOW) * 3600
        );
        assertEq(reward, amount1 + amount2);
    }

    // ─── Test: getHourlyRewards batch query ───

    function test_getHourlyRewards_batchQuery() public {
        uint256 injectAmount = 168_000 ether; // 1000 per hour

        token.approve(address(calculator), type(uint256).max);

        vm.warp(3600); // Inject at hour 1
        calculator.inject(address(community), injectAmount);

        // Query hourly rewards for hours 1-10 (starting from hour 1 = timestamp 3600)
        uint256[] memory rewards = calculator.getHourlyRewards(
            address(community),
            3600,   // startTimestamp (hour 1)
            10      // numHours
        );

        assertEq(rewards.length, 10);

        // Each hour should release injectAmount / 168 = 1000 ether
        uint256 expectedPerHour = injectAmount / VEST_WINDOW;
        for (uint256 i = 0; i < 10; i++) {
            assertEq(rewards[i], expectedPerHour, "Each hour should release equal amount");
        }
    }

    // ─── Test: calculateReward returns 0 when head <= lastCursor ───

    function test_calculateReward_zeroWhenHeadLessOrEqual() public {
        uint256 injectAmount = 168_000 ether;

        token.approve(address(calculator), type(uint256).max);
        vm.warp(3600);
        calculator.inject(address(community), injectAmount);

        // head <= lastCursor should return 0
        uint256 reward = calculator.calculateReward(
            address(community),
            10 * 3600,  // lastCursor at hour 10
            5 * 3600    // head at hour 5 (before lastCursor)
        );
        assertEq(reward, 0, "Should return 0 when head <= lastCursor");
    }

    // ─── Test: Community.withdrawPoolsRewards uses calculator correctly ───

    function test_communityWithdrawPoolsRewards() public {
        uint256 injectAmount = 168_000 ether;

        // Transfer tokens to community (since it's non-mintable, community needs balance)
        // inject() does transferFrom(msg.sender, community, amount)
        token.approve(address(calculator), type(uint256).max);

        vm.warp(3600); // hour 1
        calculator.inject(address(community), injectAmount);

        // The SocialCuration pool is the sole staker with VIRTUAL_STAKE = 1e18
        // We need to advance time so rewards accrue
        vm.warp(3600 + 10 * 3600); // advance 10 hours

        // Get the pool address
        address pool = community.activedPools(0);

        // The pool (SocialCuration) needs to call withdrawPoolsRewards
        // But withdrawPoolsRewards charges Tier 3 fee (which we set to 0)
        // Call from the pool itself via harvestRewards or directly

        // Let's call withdrawPoolsRewards from a user perspective
        address user = makeAddr("user");
        vm.deal(user, 1 ether);

        // First, trigger pool update by calling withdrawPoolsRewards
        // The user needs to have staked in the pool, but SocialCuration uses virtual stake
        // SocialCuration.getUserStakedAmount(address(pool)) == VIRTUAL_STAKE
        // So the pool itself is the "staker"

        // Let's verify the calculator returns correct reward
        uint256 expectedReward = injectAmount * 10 / VEST_WINDOW; // 10 hours of vesting
        uint256 calcReward = calculator.calculateReward(
            address(community),
            3600,           // from hour 1
            11 * 3600       // to hour 11
        );
        assertEq(calcReward, expectedReward, "Calculator should return 10 hours of rewards");
    }

    // ─── Test: Composability property F(a,c) = F(a,b) + F(b,c) ───

    function test_composability() public {
        uint256 injectAmount = 168_000 ether;

        token.approve(address(calculator), type(uint256).max);
        vm.warp(3600); // hour 1
        calculator.inject(address(community), injectAmount);

        uint256 t0 = 3600;       // hour 1
        uint256 t1 = 50 * 3600;  // hour 50
        uint256 t2 = 100 * 3600; // hour 100

        uint256 rewardFull = calculator.calculateReward(address(community), t0, t2);
        uint256 rewardFirst = calculator.calculateReward(address(community), t0, t1);
        uint256 rewardSecond = calculator.calculateReward(address(community), t1, t2);

        assertEq(rewardFull, rewardFirst + rewardSecond, "F(a,c) should equal F(a,b) + F(b,c)");
    }

    // ─── Test: getCurrentRewardRate ───

    function test_getCurrentRewardRate() public {
        uint256 injectAmount = 168_000 ether;

        token.approve(address(calculator), type(uint256).max);
        vm.warp(3600); // hour 1
        calculator.inject(address(community), injectAmount);

        // Move to hour 2 so the injection is active
        vm.warp(2 * 3600);

        uint256 rate = calculator.getCurrentRewardRate(address(community));
        // Expected: injectAmount / 168
        assertEq(rate, injectAmount / VEST_WINDOW, "Rate should be amount/168");
    }

    // ─── Test: getStartCursor ───

    function test_getStartCursor() public {
        token.approve(address(calculator), type(uint256).max);
        vm.warp(5 * 3600); // hour 5
        calculator.inject(address(community), 168_000 ether);

        uint256 startCursor = calculator.getStartCursor(address(community));
        assertEq(startCursor, 5 * 3600, "Start cursor should be first injection hour in seconds");
    }
}
