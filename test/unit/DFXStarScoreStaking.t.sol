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
 * @notice Unit tests for World-bound DFXStarScoreStaking.
 */
contract DFXStarScoreStakingTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    DFXStarScoreStakingFactory public factory;
    TestERC20 public token;
    Community public community;
    DFXStarScoreStaking public pool;

    address public feeRecipient;
    address public world;
    address public world2;
    address public user1;
    address public user2;
    address public injector;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        world = makeAddr("world");
        world2 = makeAddr("world2");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        injector = makeAddr("injector");

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        factory = new DFXStarScoreStakingFactory(address(communityFactory));

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        token = new TestERC20("TestToken", "TT", TOTAL_SUPPLY);

        address communityAddr = communityFactory.createCommunity(
            false, address(token), address(0), bytes(""), address(calculator), bytes("")
        );
        community = Community(payable(communityAddr));

        // meta = abi.encode(world); one World per pool
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("DFXStar Score Staking", ratios, address(factory), abi.encode(world));

        pool = DFXStarScoreStaking(payable(community.activedPools(0)));

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(injector, 10 ether);
        vm.deal(world, 10 ether);

        token.transfer(injector, 1_000_000 ether);
    }

    // ============ depositFromGame Tests ============

    function test_depositFromGame_success() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool.getTotalStakedAmount(), 1000);
        assertEq(pool.world(), world);
        assertEq(factory.poolOfWorld(world), address(pool));
    }

    function test_depositFromGame_multipleUsers() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(world);
        pool.depositFromGame{value: 0}(user2, 2000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool.getUserStakedAmount(user2), 2000);
        assertEq(pool.getTotalStakedAmount(), 3000);
    }

    function test_depositFromGame_revertNotWorld() public {
        vm.expectRevert("Not world");
        vm.prank(user1);
        pool.depositFromGame{value: 0}(user1, 1000);
    }

    function test_depositFromGame_revertZeroAmount() public {
        vm.expectRevert("Amount=0");
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 0);
    }

    function test_depositFromGame_revertZeroAddress() public {
        vm.expectRevert("Invalid user");
        vm.prank(world);
        pool.depositFromGame{value: 0}(address(0), 1000);
    }

    function test_depositFromGame_accumulate() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 500);

        assertEq(pool.getUserStakedAmount(user1), 1500);
        assertEq(pool.getTotalStakedAmount(), 1500);
    }

    // ============ createPool meta Tests ============

    function test_createPool_revertEmptyMeta() public {
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.expectRevert("World meta");
        community.adminAddPool("bad", ratios, address(factory), bytes(""));
    }

    function test_createPool_revertWorldAlreadyBound() public {
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.expectRevert("World already bound");
        community.adminAddPool("dup", ratios, address(factory), abi.encode(world));
    }

    // ============ injectRewards Tests ============

    function test_injectRewards_success() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, injectAmount);
    }

    function test_injectRewards_multipleStakers() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(world);
        pool.depositFromGame{value: 0}(user2, 3000);

        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        uint256 pending1 = pool.getPendingExternalRewards(user1);
        uint256 pending2 = pool.getPendingExternalRewards(user2);

        assertEq(pending1, 2500 ether);
        assertEq(pending2, 7500 ether);
    }

    function test_injectRewards_revertNoStakers() public {
        vm.expectRevert("No stakers");
        vm.prank(injector);
        pool.injectRewards{value: 0}(100 ether);
    }

    function test_injectRewards_revertZeroAmount() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.expectRevert("Amount=0");
        vm.prank(injector);
        pool.injectRewards{value: 0}(0);
    }

    function test_injectRewards_multipleInjections() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);
        pool.injectRewards{value: 0}(5000 ether);
        vm.stopPrank();

        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, 15000 ether);
    }

    // ============ claimExternalRewards Tests ============

    function test_claimExternalRewards_success() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        uint256 injectAmount = 10000 ether;
        vm.startPrank(injector);
        token.approve(address(pool), injectAmount);
        pool.injectRewards{value: 0}(injectAmount);
        vm.stopPrank();

        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
        uint256 balanceAfter = token.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, injectAmount);
        assertEq(pool.getPendingExternalRewards(user1), 0);
    }

    function test_claimExternalRewards_revertNoRewards() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.expectRevert("No rewards");
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
    }

    function test_claimExternalRewards_partialClaim() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();

        vm.startPrank(injector);
        pool.injectRewards{value: 0}(5000 ether);
        vm.stopPrank();

        uint256 balanceBefore = token.balanceOf(user1);
        vm.prank(user1);
        pool.claimExternalRewards{value: 0}();
        uint256 balanceAfter = token.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, 5000 ether);
    }

    // ============ Multiple Pools Tests ============

    function test_createMultiplePools_differentWorlds() public {
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        community.adminAddPool("DFXStar Score Staking 2", ratios, address(factory), abi.encode(world2));

        DFXStarScoreStaking pool2 = DFXStarScoreStaking(payable(community.activedPools(1)));
        assertEq(pool2.world(), world2);
        assertEq(factory.poolOfWorld(world2), address(pool2));

        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.prank(world2);
        pool2.depositFromGame{value: 0}(user1, 2000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
        assertEq(pool2.getUserStakedAmount(user1), 2000);
    }

    // ============ Admin Management Tests (bookkeeping only) ============

    function test_addAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        factory.addAdmin(newAdmin);
        assertTrue(factory.isAdmin(newAdmin));
    }

    function test_removeAdmin() public {
        address bookAdmin = makeAddr("bookAdmin");
        factory.addAdmin(bookAdmin);
        factory.removeAdmin(bookAdmin);
        assertFalse(factory.isAdmin(bookAdmin));
    }

    function test_addAdmin_revertNotOwner() public {
        address newAdmin = makeAddr("newAdmin");
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        factory.addAdmin(newAdmin);
    }

    function test_addAdmin_revertAlreadyAdmin() public {
        address bookAdmin = makeAddr("bookAdmin");
        factory.addAdmin(bookAdmin);
        vm.expectRevert("Already admin");
        factory.addAdmin(bookAdmin);
    }

    function test_removeAdmin_revertNotAdmin() public {
        vm.expectRevert("Not admin");
        factory.removeAdmin(user1);
    }

    // ============ View Functions Tests ============

    function test_getPendingAllRewards() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.startPrank(injector);
        token.approve(address(pool), 10000 ether);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        (uint256 communityPending, uint256 externalPending) = pool.getPendingAllRewards(user1);
        assertEq(externalPending, 10000 ether);
        assertEq(communityPending, 0);
    }

    function test_getPendingExternalRewards_noStake() public {
        uint256 pending = pool.getPendingExternalRewards(user1);
        assertEq(pending, 0);
    }

    // ============ Edge Cases Tests ============

    function test_depositThenInjectThenDeposit() public {
        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        vm.startPrank(injector);
        token.approve(address(pool), type(uint256).max);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        vm.prank(world);
        pool.depositFromGame{value: 0}(user2, 1000);

        vm.startPrank(injector);
        pool.injectRewards{value: 0}(10000 ether);
        vm.stopPrank();

        uint256 pending1 = pool.getPendingExternalRewards(user1);
        uint256 pending2 = pool.getPendingExternalRewards(user2);

        assertEq(pending1, 15000 ether);
        assertEq(pending2, 5000 ether);
    }

    function test_noFeeForDeposit() public {
        committee.adminSetPoolOperationFee(0.1 ether);

        vm.prank(world);
        pool.depositFromGame{value: 0}(user1, 1000);

        assertEq(pool.getUserStakedAmount(user1), 1000);
    }
}
