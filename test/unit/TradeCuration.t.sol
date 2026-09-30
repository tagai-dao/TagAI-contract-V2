// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {CommunityFactory} from "../../src/nutbox/CommunityFactory.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {TradeCurationFactory} from "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import {TradeCuration} from "../../src/nutbox/dapps/trade-curation/TradeCuration.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TradeRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract TradeCurationTest is Test {
    Committee internal committee;
    CommunityFactory internal cf;
    HourlyTickCalculator internal calculator;
    TradeCurationFactory internal factory;
    TradeRewardToken internal token;
    Community internal community;
    TradeCuration internal pool;
    address internal user;
    address internal feeRecipient;
    uint256 internal constant SIGNER_KEY = 0xABC123;
    bytes32 internal constant CLAIM_TYPEHASH =
        keccak256("Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)");

    function setUp() public {
        vm.warp(3600);
        user = makeAddr("user");
        vm.deal(user, 10 ether);
        feeRecipient = makeAddr("feeRecipient");
        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        cf = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(cf));
        factory = new TradeCurationFactory(address(cf), vm.addr(SIGNER_KEY));
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));
        token = new TradeRewardToken();
        (community, pool) = _newCommunity();
    }

    function _newCommunity() internal returns (Community c, TradeCuration p) {
        c = Community(payable(cf.createCommunity(false, address(token), address(0), "", address(calculator), "")));
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        c.adminAddPool("Trade Curation", ratios, address(factory), "");
        p = TradeCuration(payable(c.activedPools(0)));
    }

    function _sign(
        uint256 key,
        address target,
        uint256 chain,
        string memory domainName,
        address to,
        uint256 orderId,
        uint256 amount,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(domainName)),
                keccak256("1"),
                chain,
                target
            )
        );
        bytes32 claim = keccak256(abi.encode(CLAIM_TYPEHASH, chain, target, orderId, amount, to, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, claim)));
        return abi.encodePacked(r, s, v);
    }

    function _signature(uint256 orderId, uint256 amount, uint256 deadline) internal view returns (bytes memory) {
        return _sign(SIGNER_KEY, address(pool), block.chainid, "Nutbox TradeCuration", user, orderId, amount, deadline);
    }

    function _fundAccrual() internal {
        token.approve(address(calculator), 168_000 ether);
        calculator.inject(address(community), 168_000 ether);
        vm.warp(block.timestamp + 168 hours);
    }

    function test_claimFromBalanceAndReplayBlocked() public {
        token.transfer(address(pool), 100 ether);
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        vm.prank(user);
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertEq(token.balanceOf(user), 10 ether);
        assertEq(pool.totalClaimed(), 10 ether);
        assertTrue(pool.claimedOrders(user, 1));
        vm.prank(user);
        vm.expectRevert("Claimed");
        pool.claim(1, 10 ether, block.timestamp, sig);
    }

    function test_claimHarvestsRealAccruedRewards() public {
        _fundAccrual();
        bytes memory sig = _signature(1, 100 ether, block.timestamp);
        vm.prank(user);
        pool.claim(1, 100 ether, block.timestamp, sig);
        assertEq(token.balanceOf(user), 100 ether);
        assertEq(token.balanceOf(address(pool)), 167_900 ether);
        assertEq(pool.getUserStakedAmount(user), 0);
        assertEq(pool.getUserStakedAmount(address(pool)), pool.getTotalStakedAmount());
    }

    function test_zeroFeeHarvestAndClaimRefundAllOverpayment() public {
        _fundAccrual();
        uint256 beforeBalance = user.balance;
        bytes memory sig = _signature(1, 100 ether, block.timestamp);
        vm.prank(user);
        pool.claim{value: 1 ether}(1, 100 ether, block.timestamp, sig);
        assertEq(user.balance, beforeBalance);
        vm.prank(user);
        pool.harvestRewards{value: 1 ether}();
        assertEq(user.balance, beforeBalance);
        assertEq(address(community).balance, 0);
        assertEq(address(pool).balance, 0);
    }

    function test_eachClaimChargesOneFeeOnBothPathsForRegularUser() public {
        _fundAccrual();
        committee.adminSetPoolOperationFee(0.001 ether);
        for (uint256 orderId = 1; orderId <= 2; ++orderId) {
            bytes memory sig = _signature(orderId, 100 ether, block.timestamp);
            uint256 beforeBalance = user.balance;
            vm.prank(user);
            pool.claim{value: 1 ether}(orderId, 100 ether, block.timestamp, sig);
            assertEq(beforeBalance - user.balance, 0.001 ether);
        }
        assertEq(feeRecipient.balance, 0.002 ether);
        assertEq(address(pool).balance, 0);
        assertEq(address(community).balance, 0);
    }

    function test_feeFreeDirectClaimPaysNoFeeAndRefundsOverpayment() public {
        token.transfer(address(pool), 100 ether);
        committee.adminSetPoolOperationFee(0.001 ether);
        committee.adminAddFeeFreeAddress(user);
        uint256 beforeBalance = user.balance;
        for (uint256 orderId = 1; orderId <= 2; ++orderId) {
            bytes memory sig = _signature(orderId, 10 ether, block.timestamp);
            vm.prank(user);
            pool.claim{value: orderId == 1 ? 0 : 1 ether}(orderId, 10 ether, block.timestamp, sig);
        }
        assertEq(token.balanceOf(user), 20 ether);
        assertEq(user.balance, beforeBalance);
        assertEq(feeRecipient.balance, 0);
        assertEq(address(pool).balance, 0);
    }

    function test_rejectWrongSignerUserPoolChainDomainAndAmount() public {
        token.transfer(address(pool), 100 ether);
        bytes[] memory bad = new bytes[](6);
        bad[0] = _sign(456, address(pool), block.chainid, "Nutbox TradeCuration", user, 1, 10 ether, block.timestamp);
        bad[1] = _sign(
            SIGNER_KEY,
            address(pool),
            block.chainid,
            "Nutbox TradeCuration",
            address(this),
            1,
            10 ether,
            block.timestamp
        );
        bad[2] = _sign(
            SIGNER_KEY, address(community), block.chainid, "Nutbox TradeCuration", user, 1, 10 ether, block.timestamp
        );
        bad[3] = _sign(
            SIGNER_KEY, address(pool), block.chainid + 1, "Nutbox TradeCuration", user, 1, 10 ether, block.timestamp
        );
        bad[4] = _sign(
            SIGNER_KEY, address(pool), block.chainid, "Nutbox SocialCuration", user, 1, 10 ether, block.timestamp
        );
        bad[5] = _signature(1, 11 ether, block.timestamp);
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(user);
            vm.expectRevert("Bad sig");
            pool.claim(1, 10 ether, block.timestamp, bad[i]);
        }
        assertFalse(pool.claimedOrders(user, 1));
    }

    function test_expiredAndZeroAmountRejected() public {
        bytes memory expired = _signature(1, 10 ether, block.timestamp - 1);
        vm.prank(user);
        vm.expectRevert("Expired");
        pool.claim(1, 10 ether, block.timestamp - 1, expired);
        vm.prank(user);
        vm.expectRevert("Amount=0");
        pool.claim(1, 0, block.timestamp, "");
    }

    function test_failedPayoutDoesNotConsumePermitAndCanRetry() public {
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        vm.prank(user);
        vm.expectRevert("Insufficient bal");
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertFalse(pool.claimedOrders(user, 1));
        token.transfer(address(pool), 10 ether);
        vm.prank(user);
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertTrue(pool.claimedOrders(user, 1));
    }

    function test_signerRotationOnlyOwnerAndOldPermitsInvalidated() public {
        token.transfer(address(pool), 100 ether);
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.adminSetClaimSigner(user);
        vm.expectRevert("Invalid address");
        factory.adminSetClaimSigner(address(0));
        factory.adminSetClaimSigner(vm.addr(456));
        vm.prank(user);
        vm.expectRevert("Bad sig");
        pool.claim(1, 10 ether, block.timestamp, sig);
        sig = _sign(456, address(pool), block.chainid, "Nutbox TradeCuration", user, 1, 10 ether, block.timestamp);
        vm.prank(user);
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertEq(token.balanceOf(user), 10 ether);
    }

    function test_factoryAllowsOnlyOnePoolPerRealCommunity() public {
        vm.expectRevert("Permission denied: caller is not community");
        factory.createPool(address(community), "Trade", "");
        vm.prank(user);
        vm.expectRevert("Invalid community");
        factory.createPool(user, "Trade", "");
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.expectRevert("Community already has this pool");
        community.adminAddPool("Trade", ratios, address(factory), "");
        (, TradeCuration second) = _newCommunity();
        assertTrue(address(second) != address(pool));
    }

    function test_cannotInitializeCloneTwiceOrInitializeImplementation() public {
        address implementation = factory.poolTemplate();
        vm.expectRevert("Initializable: contract is already initialized");
        pool.initialize(address(community));
        vm.expectRevert("Initializable: contract is already initialized");
        TradeCuration(payable(implementation)).initialize(address(community));
    }

    function test_constructorRejectsZeroSigner() public {
        vm.expectRevert("Invalid address");
        new TradeCurationFactory(address(cf), address(0));
    }
}
