// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TradeCurationTest} from "../unit/TradeCuration.t.sol";
import {TradeCuration} from "../../src/nutbox/dapps/trade-curation/TradeCuration.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TradeCallbackActor {
    address public target;
    bytes public payload;
    bool public rejectEth;
    uint256 public callbacks;
    bool public claimEntered;
    bool public harvestEntered;
    bytes public claimError;
    bytes public harvestError;

    function configure(address target_, bytes memory payload_, bool reject_) external {
        target = target_;
        payload = payload_;
        rejectEth = reject_;
    }

    function execute(uint256 value) external {
        (bool ok, bytes memory result) = target.call{value: value}(payload);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
    }

    function attack() public {
        ++callbacks;
        (claimEntered, claimError) = target.call(payload);
        (harvestEntered, harvestError) = target.call(abi.encodeWithSignature("harvestRewards()"));
    }

    receive() external payable {
        require(!rejectEth, "REJECT_REFUND");
        attack();
    }
}

contract AdversarialRewardToken is ERC20 {
    enum Mode {
        Normal,
        FalseReturn,
        RevertTransfer,
        NoReturn,
        Callback,
        Taxed
    }
    Mode public mode;
    TradeCallbackActor public callback;

    constructor() ERC20("Adversarial", "BAD") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configure(Mode mode_, TradeCallbackActor callback_) external {
        mode = mode_;
        callback = callback_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.RevertTransfer) revert("TOKEN_TRANSFER_FAILED");
        if (mode == Mode.FalseReturn) {
            super.transfer(to, amount);
            return false;
        }
        if (mode == Mode.Taxed) {
            _burn(msg.sender, amount / 10);
            return super.transfer(to, amount - amount / 10);
        }
        bool ok = super.transfer(to, amount);
        if (mode == Mode.Callback) callback.attack();
        if (mode == Mode.NoReturn) assembly { return(0, 0) }
        return ok;
    }
}

