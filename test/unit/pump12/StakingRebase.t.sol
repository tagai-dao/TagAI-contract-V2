// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {SToken} from "../../../src/pump12/staking/SToken.sol";
import {Staking} from "../../../src/pump12/staking/Staking.sol";

contract StakingMockToken is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakingMockDistributor {
    StakingMockToken public token;
    SToken public sToken;
    address public staking;
    uint256 public reward = 10e18;
    uint256 public calls;

    function configure(StakingMockToken token_, SToken sToken_, address staking_) external {
        token = token_;
        sToken = sToken_;
        staking = staking_;
    }

    function distribute() external returns (uint256) {
        require(msg.sender == staking, "only staking");
        ++calls;
        if (sToken.totalSupply() == 0) return 0;
        token.mint(staking, reward);
        return reward;
    }
}

contract StakingRebaseTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    StakingMockToken internal token;
    SToken internal sToken;
    Staking internal staking;
    StakingMockDistributor internal distributor;
    uint40 internal start;

    function setUp() public {
        token = new StakingMockToken();
        distributor = new StakingMockDistributor();
        sToken = SToken(Clones.clone(address(new SToken())));
        staking = Staking(Clones.clone(address(new Staking())));
        sToken.initialize(address(staking), "Staked Token", "sTKN");
        start = uint40(block.timestamp);
        staking.initialize(address(token), address(sToken), address(distributor), start);
        distributor.configure(token, sToken, address(staking));

        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
    }

    function test_queueThenRebaseAndImmediateUnstake() public {
        vm.prank(alice);
        staking.stake(alice, 100e18);

        vm.warp(start + 8 hours);
        staking.rebase();
        assertEq(sToken.balanceOf(alice), 100e18);
        (,,, uint256 queued) = staking.epoch();
        assertEq(queued, 10e18);

        vm.warp(start + 16 hours);
        staking.rebase();
        assertEq(sToken.balanceOf(alice), 110e18);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(alice, 110e18);
        assertEq(token.balanceOf(alice) - before, 110e18);
        assertEq(sToken.balanceOf(alice), 0);
    }

    function test_stakeProcessesDueEpochBeforeMintingReceipt() public {
        vm.warp(start + 8 hours);
        vm.prank(alice);
        staking.stake(alice, 100e18);
        assertEq(distributor.calls(), 1);
        assertEq(sToken.balanceOf(alice), 100e18);
        (,,, uint256 firstQueued) = staking.epoch();
        assertEq(firstQueued, 0);

        vm.warp(start + 16 hours);
        staking.rebase();
        assertEq(sToken.balanceOf(alice), 100e18);
        (,,, uint256 secondQueued) = staking.epoch();
        assertEq(secondQueued, 10e18);

        vm.warp(start + 24 hours);
        staking.rebase();
        assertEq(sToken.balanceOf(alice), 110e18);
    }

    function test_oneCallAdvancesAtMostOneMissedEpoch() public {
        vm.prank(alice);
        staking.stake(alice, 100e18);
        vm.warp(start + 32 hours);

        staking.rebase();
        (, uint64 number, uint64 end,) = staking.epoch();
        assertEq(number, 2);
        assertEq(end, start + 16 hours);
        assertEq(distributor.calls(), 1);
    }

    function test_warmupIsZeroAndThirdPartyStakeIsImmediate() public {
        assertEq(staking.WARMUP_EPOCHS(), 0);
        vm.prank(alice);
        staking.stake(bob, 25e18);
        assertEq(sToken.balanceOf(bob), 25e18);
    }

    function test_onlyStakingControlsReceiptSupply() public {
        vm.expectRevert(SToken.OnlyStaking.selector);
        sToken.mint(alice, 1);
        vm.expectRevert(SToken.OnlyStaking.selector);
        sToken.burn(alice, 1);
        vm.expectRevert(SToken.OnlyStaking.selector);
        sToken.rebase(1, 1);
    }
}
