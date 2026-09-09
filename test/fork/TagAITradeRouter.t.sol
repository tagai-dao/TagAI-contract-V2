// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest, ForkPair, ForkStake} from "./Pump13Mainnet.t.sol";
import {Token} from "../../src/pump/Token.sol";
import {Vm} from "forge-std/Vm.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";

// Test-only probe: determines which account owns a deposit made through another contract.
contract StakeCallerProbe {
    function deposit(address lp, address pool, uint256 amount) external payable {
        IERC20(lp).transferFrom(msg.sender, address(this), amount);
        IERC20(lp).approve(pool, amount);
        ForkStake(pool).deposit{value: msg.value}(amount);
    }

    function withdraw(address lp, address pool, uint256 amount) external payable {
        ForkStake(pool).withdraw{value: msg.value}(amount);
        IERC20(lp).transfer(msg.sender, amount);
    }
    receive() external payable {}
}

/// @dev Run only test_tradeRouter_* to exclude inherited base regression tests.
contract TagAITradeRouterForkTest is Pump13MainnetForkTest {
    function _tradeLeg(TagAITradeRouter executor, Token t, uint8 index, uint256 amount, bool isBuy)
        internal
        view
        returns (TagAITradeRouter.Leg memory)
    {
        address asset = address(t);
        if (index != 0) (asset,,) = t.componentAt(index - 1);
        return TagAITradeRouter.Leg(
            index,
            amount,
            index == 0 ? 0 : 1,
            1,
            executor.routeHash(isBuy ? address(0) : asset, isBuy ? asset : address(0))
        );
    }

    function _splitRoundtrip(uint256 componentCount, address subject) internal {
        Token t = _create(_config(0, componentCount, true));
        _fill(t);
        _list(t);
        TagAITradeRouter executor = new TagAITradeRouter(address(pump), address(router), Config.pancakeV2Factory());
        address buyer = makeAddr("split-buyer");
        vm.deal(buyer, 10 ether);
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](componentCount + 1);
        uint256 chunk = 0.1 ether;
        for (uint8 i; i < legs.length; ++i) {
            legs[i] = _tradeLeg(executor, t, i, chunk, true);
        }
        uint256 beforeBuy = vm.snapshotState();
        vm.prank(buyer);
        uint256 quoted =
            executor.buy{value: chunk * legs.length}(address(t), legs, 1, block.timestamp + 60, buyer, subject);
        vm.revertToState(beforeBuy);
        // The exact same complete-plan simulation is the frontend's quote boundary.
        vm.recordLogs();
        vm.prank(buyer);
        uint256 out =
            executor.buy{value: chunk * legs.length}(address(t), legs, quoted, block.timestamp + 60, buyer, subject);
        address expectedSubject =
            subject != address(0) && IIPShare(IPSHARE).ipshareCreated(subject) ? subject : t.getIPShare();
        _assertCapture(vm.getRecordedLogs(), t, expectedSubject, true);
        assertEq(out, quoted);
        assertEq(t.balanceOf(buyer), out);
        vm.prank(buyer);
        t.approve(address(executor), out);
        uint256 allocated;
        for (uint8 i; i < legs.length; ++i) {
            uint256 amount = i + 1 == legs.length ? out - allocated : out / legs.length;
            allocated += amount;
            legs[i] = _tradeLeg(executor, t, i, amount, false);
        }
        uint256 beforeSell = vm.snapshotState();
        vm.prank(buyer);
        quoted = executor.sell(address(t), out, legs, 1, block.timestamp + 60, buyer, subject);
        vm.revertToState(beforeSell);
        uint256 balanceBefore = buyer.balance;
        vm.recordLogs();
        vm.prank(buyer);
        uint256 received = executor.sell(address(t), out, legs, quoted, block.timestamp + 60, buyer, subject);
        _assertCapture(vm.getRecordedLogs(), t, expectedSubject, true);
        assertEq(received, quoted);
        assertEq(buyer.balance - balanceBefore, received);
        assertEq(t.balanceOf(buyer), 0);
        assertEq(address(executor).balance, 0);
        assertEq(t.balanceOf(address(executor)), 0);
        assertEq(t.allowance(address(executor), address(router)), 0);
        for (uint256 i; i < componentCount; ++i) {
            (address asset,,) = t.componentAt(i);
            assertEq(IERC20(asset).balanceOf(address(executor)), 0);
            assertEq(IERC20(asset).allowance(address(executor), address(router)), 0);
        }
    }

    function _assertCapture(Vm.Log[] memory entries, Token t, address expected, bool mainUsed) internal view {
        uint256 capture;
        uint256 hookFee;
        uint256 feeEvents;
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory e = entries[i];
            if (
                e.emitter == address(hook)
                    && e.topics[0] == keccak256("SwapFeeCollected(bytes32,address,uint256,uint256,uint256)")
                    && e.topics[2] == bytes32(uint256(uint160(address(t))))
            ) {
                (, uint256 fee,) = abi.decode(e.data, (uint256, uint256, uint256));
                hookFee += fee;
                ++feeEvents;
            }
            if (
                e.emitter == IPSHARE && e.topics[0] == keccak256("ValueCaptured(address,address,uint256)")
                    && e.topics[2] == bytes32(uint256(uint160(address(hook))))
            ) {
                assertEq(e.topics[1], bytes32(uint256(uint160(expected))), "wrong IPShare beneficiary");
                capture += uint256(e.topics[3]);
            }
        }
        if (mainUsed) {
            assertEq(feeEvents, 1);
            assertGt(hookFee, 0);
        } else {
            assertEq(feeEvents, 0);
        }
        assertEq(capture, hookFee, "IPShare value does not match main-pool fee");
    }

    function test_tradeRouter_customSubjectFiveLegBuyAndSellFees() public {
        address subject = makeAddr("frontend-ipshare-subject");
        IIPShare(IPSHARE).createShare{value: IIPShare(IPSHARE).createFee()}(subject);
        _splitRoundtrip(4, subject);
    }

    function test_tradeRouter_uncreatedSubjectFallsBackOnBuyAndSell() public {
        _splitRoundtrip(1, makeAddr("uncreated-subject"));
    }

    function test_tradeRouter_componentOnlyDoesNotChargeIPShare() public {
        Token t = _create(_config(0, 1, true));
        _fill(t);
        _list(t);
        TagAITradeRouter executor = new TagAITradeRouter(address(pump), address(router), Config.pancakeV2Factory());
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = _tradeLeg(executor, t, 1, 0.1 ether, true);
        vm.recordLogs();
        uint256 out = executor.buy{value: 0.1 ether}(address(t), legs, 1, block.timestamp, address(this), creator);
        _assertCapture(vm.getRecordedLogs(), t, creator, false);
        t.approve(address(executor), out);
        legs[0] = _tradeLeg(executor, t, 1, out, false);
        vm.recordLogs();
        executor.sell(address(t), out, legs, 1, block.timestamp, address(this), creator);
        _assertCapture(vm.getRecordedLogs(), t, creator, false);
    }

    function test_tradeRouter_twoLegRoundtrip() public {
        _splitRoundtrip(1, address(0));
    }

    function test_tradeRouter_fiveLegRoundtrip() public {
        _splitRoundtrip(4, address(0));
    }

    function test_tradeRouter_pendingCannotTrade() public {
        Token t = _create(_config(0, 1, true));
        _fill(t);
        TagAITradeRouter executor = new TagAITradeRouter(address(pump), address(router), Config.pancakeV2Factory());
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = TagAITradeRouter.Leg(0, 0.1 ether, 0, 1, bytes32(uint256(1)));
        vm.expectRevert(TagAITradeRouter.InvalidToken.selector);
        executor.buy{value: 0.1 ether}(address(t), legs, 1, block.timestamp + 60, address(this), address(0));
    }

    function test_tradeRouter_realStakingCreditsCallerNotOriginalUser() public {
        Token t = _create(_config(0, 1, true));
        _fill(t);
        _list(t);
        (address asset,, address pair) = t.componentAt(0);
        address pool = ICommunity(t.nutboxCommunity()).activedPools(0);
        router.swapExactInput{value: 0.1 ether}(
            address(0), address(t), 0.1 ether, 1, address(this), block.timestamp + 60
        );
        uint256 tokenAmount = 100 ether;
        uint256 assetAmount = IERC20(asset).balanceOf(pair) * tokenAmount / t.balanceOf(pair);
        router.swapExactInput{value: 0.1 ether}(
            address(0), asset, 0.1 ether, assetAmount, address(this), block.timestamp + 60
        );
        t.transfer(pair, tokenAmount);
        IERC20(asset).transfer(pair, assetAmount);
        uint256 lp = ForkPair(pair).mint(address(this));
        uint256 fee = ICommittee(COMMITTEE).getPoolOperationFee();
        StakeCallerProbe probe = new StakeCallerProbe();
        IERC20(pair).approve(address(probe), lp);
        probe.deposit{value: fee}(pair, pool, lp);
        assertEq(ForkStake(pool).getUserStakedAmount(address(probe)), lp);
        assertEq(ForkStake(pool).getUserStakedAmount(address(this)), 0);
        probe.withdraw{value: fee}(pair, pool, lp);
        assertEq(IERC20(pair).balanceOf(address(this)), lp);
        // The second UI operation must be signed by the user directly.
        IERC20(pair).approve(pool, lp);
        ForkStake(pool).deposit{value: fee}(lp);
        assertEq(ForkStake(pool).getUserStakedAmount(address(this)), lp);
        assertEq(ForkStake(pool).getUserStakedAmount(address(probe)), 0);
    }
}