contract TradeCurationAdversarialTest is TradeCurationTest {
    function _payload(address recipient, uint256 amount) private view returns (bytes memory) {
        bytes memory sig = _sign(
            SIGNER_KEY, address(pool), block.chainid, "Nutbox TradeCuration", recipient, 77, amount, block.timestamp
        );
        return abi.encodeCall(pool.claim, (77, amount, block.timestamp, sig));
    }

    function _assertGuard(TradeCallbackActor actor) private view {
        assertGt(actor.callbacks(), 0, "callback must actually execute");
        assertFalse(actor.claimEntered());
        assertFalse(actor.harvestEntered());
        bytes memory expected = abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call");
        assertEq(actor.claimError(), expected);
        assertEq(actor.harvestError(), expected);
    }

    function test_attackRefundCannotReenterClaimOrHarvest() public {
        token.transfer(address(pool), 100 ether);
        TradeCallbackActor actor = new TradeCallbackActor();
        actor.configure(address(pool), _payload(address(actor), 10 ether), false);
        vm.deal(address(actor), 1 ether);
        actor.execute(1 ether);
        _assertGuard(actor);
        assertEq(token.balanceOf(address(actor)), 10 ether);
        assertEq(pool.totalClaimed(), 10 ether);
        assertEq(address(actor).balance, 1 ether);
    }

    function test_attackFeeRecipientCannotReenterBeforeOrderIsConsumed() public {
        token.transfer(address(pool), 100 ether);
        TradeCallbackActor recipient = new TradeCallbackActor();
        recipient.configure(address(pool), _payload(user, 10 ether), false);
        committee.adminSetFeeRecipient(payable(address(recipient)));
        committee.adminSetPoolOperationFee(0.001 ether);
        bytes memory payload = _payload(user, 10 ether);
        vm.prank(user);
        (bool ok,) = address(pool).call{value: 0.001 ether}(payload);
        assertTrue(ok);
        _assertGuard(recipient);
        assertEq(token.balanceOf(user), 10 ether);
        assertEq(address(recipient).balance, 0.001 ether);
    }

    function test_rejectedRefundRollsBackHarvestDebtFeeAndPermitThenRetry() public {
        _fundAccrual();
        committee.adminSetPoolOperationFee(0.001 ether);
        TradeCallbackActor actor = new TradeCallbackActor();
        bytes memory payload = _payload(address(actor), 10 ether);
        actor.configure(address(pool), payload, true);
        vm.deal(address(actor), 1 ether);
        uint256 debt = community.getUserDebt(address(pool), address(pool));
        uint256 cursor = community.getLastRewardCursor();
        uint256 pending = community.getPoolPendingRewards(address(pool), address(pool));
        vm.expectRevert("ETH refund failed");
        actor.execute(1 ether);
        assertFalse(pool.claimedOrders(address(actor), 77));
        assertEq(pool.totalClaimed(), 0);
        assertEq(token.balanceOf(address(actor)), 0);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(community)), 168_000 ether);
        assertEq(community.getUserDebt(address(pool), address(pool)), debt);
        assertEq(community.getLastRewardCursor(), cursor);
        assertEq(community.getPoolPendingRewards(address(pool), address(pool)), pending);
        assertEq(feeRecipient.balance, 0);
        assertEq(address(actor).balance, 1 ether);
        // Same rejecting receiver can succeed when no refund is necessary.
        actor.execute(0.001 ether);
        assertTrue(pool.claimedOrders(address(actor), 77));
        assertEq(token.balanceOf(address(actor)), 10 ether);
        assertEq(feeRecipient.balance, 0.001 ether);
    }

    function test_rejectedFeeRollsBackDirectClaimAndCanRetry() public {
        token.transfer(address(pool), 100 ether);
        TradeCallbackActor recipient = new TradeCallbackActor();
        recipient.configure(address(pool), "", true);
        committee.adminSetFeeRecipient(payable(address(recipient)));
        committee.adminSetPoolOperationFee(0.001 ether);
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        vm.expectRevert("Fee transfer failed");
        pool.claim{value: 0.001 ether}(1, 10 ether, block.timestamp, sig);
        assertFalse(pool.claimedOrders(user, 1));
        assertEq(pool.totalClaimed(), 0);
        assertEq(user.balance, beforeBalance);
        assertEq(token.balanceOf(address(pool)), 100 ether);
        committee.adminSetFeeRecipient(payable(feeRecipient));
        vm.prank(user);
        pool.claim{value: 0.001 ether}(1, 10 ether, block.timestamp, sig);
        assertEq(token.balanceOf(user), 10 ether);
    }

    function _abnormalPool(bool accrue) private returns (AdversarialRewardToken bad) {
        bad = new AdversarialRewardToken();
        community = Community(payable(cf.createCommunity(false, address(bad), address(0), "", address(calculator), "")));
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        community.adminAddPool("Trade", ratios, address(factory), "");
        pool = TradeCuration(payable(community.activedPools(0)));
        if (accrue) {
            bad.approve(address(calculator), 168_000 ether);
            calculator.inject(address(community), 168_000 ether);
            vm.warp(block.timestamp + 168 hours);
        } else {
            bad.transfer(address(pool), 100 ether);
        }
    }

    function testFuzz_falseOrRevertingTokenRollsBackBothPaths(bool accrue, bool returnFalse) public {
        AdversarialRewardToken bad = _abnormalPool(accrue);
        bad.configure(
            returnFalse ? AdversarialRewardToken.Mode.FalseReturn : AdversarialRewardToken.Mode.RevertTransfer,
            TradeCallbackActor(payable(address(0)))
        );
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        uint256 beforePool = bad.balanceOf(address(pool));
        uint256 beforeCommunity = bad.balanceOf(address(community));
        uint256 beforeDebt = community.getUserDebt(address(pool), address(pool));
        uint256 beforeCursor = community.getLastRewardCursor();
        committee.adminSetPoolOperationFee(0.001 ether);
        uint256 beforeBnb = user.balance;
        vm.prank(user);
        vm.expectRevert(bytes(returnFalse ? "ERC20: operation did not succeed" : "ERC20: call failed"));
        pool.claim{value: 0.001 ether}(1, 10 ether, block.timestamp, sig);
        assertEq(bad.balanceOf(user), 0);
        assertEq(bad.balanceOf(address(pool)), beforePool);
        assertEq(bad.balanceOf(address(community)), beforeCommunity);
        assertEq(community.getUserDebt(address(pool), address(pool)), beforeDebt);
        assertEq(community.getLastRewardCursor(), beforeCursor);
        assertFalse(pool.claimedOrders(user, 1));
        assertEq(pool.totalClaimed(), 0);
        assertEq(user.balance, beforeBnb);
        assertEq(feeRecipient.balance, 0);
        bad.configure(AdversarialRewardToken.Mode.Normal, TradeCallbackActor(payable(address(0))));
        vm.prank(user);
        pool.claim{value: 0.001 ether}(1, 10 ether, block.timestamp, sig);
        assertEq(bad.balanceOf(user), 10 ether);
    }

    function test_noReturnTokenCanHarvestAndPayExactly() public {
        AdversarialRewardToken bad = _abnormalPool(true);
        bad.configure(AdversarialRewardToken.Mode.NoReturn, TradeCallbackActor(payable(address(0))));
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        vm.prank(user);
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertEq(bad.balanceOf(user), 10 ether);
        assertEq(pool.totalClaimed(), 10 ether);
    }

    function test_tokenCallbackCannotReenterDuringHarvestOrPayout() public {
        AdversarialRewardToken bad = _abnormalPool(true);
        TradeCallbackActor callback = new TradeCallbackActor();
        callback.configure(address(pool), _payload(user, 10 ether), false);
        bad.configure(AdversarialRewardToken.Mode.Callback, callback);
        bytes memory payload = _payload(user, 10 ether);
        vm.prank(user);
        (bool ok,) = address(pool).call(payload);
        assertTrue(ok);
        _assertGuard(callback);
        assertEq(callback.callbacks(), 2, "Community transfer and user payout both callback");
        assertEq(bad.balanceOf(user), 10 ether);
        assertEq(pool.totalClaimed(), 10 ether);
    }

    /// @dev Characterization: arbitrary taxed community tokens are not net-amount guaranteed.
    /// Pump's own token does not tax transfers from a curation pool to an ordinary user.
    function test_characterizeTaxedTokenPaysLessThanSignedGrossAmount() public {
        AdversarialRewardToken bad = _abnormalPool(false);
        bad.configure(AdversarialRewardToken.Mode.Taxed, TradeCallbackActor(payable(address(0))));
        bytes memory sig = _signature(1, 10 ether, block.timestamp);
        vm.prank(user);
        pool.claim(1, 10 ether, block.timestamp, sig);
        assertEq(bad.balanceOf(user), 9 ether);
        assertEq(pool.totalClaimed(), 10 ether);
        assertTrue(pool.claimedOrders(user, 1));
    }

    function test_dust365DailyInjectionsAndHarvestsRemainBounded() public {
        token.approve(address(calculator), type(uint256).max);
        uint256 injected;
        for (uint256 day; day < 365; ++day) {
            uint256 amount = 1e12 + uint256(keccak256(abi.encode(day))) % 1e9;
            calculator.inject(address(community), amount);
            injected += amount;
            vm.warp(block.timestamp + 1 days);
            pool.harvestRewards();
            assertEq(token.balanceOf(address(pool)) + token.balanceOf(address(community)), injected);
        }
        vm.warp(block.timestamp + 168 hours);
        pool.harvestRewards();
        uint256 payout = token.balanceOf(address(pool));
        assertGt(payout, 0);
        bytes memory sig = _signature(1, payout, block.timestamp);
        vm.prank(user);
        pool.claim(1, payout, block.timestamp, sig);
        uint256 dust = token.balanceOf(address(community));
        assertEq(token.balanceOf(user) + dust, injected);
        // Community floors its 1e12 accumulator against virtual stake 1e18 on each update.
        assertLt(dust, 366 * 1e6, "rounding loss exceeds one accumulator quantum per settlement");
        assertEq(community.getPoolPendingRewards(address(pool), address(pool)), 0);
        assertEq(pool.totalClaimed(), payout);
        assertEq(token.balanceOf(address(pool)), 0);
        emit log_named_uint("365-day unallocated rounding dust (token wei)", dust);
    }
}
