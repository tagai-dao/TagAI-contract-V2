// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/dfxstar-score-staking/DFXStarScoreStaking.sol";
import "../../src/nutbox/dapps/dfxstar-score-staking/DFXStarScoreStakingFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple ERC20 for testing (non-mintable, pre-minted supply).
contract TestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/**
 * @title DFXStarScoreStakingTest
 * @notice Unit tests for DFXStarScoreStaking contract.
 */
contract DFXStarScoreStakingTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    DFXStarScoreStakingFactory public factory;
    TestERC20 public token;
    Community public community;
    DFXStarScoreStaking public pool;

    address public admin = address(this);
    address public feeRecipient;
    address public gameAdmin;
    address public user1;
    address public user2;
    address public injector;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant VEST_WINDOW = 168;

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        gameAdmin = makeAddr("gameAdmin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        injector = makeAddr("injector");

        // 1. Deploy Committee
        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        // 2. Deploy CommunityFactory
        communityFactory = new CommunityFactory(address(committee));

        // 3. Deploy HourlyTickCalculator
        calculator = new HourlyTickCalculator(address(communityFactory));

        // 4. Deploy DFXStarScoreStakingFactory
        factory = new DFXStarScoreStakingFactory(address(communityFactory));

        // 5. Whitelist calculator and factory in Committee
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        // 6. Deploy test ERC20 token
        token = new TestERC20("TestToken", "TT", TOTAL_SUPPLY);

        // 7. Create community
        address communityAddr = communityFactory.createCommunity(
            false,
            address(token),
            address(0),
            bytes(""),
            address(calculator),
            bytes("")
        );
        community = Community(payable(communityAddr));

        // 8. Add DFXStarScoreStaking pool to community
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("DFXStar Score Staking", ratios, address(factory), bytes(""));

        // 9. Get pool address
        pool = DFXStarScoreStaking(payable(community.activedPools(0)));

        // 10. Add gameAdmin as admin in factory
        factory.addAdmin(gameAdmin);

        // 11. Deal ETH to users for potential fees
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(injector, 10 ether);
        vm.deal(gameAdmin, 10 ether);

        // 12. Give tokens to injector for reward injection
        token.transfer(injector, 1_000_000 ether);
    }

    // ============ depositFromGame Tests ============

    function test_depositFromGame_success() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool.getTotalStakedAmount(), 1000);
    }

    function test_depositFromGame_multipleUsers() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user2, 2000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool.getUserStakedAmount(user2), 2000);
        assertEq(pool.getTotalStakedAmount(), 3000);
    }

    function test_depositFromGame_revertNotAdmin() public {
        vm.expectRevert("Not admin");
        vm.prank(user1);
        pool.depositFromGame{value: 0}(user1, 1000);
    }

    function test_depositFromGame_revertZeroAmount() public {
        vm.expectRevert("Amount=0");
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 0);
    }

    function test_depositFromGame_revertZeroAddress() public {
        vm.expectRevert("Invalid user");
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(address(0), 1000);
    }

    function test_depositFromGame_accumulate() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 500);

        assertEq(pool.getUserStakedAmount(user1), 1500);
        assertEq(pool.getTotalStakedAmount(), 1500);
    }

    // ============ injectRewards Tests ============

    function test_injectRewards_success() public {
        // First deposit some score
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // Inject rewards
        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        // User should have pending external rewards
        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, injectAmount);
    }

    function test_injectRewards_multipleStakers() public {
        // Two users deposit
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user2, 3000);

        // Inject rewards
        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        // user1 gets 1/4, user2 gets 3/4
        uint256 pending1 = pool.getPendingExternalRewards(user1);
        uint256 pending2 = pool.getPendingExternalRewards(user2);

        assertEq(pending1, 2500 ether);  // 10000 * 1000 / 4000
        assertEq(pending2, 7500 ether);  // 10000 * 3000 / 4000
    }

    function test_injectRewards_revertNoStakers() public {
        vm.expectRevert("No stakers");
        vm.prank(injector);
        pool.injectRewards{value: 0}(100 ether);
    }

    function test_injectRewards_revertZeroAmount() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.expectRevert("Amount=0");
        vm.prank(injector);
        pool.injectRewards{value: 0}(0);
    }

    function test_injectRewards_multipleInjections() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // First injection
        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);

        // Second injection
        pool.injectRewards{value: 0}(5000 ether);
        vm.stopPrank();

        // Total pending should be 15000
        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, 15000 ether);
    }

    // ============ claimExternalRewards Tests ============

    function test_claimExternalRewards_success() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        // Claim rewards
        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
        uint256 balanceAfter = token.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, injectAmount);
        assertEq(pool.getPendingExternalRewards(user1), 0);
    }

    function test_claimExternalRewards_revertNoRewards() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.expectRevert("No rewards");
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
    }

    function test_claimExternalRewards_partialClaim() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // First injection
        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        // Claim first batch
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();

        // Second injection
        vm.startPrank(injector);
        pool.injectRewards{value: 0}(5000 ether);
        vm.stopPrank();

        // Claim second batch
        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
        uint256 balanceAfter = token.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, 5000 ether);
    }

    // ============ Multiple Pools Tests ============

    function test_createMultiplePools() public {
        // Create second pool
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        community.adminAddPool("DFXStar Score Staking 2", ratios, address(factory), bytes(""));

        DFXStarScoreStaking pool2 = DFXStarScoreStaking(payable(community.activedPools(1)));

        // Deposit to both pools
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(gameAdmin);
        pool2.depositFromGame{value: 0}(user1, 2000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool2.getUserStakedAmount(user1), 2000);
    }

    // ============ Admin Management Tests ============

    function test_addAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        factory.addAdmin(newAdmin);
        assertTrue(factory.isAdmin(newAdmin));
    }

    function test_removeAdmin() public {
        factory.removeAdmin(gameAdmin);
        assertFalse(factory.isAdmin(gameAdmin));
    }

    function test_addAdmin_revertNotOwner() public {
        address newAdmin = makeAddr("newAdmin");
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        factory.addAdmin(newAdmin);
    }

    function test_addAdmin_revertAlreadyAdmin() public {
        vm.expectRevert("Already admin");
        factory.addAdmin(gameAdmin);
    }

    function test_removeAdmin_revertNotAdmin() public {
        vm.expectRevert("Not admin");
        factory.removeAdmin(user1);
    }

    // ============ View Functions Tests ============

    function test_getPendingAllRewards() public {
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // Inject external rewards
        vm.startPrank(injector);
        token.approve(address(pool), 10000 ether);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        (uint256 communityPending, uint256 externalPending) = pool.getPendingAllRewards(user1);
        assertEq(externalPending, 10000 ether);
        // communityPending would be 0 unless we inject to calculator
        assertEq(communityPending, 0);
    }

    function test_getPendingExternalRewards_noStake() public {
        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, 0);
    }

    // ============ Edge Cases Tests ============

    function test_depositThenInjectThenDeposit() public {
        // user1 deposits
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // Inject rewards
        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        // user2 deposits after injection
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user2, 1000);

        // Inject more rewards
        vm.startPrank(injector);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        // user1 should have more rewards (was staked for both injections)
        // user2 should have rewards only from second injection
        uint256 pending1 = pool.getPendingExternalRewards(user1);
        uint256 pending2 = pool.getPendingExternalRewards(user2);

        // user1: 10000 (first) + 5000 (second, half of 10000)
        // user2: 5000 (second, half of 10000)
        assertEq(pending1, 15000 ether);
        assertEq(pending2, 5000 ether);
    }

    function test_noFeeForDeposit() public {
        // Set a fee
        committee.adminSetPoolOperationFee(0.1 ether);

        // Fee-free for gameAdmin (would need to set in Committee)
        // For this test, we verify deposit works without sending fee
        vm.prank(gameAdmin);
        pool.depositFromGame{value: 0}(user1, 1000);

        // Should succeed without fee
        assertEq(pool.getUserStakedAmount(user1), 1000);
    }
}
