// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {Token} from "../../src/pump/Token.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title TokenTest
 * @notice Token bonding-curve unit tests on Uniswap v4 Pump stack.
 */
contract TokenTest is V4PumpTestBase {
    Token public token;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public override {
        super.setUp();
        if (!envReady) return;
        token = _createToken("UNIT");
    }

    function test_buyToken_noSignatureRequired() public onlyReady {
        vm.warp(block.timestamp + 16);
        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);
        assertGt(received, 0);
    }

    function test_sellToken_noSignatureRequired() public onlyReady {
        vm.warp(block.timestamp + 16);
        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);

        uint256 sellAmount = received / 2;
        vm.prank(buyer, buyer);
        token.sellToken(sellAmount, 0, creator, 0);
        assertEq(IERC20(address(token)).balanceOf(buyer), received - sellAmount);
    }

    function test_receive_buysWhenNotListed() public onlyReady {
        vm.warp(block.timestamp + 16);
        uint256 beforeBal = IERC20(address(token)).balanceOf(buyer);

        vm.prank(buyer, buyer);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertTrue(success);
        assertGt(IERC20(address(token)).balanceOf(buyer), beforeBal);
    }

    function test_receive_revertsWhenListed() public onlyReady {
        _fillBondingCurveUntilListed(token, buyer);
        assertTrue(token.listed());

        vm.prank(buyer, buyer);
        (bool success, bytes memory reason) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IToken.TokenListed.selector));
    }

    function test_totalSupply_oneBillion() public onlyReady {
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }

    function test_totalSupply_invariantAfterTrades() public onlyReady {
        vm.warp(block.timestamp + 16);
        vm.prank(buyer, buyer);
        uint256 received = token.buyToken{value: 1 ether}(0, creator, 0);
        if (token.listed()) {
            vm.skip(true);
            return;
        }
        vm.prank(buyer, buyer);
        token.sellToken(received / 2, 0, creator, 0);
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY);
    }

    function test_initialize_canOnlyBeCalledOnce() public onlyReady {
        vm.expectRevert();
        token.initialize(address(pump), creator, "AGAIN");
    }

    function test_buyToken_revertsBelowDustGuard() public onlyReady {
        vm.warp(block.timestamp + 16);
        vm.prank(buyer, buyer);
        vm.expectRevert();
        token.buyToken{value: 1}(0, creator, 0);
    }

    function test_setNutboxAddresses_onlyManager() public onlyReady {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        token.setNutboxAddresses(makeAddr("comm"), makeAddr("pool"));
    }

    function test_antiSnipeWindow_dynamicSellsmanFee() public onlyReady {
        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        assertEq(platformFee, 30);
        assertGt(sellsmanFee, 30);

        vm.prank(buyer, buyer);
        token.buyToken{value: 0.1 ether}(0, creator, 0);

        (platformFee, sellsmanFee) = token.getBuyFeeRatios();
        assertGt(sellsmanFee, 30);
        assertEq(platformFee, 30);
    }

    function test_antiSnipeWindow_normalFeesAfter15s() public onlyReady {
        vm.prank(buyer, buyer);
        token.buyToken{value: 0.1 ether}(0, creator, 0);
        vm.warp(block.timestamp + 16);

        (uint256 platformFee, uint256 sellsmanFee) = token.getBuyFeeRatios();
        assertEq(platformFee, 30);
        assertEq(sellsmanFee, 30);
    }

    function test_ipshareSubject_isCreator() public onlyReady {
        assertEq(token.ipshareSubject(), creator);
    }

    function test_transferIPShareOwner_success() public onlyReady {
        address newSubject = makeAddr("newSubject");
        vm.deal(newSubject, 1 ether);
        vm.prank(newSubject, newSubject);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(newSubject);

        vm.prank(creator, creator);
        vm.expectEmit(true, true, false, true);
        emit IToken.IPShareSubjectTransferred(creator, newSubject);
        token.transferIPShareOwner(newSubject);

        assertEq(token.ipshareSubject(), newSubject);
        assertEq(token.getIPShare(), newSubject);
    }

    function test_transferIPShareOwner_onlyCurrentSubject() public onlyReady {
        address newSubject = makeAddr("newSubject2");
        vm.deal(newSubject, 1 ether);
        vm.prank(newSubject, newSubject);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(newSubject);

        vm.prank(buyer, buyer);
        vm.expectRevert(IToken.OnlyIPShareOwner.selector);
        token.transferIPShareOwner(newSubject);
    }

    function test_transferIPShareOwner_revertsZeroAddress() public onlyReady {
        vm.prank(creator, creator);
        vm.expectRevert(IToken.ZeroIPShareSubject.selector);
        token.transferIPShareOwner(address(0));
    }

    function test_transferIPShareOwner_revertsSameSubject() public onlyReady {
        vm.prank(creator, creator);
        vm.expectRevert(IToken.IPShareAlreadySet.selector);
        token.transferIPShareOwner(creator);
    }

    function test_transferIPShareOwner_revertsIfIPShareNotCreated() public onlyReady {
        vm.prank(creator, creator);
        vm.expectRevert(IToken.IPShareNotCreated.selector);
        token.transferIPShareOwner(makeAddr("noShare"));
    }

    function test_transferIPShareOwner_canTransferTwice() public onlyReady {
        address subjectA = makeAddr("subjectA");
        address subjectB = makeAddr("subjectB");
        vm.deal(subjectA, 1 ether);
        vm.deal(subjectB, 1 ether);

        vm.prank(subjectA, subjectA);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(subjectA);
        vm.prank(subjectB, subjectB);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(subjectB);

        vm.prank(creator, creator);
        token.transferIPShareOwner(subjectA);
        vm.prank(subjectA, subjectA);
        token.transferIPShareOwner(subjectB);
        assertEq(token.ipshareSubject(), subjectB);
    }

    function test_NUTBOX_ALLOCATION_isFifteenPercent() public onlyReady {
        assertEq(token.NUTBOX_ALLOCATION(), 150_000_000 ether);
    }

    // ── P1T2: anti-snipe 边界与禁窗上市 ───────────────────────────────────────────

    function test_publicFirstBuy_paysAntiSnipeFee() public onlyReady {
        // 窗口内公开第一笔买入：sellsman 费率高于稳态 feeRatio[1]
        (uint256 tip, uint256 sellsman) = token.getBuyFeeRatios();
        uint256[2] memory ratio = pump.getFeeRatio();
        assertEq(tip, ratio[0]);
        assertGt(sellsman, ratio[1]);
    }

    function test_pumpPremineUsesNormalFee() public onlyReady {
        // Pump 捆绑预购走普通 feeRatio：创建时附带超过 fixedFee 的 ETH，预购到账量应与净买入一致。
        uint256 totalFixedFee = pump.createFee();
        uint256 premineEth = 0.05 ether;
        vm.deal(creator, premineEth + totalFixedFee + 1 ether);
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: totalFixedFee + premineEth}(
            "PREMINE",
            keccak256("premine")
        );
        Token t = Token(payable(tokenAddr));
        // 预购按 feeRatio[0]/feeRatio[1] 扣费；sellsmanFee 在窗口内走 valueCapture（community 未绑定）
        uint256 netBuy = premineEth - (premineEth * pump.getFeeRatio()[0]) / 1e4 - (premineEth * pump.getFeeRatio()[1]) / 1e4;
        uint256 expectedTokens = IBondingCurve(address(pump)).getBuyAmountByValue(0, netBuy);
        assertEq(IERC20(tokenAddr).balanceOf(creator), expectedTokens);
    }

    function test_listingDisabledDuringAntiSnipeWindow() public onlyReady {
        // 窗口内把曲线买满应 revert ListingDisabledDuringAntiSnipe，而不是上市
        vm.deal(buyer, 100_000 ether);
        vm.prank(buyer, buyer);
        vm.expectRevert(IToken.ListingDisabledDuringAntiSnipe.selector);
        token.buyToken{value: 90_000 ether}(0, creator, 0);
    }
}
