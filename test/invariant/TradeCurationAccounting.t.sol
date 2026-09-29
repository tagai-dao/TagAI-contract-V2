// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TradeRewardToken} from "../unit/TradeCuration.t.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {CommunityFactory} from "../../src/nutbox/CommunityFactory.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {TradeCuration} from "../../src/nutbox/dapps/trade-curation/TradeCuration.sol";

contract TradeAccountingHandler is Test {
    TradeRewardToken public token;
    Community public community;
    HourlyTickCalculator public calculator;
    TradeCuration public pool;
    TradeCurationFactory public factory;
    uint256 public injected;
    uint256 public paid;
    uint256 public claims;
    uint256 public harvests;
    uint256 public replays;
    uint256 public rotations;
    uint256 public signerKey = 0xABC123;
    address[64] public users;
    uint256[64] public orders;
    uint256[64] public userPaid;

    struct Injection {
        uint256 hour;
        uint256 amount;
    }
    Injection[] public model;

    constructor(TradeRewardToken t, Community c, HourlyTickCalculator calc, TradeCuration p, TradeCurationFactory f) {
        token = t;
        community = c;
        calculator = calc;
        pool = p;
        factory = f;
        for (uint256 i; i < 64; ++i) {
            users[i] = address(uint160(0x10000 + i));
        }
        token.approve(address(calculator), type(uint256).max);
    }

    function acceptOwnership() external {
        factory.acceptOwnership();
    }

    function inject(uint256 seed) external {
        // Multiples of 168*1e6 make the oracle exact despite Community's 1e12 accumulator.
        uint256 amount = bound(seed, 1, 10000) * 168 * 1e6;
        calculator.inject(address(community), amount);
        injected += amount;
        model.push(Injection(block.timestamp / 1 hours, amount));
    }

    function advance(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 30 days));
    }

    function harvest() external {
        pool.harvestRewards();
        ++harvests;
    }

    function signature(uint256 order, uint256 amount, address to) public view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nutbox TradeCuration"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        bytes32 claimHash = keccak256(
            abi.encode(
                keccak256(
                    "Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)"
                ),
                block.chainid,
                address(pool),
                order,
                amount,
                to,
                type(uint256).max
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", domain, claimHash)));
        return abi.encodePacked(r, s, v);
    }

    function claim(uint256 userSeed, uint256 amountSeed) external {
        uint256 available =
            token.balanceOf(address(pool)) + community.getPoolPendingRewards(address(pool), address(pool));
        if (available == 0) return;
        uint256 i = userSeed % 64;
        uint256 amount = amountSeed == type(uint256).max ? available : bound(amountSeed, 1, available);
        uint256 order = ++orders[i];
        bytes memory sig = signature(order, amount, users[i]);
        vm.prank(users[i]);
        pool.claim(order, amount, type(uint256).max, sig);
        userPaid[i] += amount;
        paid += amount;
        ++claims;
        assertTrue(pool.claimedOrders(users[i], order));
    }

    function replay(uint256 userSeed) external {
        uint256 i = userSeed % 64;
        if (orders[i] == 0) return;
        // Re-sign with current signer: even signer rotation cannot revive a consumed order.
        bytes memory sig = signature(orders[i], 1, users[i]);
        vm.prank(users[i]);
        vm.expectRevert("Claimed");
        pool.claim(orders[i], 1, type(uint256).max, sig);
        ++replays;
    }

    function rotate() external {
        signerKey = signerKey == 0xABC123 ? 0xABC124 : 0xABC123;
        factory.adminSetClaimSigner(vm.addr(signerKey));
        ++rotations;
    }

    /// @dev Independent O(N) model: no production prefix sums / binary search reused.
    function vested() public view returns (uint256 amount) {
        uint256 nowHour = block.timestamp / 1 hours;
        for (uint256 i; i < model.length; ++i) {
            Injection memory entry = model[i];
            uint256 elapsed = nowHour - entry.hour;
            if (elapsed > 168) elapsed = 168;
            amount += entry.amount * elapsed / 168;
        }
    }
}

contract TradeCurationAccountingInvariantTest is StdInvariant, Test {
    TradeRewardToken internal token;
    Community internal community;
    HourlyTickCalculator internal calculator;
    TradeCuration internal pool;
    TradeAccountingHandler internal handler;

    function setUp() public {
        vm.warp(3600);
        Committee committee = new Committee(payable(address(0xFEE)));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        CommunityFactory cf = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(cf));
        TradeCurationFactory factory = new TradeCurationFactory(address(cf), vm.addr(0xABC123));
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));
        token = new TradeRewardToken();
        community =
            Community(payable(cf.createCommunity(false, address(token), address(0), "", address(calculator), "")));
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        community.adminAddPool("Trade", ratios, address(factory), "");
        pool = TradeCuration(payable(community.activedPools(0)));
        handler = new TradeAccountingHandler(token, community, calculator, pool, factory);
        token.transfer(address(handler), token.balanceOf(address(this)));
        factory.transferOwnership(address(handler));
        handler.acceptOwnership();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.inject.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.harvest.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.replay.selector;
        selectors[5] = handler.rotate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_exactCustodyAndIndependentVestingOracle() public view {
        uint256 userBalances;
        for (uint256 i; i < 64; ++i) {
            uint256 balance = token.balanceOf(handler.users(i));
            assertEq(balance, handler.userPaid(i), "user accounting drift");
            userBalances += balance;
        }
        assertEq(userBalances, handler.paid());
        assertEq(pool.totalClaimed(), handler.paid());
        assertEq(calculator.totalInjected(address(community)), handler.injected());
        assertEq(
            token.balanceOf(address(community)) + token.balanceOf(address(pool)) + userBalances, handler.injected()
        );
        uint256 accrued = community.getPoolPendingRewards(address(pool), address(pool));
        assertEq(accrued + token.balanceOf(address(pool)) + userBalances, handler.vested(), "vesting/accounting drift");
        assertLe(userBalances, handler.vested(), "claimed future rewards");
    }

    function test_longRun365Days730Injections64UsersWithFinalDrain() public {
        for (uint256 day; day < 365; ++day) {
            handler.inject(day + 1);
            handler.inject(day + 777); // Same-hour merging is exercised every day.
            handler.advance(12 hours);
            handler.claim(day % 64, type(uint256).max);
            handler.harvest();
            handler.advance(12 hours);
            handler.claim((day + 31) % 64, type(uint256).max);
            handler.replay(day % 64);
            if (day % 7 == 0) handler.rotate();
            invariant_exactCustodyAndIndependentVestingOracle();
        }
        handler.advance(168 hours);
        handler.harvest();
        handler.claim(0, type(uint256).max);
        invariant_exactCustodyAndIndependentVestingOracle();
        assertEq(handler.paid(), handler.injected());
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(community)), 0);
        assertEq(handler.harvests(), 366);
        assertEq(handler.replays(), 365);
        assertGt(handler.claims(), 700);
        assertGt(handler.rotations(), 50);
        for (uint256 i; i < 64; ++i) {
            assertGt(handler.userPaid(i), 0, "every user must receive rewards");
        }
    }
}
