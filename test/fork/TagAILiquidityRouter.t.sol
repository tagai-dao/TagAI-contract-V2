// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest, ForkPair, ForkStake} from "./Pump13Mainnet.t.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";
import {TagAILiquidityRouter} from "../../src/router/TagAILiquidityRouter.sol";
import {Token} from "../../src/pump/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Real BSC venues/assets; fresh production contracts in the fork, no DEX mocks.
/// Run test_liquidity_* only, excluding inherited Pump regression tests.
contract TagAILiquidityRouterForkTest is Pump13MainnetForkTest {
    TagAITradeRouter trade;
    TagAILiquidityRouter liquidity;
    address user;
    uint256 constant INPUT = 0.2 ether;
    uint256 constant Q128 = 1 << 128;

    struct Quote {
        uint256 lp;
        uint256 grossT;
        uint256 netT;
        uint256 usedA;
        uint256 remainderT;
        uint256 remainderA;
    }

    function _fixture(uint256 start, uint256 count) internal returns (Token t) {
        emit log_named_uint("BSC fork block", block.number);
        t = _create(_config(start, count, true));
        _fill(t);
        _list(t);
        trade = new TagAITradeRouter(address(pump), address(router), Config.pancakeV2Factory());
        liquidity = new TagAILiquidityRouter(trade);
        user = makeAddr("bnb-lp-user");
        vm.deal(user, 10 ether);
    }

    function _leg(Token t, uint256 amount, bool buy) internal view returns (TagAITradeRouter.Leg[] memory legs) {
        legs = new TagAITradeRouter.Leg[](1);
        legs[0] = TagAITradeRouter.Leg(
            0, amount, 0, 1, trade.routeHash(buy ? address(0) : address(t), buy ? address(t) : address(0))
        );
    }

    // Independently simulate the two purchases and V2 mint arithmetic; no helper quote/mocks.
    // All preview state is reverted. Real executions use nontrivial price/LP bounds.
    function _quote(Token t, uint256 index, uint256 tokenBnb, address subject)
        internal
        returns (TagAILiquidityRouter.Zap memory z, Quote memory q)
    {
        (address a,, address p) = t.componentAt(index);
        z = TagAILiquidityRouter.Zap(
            address(t),
            index,
            tokenBnb,
            1,
            1,
            1,
            block.timestamp + 60,
            subject,
            trade.routeHash(address(0), address(t)),
            trade.routeHash(address(0), a),
            1,
            1
        );
        uint256 snapshot = vm.snapshotState();
        uint256 boughtT =
            trade.buy{value: tokenBnb}(address(t), _leg(t, tokenBnb, true), 1, z.deadline, address(this), subject);
        uint256 boughtA = router.swapExactInput{value: INPUT - tokenBnb}(
            address(0), a, INPUT - tokenBnb, 1, address(this), z.deadline
        );
        (uint112 r0, uint112 r1,) = ForkPair(p).getReserves();
        (uint256 rt, uint256 ra) =
            ForkPair(p).token0() == address(t) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        q.grossT = boughtT;
        q.netT = boughtT - boughtT / 1000;
        q.usedA = q.netT * ra / rt;
        if (q.usedA > boughtA) {
            q.usedA = boughtA;
            q.netT = boughtA * rt / ra;
            q.grossT = q.netT + (q.netT - 1) / 999;
        }
        q.remainderT = boughtT - q.grossT;
        q.remainderA = boughtA - q.usedA;
        q.lp = _min(q.netT * IERC20(p).totalSupply() / rt, q.usedA * IERC20(p).totalSupply() / ra);
        z.minToken = boughtT * 99 / 100;
        z.minAsset = boughtA * 99 / 100;
        z.minLP = q.lp * 99 / 100;
        if (q.remainderT != 0) {
            t.approve(address(trade), q.remainderT);
            uint256 refund = trade.sell(
                address(t), q.remainderT, _leg(t, q.remainderT, false), 1, z.deadline, address(this), subject
            );
            z.minTokenRefundRateX128 = refund * Q128 / q.remainderT * 99 / 100;
        }
        if (q.remainderA != 0) {
            IERC20(a).approve(address(router), q.remainderA);
            uint256 refund = router.swapExactInput(a, address(0), q.remainderA, 1, address(this), z.deadline);
            z.minAssetRefundRateX128 = refund * Q128 / q.remainderA * 99 / 100;
        }
        assertGt(z.minTokenRefundRateX128, 0);
        assertGt(z.minAssetRefundRateX128, 0);
        assertTrue(vm.revertToState(snapshot));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _logs(Vm.Log[] memory logs, Token t, address subject, uint256 swaps, uint256 refund, uint256 tax)
        internal
        view
    {
        uint256 count;
        uint256 fee;
        uint256 captured;
        uint256 refunded;
        uint256 taxed;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory e = logs[i];
            if (
                e.emitter == address(hook)
                    && e.topics[0] == keccak256("SwapFeeCollected(bytes32,address,uint256,uint256,uint256)")
            ) {
                (, uint256 f,) = abi.decode(e.data, (uint256, uint256, uint256));
                fee += f;
                ++count;
            }
            if (e.emitter == IPSHARE && e.topics[0] == keccak256("ValueCaptured(address,address,uint256)")) {
                assertEq(e.topics[1], bytes32(uint256(uint160(subject))));
                assertEq(e.topics[2], bytes32(uint256(uint160(address(hook)))));
                captured += uint256(e.topics[3]);
            }
            if (e.emitter == address(liquidity) && e.topics[0] == keccak256("NativeRefund(address,uint256)")) {
                assertEq(e.topics[1], bytes32(uint256(uint160(user))));
                refunded += abi.decode(e.data, (uint256));
            }
            if (
                e.emitter == address(t)
                    && e.topics[0] == keccak256("ComponentPoolTaxBurned(address,address,address,uint256,uint256)")
            ) {
                (, uint256 amount) = abi.decode(e.data, (uint256, uint256));
                taxed += amount;
            }
        }
        assertEq(count, swaps, "main pool swap count");
        assertGt(fee, 0);
        assertEq(captured, fee, "IPShare fee reconciliation");
        assertEq(refunded, refund, "native refund reconciliation");
        assertEq(taxed, tax, "component transfer tax");
    }

    function _roundtrip(Token t, uint256 index, bool surplusToken, address subject) internal {
        trade = new TagAITradeRouter(address(pump), address(router), Config.pancakeV2Factory());
        liquidity = new TagAILiquidityRouter(trade);
        user = makeAddr(string.concat("lp-component-user-", vm.toString(index)));
        vm.deal(user, 10 ether);
        (address a,, address p) = t.componentAt(index);
        (TagAILiquidityRouter.Zap memory z, Quote memory q) =
            _quote(t, index, surplusToken ? 0.199 ether : 0.001 ether, subject);
        if (surplusToken) assertGt(q.remainderT, 0);
        else assertGt(q.remainderA, 0);
        uint256 tokenReserve = t.balanceOf(p);
        uint256 assetReserve = IERC20(a).balanceOf(p);
        // Seed unrelated balances using real purchased tokens; these must remain untouched.
        vm.prank(creator);
        t.transfer(address(liquidity), 17 ether);
        router.swapExactInput{value: 0.001 ether}(address(0), a, 0.001 ether, 1, address(this), block.timestamp);
        IERC20(a).transfer(address(liquidity), 7);
        vm.deal(address(liquidity), 123);
        // Donation purchase moves the underlying stock pool, so refresh the quote.
        (z, q) = _quote(t, index, z.tokenBnb, subject);
        uint256 beforeBnb = user.balance;
        vm.recordLogs();
        vm.prank(user);
        uint256 lp = liquidity.addWithBNB{value: INPUT}(z);
        uint256 refund = user.balance + INPUT - beforeBnb;
        assertGt(refund, 0);
        assertLt(refund, INPUT);
        assertEq(lp, q.lp, "LP matches reserve/supply model");
        assertEq(IERC20(p).balanceOf(user), lp);
        assertEq(t.balanceOf(p) - tokenReserve, q.netT);
        assertEq(IERC20(a).balanceOf(p) - assetReserve, q.usedA);
        _logs(
            vm.getRecordedLogs(),
            t,
            subject == address(0) ? creator : subject,
            surplusToken ? 2 : 1,
            refund,
            q.grossT / 1000
        );
        assertEq(t.balanceOf(address(liquidity)), 17 ether);
        assertEq(IERC20(a).balanceOf(address(liquidity)), 7);
        assertEq(address(liquidity).balance, 123);
        assertEq(t.balanceOf(user), 0);
        assertEq(IERC20(a).balanceOf(user), 0);
        assertEq(t.allowance(address(liquidity), address(trade)), 0);
        assertEq(IERC20(a).allowance(address(liquidity), address(router)), 0);
        assertEq(address(trade).balance, 0);
        assertEq(t.balanceOf(address(trade)), 0);
        // LP staking remains a separate transaction signed by the user.
        address pool = ICommunity(t.nutboxCommunity()).activedPools(index);
        uint256 fee = ICommittee(COMMITTEE).getPoolOperationFee();
        vm.startPrank(user);
        IERC20(p).approve(pool, lp);
        ForkStake(pool).deposit{value: fee}(lp);
        assertEq(ForkStake(pool).getUserStakedAmount(user), lp);
        assertEq(ForkStake(pool).getUserStakedAmount(address(liquidity)), 0);
        ForkStake(pool).withdraw{value: fee}(lp);
        uint256 grossOut = t.balanceOf(p) * lp / IERC20(p).totalSupply();
        uint256 assetOut = IERC20(a).balanceOf(p) * lp / IERC20(p).totalSupply();
        IERC20(p).approve(address(liquidity), lp);
        (uint256 netOut, uint256 receivedA) =
            liquidity.remove(address(t), index, lp, grossOut - grossOut / 1000, assetOut, block.timestamp);
        vm.stopPrank();
        assertEq(netOut, grossOut - grossOut / 1000);
        assertEq(receivedA, assetOut);
        assertEq(t.balanceOf(user), netOut);
        assertEq(IERC20(a).balanceOf(user), receivedA);
        assertEq(IERC20(p).balanceOf(user), 0);
    }

    function test_liquidity_stockSurplusRefundAndStakeRemove() public {
        _roundtrip(_fixture(2, 1), 0, false, address(0)); // QQQB stock/ETF
    }

    function test_liquidity_tokenSurplusRefundWithCustomIPShare() public {
        Token t = _fixture(2, 1);
        address subject = makeAddr("lp-referral");
        IIPShare(IPSHARE).createShare{value: IIPShare(IPSHARE).createFee()}(subject);
        _roundtrip(t, 0, true, subject);
    }

    function test_liquidity_sixDecimalGold() public {
        _roundtrip(_fixture(7, 1), 0, false, address(0));
    }

    function test_liquidity_fourStockComponents() public {
        Token t = _fixture(2, 4);
        for (uint256 i; i < 4; ++i) {
            _roundtrip(t, i, i % 2 == 0, address(0));
        }
    }

    function _state(Token t, address a, address p) internal view returns (bytes32) {
        (uint112 r0, uint112 r1,) = ForkPair(p).getReserves();
        return keccak256(
            abi.encode(
                user.balance,
                address(liquidity).balance,
                address(trade).balance,
                address(hook).balance,
                VAULT.balance,
                t.balanceOf(user),
                t.balanceOf(address(liquidity)),
                t.balanceOf(p),
                t.balanceOf(DEAD),
                IERC20(a).balanceOf(p),
                IERC20(a).balanceOf(address(liquidity)),
                IERC20(p).balanceOf(user),
                IERC20(p).totalSupply(),
                r0,
                r1,
                t.allowance(address(liquidity), address(trade)),
                IERC20(a).allowance(address(liquidity), address(router))
            )
        );
    }

    function _revertCase(uint256 mode) internal {
        Token t = _fixture(2, 1);
        (address a,, address p) = t.componentAt(0);
        (TagAILiquidityRouter.Zap memory z, Quote memory q) =
            _quote(t, 0, mode == 2 ? 0.199 ether : 0.001 ether, address(0));
        if (mode == 0) z.minLP = q.lp + 1;
        if (mode == 1) z.minAssetRefundRateX128 *= 100;
        if (mode == 2) z.minTokenRefundRateX128 *= 100;
        if (mode == 3) z.minToken *= 100;
        if (mode == 4) z.minAsset *= 100;
        if (mode == 5) z.assetRouteHash = bytes32(uint256(123));
        bytes32 beforeState = _state(t, a, p);
        bytes4 expected = mode == 5
            ? TagAILiquidityRouter.InvalidPool.selector
            : (mode == 1 || mode == 4)
                ? bytes4(keccak256("PriceUnavailable()"))
                : TagAILiquidityRouter.Slippage.selector;
        vm.expectRevert(expected);
        vm.prank(user);
        liquidity.addWithBNB{value: INPUT}(z);
        assertEq(_state(t, a, p), beforeState, "failed zap must roll back mint, buys, fees and approvals");
        // Retry the valid quote against exactly the same state, proving fixture/path viability.
        (z, q) = _quote(t, 0, z.tokenBnb, address(0));
        vm.prank(user);
        assertEq(liquidity.addWithBNB{value: INPUT}(z), q.lp);
    }

    function test_liquidity_minLpRollsBackEntireZap() public {
        _revertCase(0);
    }

    function test_liquidity_assetRefundSlippageRollsBackEntireZap() public {
        _revertCase(1);
    }

    function test_liquidity_tokenRefundSlippageRollsBackEntireZap() public {
        _revertCase(2);
    }

    function test_liquidity_tokenBuySlippageRollsBackEntireZap() public {
        _revertCase(3);
    }

    function test_liquidity_assetBuySlippageRollsBackEntireZap() public {
        _revertCase(4);
    }

    function test_liquidity_changedRouteRejected() public {
        _revertCase(5);
    }
}
