// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommentTradeVault, ICommentBuyAdapter} from "../../src/helper/CommentTradeVault.sol";

contract CommentTestToken is ERC20 {
    constructor() ERC20("test", "T") {}
    function mint(address to, uint256 value) external { _mint(to, value); }
}
contract CommentTestAdapter is ICommentBuyAdapter {
    uint256 public outputBps;
    function setOutputBps(uint256 value) external { outputBps = value; }
    function outputFeeBps(address, uint8) external view returns (uint256) { return outputBps; }
    uint256 public output = 100;
    uint256 public routeFee;
    function setOutput(uint256 v) external { output = v; }
    function setRouteFee(uint256 v) external { routeFee = v; }
    function quoteInput(address, uint256 principal, uint8) external view returns (uint256, uint256, uint256, uint256) {
        return (principal + routeFee, routeFee, 0, 0);
    }
    function buy(address token, address to, address, uint256, uint256, uint8, bytes calldata) external payable returns (uint256) {
        CommentTestToken(token).mint(to, output);
        return output;
    }
}
contract CommentReentrantUser {
    CommentTradeVault public vault;
    bool public blocked;
    constructor(CommentTradeVault vault_) { vault = vault_; }
    function fundAndWithdraw() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw(msg.value);
    }
    receive() external payable {
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeWithSignature(
            "authorize(uint256,uint256,uint256,uint256,uint16,uint256)",
            1, 1, 1, 0, 0, block.timestamp + 1 days));
        blocked = !ok && keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
    }
}
contract CommentTradeVaultTest is Test {
    CommentTradeVault vault;
    CommentTestAdapter adapter;
    CommentTestToken token;
    address user = address(0x123);
    address executor = address(0x456);
    address fees = address(0x789);
    function setUp() public {
        vm.warp(10 days);
        adapter = new CommentTestAdapter();
        token = new CommentTestToken();
        vault = new CommentTradeVault(executor, fees, address(adapter));
        vault.setPaused(false);
        vm.deal(user, 5 ether);
        // Keep accounting fixtures independent of pre-existing balances on a fork.
        vm.deal(executor, 0);
        vm.deal(fees, 0);
        vm.startPrank(user);
        vault.authorize{value: 2 ether}(2 ether, 0.2 ether, 0.3 ether, 0.001 ether, 100, block.timestamp + 1 days);
        vm.stopPrank();
    }
    function order(uint256 id) internal view returns (CommentTradeVault.Order memory) {
        return CommentTradeVault.Order(bytes32(id), user, address(token), address(0), 0.1 ether,
            0.001 ether, 0.001 ether, 100, block.timestamp + 60, 1, 100, 0, 0);
    }
    function execute(uint256 id) internal { vm.prank(executor); vault.execute(order(id), ""); }
    function testSuccessAndReplay() public {
        execute(1);
        assertEq(token.balanceOf(user), 100);
        assertEq(vault.balanceOf(user), 1.898 ether);
        assertEq(fees.balance, 0.001 ether);
        assertEq(executor.balance, 0.001 ether);
        vm.expectRevert(CommentTradeVault.Invalid.selector); execute(1);
    }
    function testOutputProtocolFeeCountsTowardsCapWithoutSecondDebit() public {
        assertEq(vault.MAX_PROTOCOL_FEE_BPS(), 300);
        adapter.setOutputBps(201); // 2.01% output + 1% platform exceeds the fixed 3% ceiling.
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
        adapter.setOutputBps(200); // Exactly 3% passes; no user-supplied cap.
        execute(1);
        assertEq(vault.balanceOf(user), 1.898 ether); // output fee is not debited again in BNB
    }
    function testRevertedDeliveryRollsBackEverything() public {
        adapter.setOutput(99);
        vm.expectRevert(CommentTradeVault.Delivery.selector); execute(1);
        assertFalse(vault.executed(bytes32(uint256(1))));
        assertEq(vault.balanceOf(user), 2 ether);
        assertEq(token.balanceOf(user), 0);
        assertEq(fees.balance, 0);
        assertEq(vault.lastTradeAt(user), 0);
    }
    function testDailyLimitIncludesFeesAndReauthorizationDoesNotReset() public {
        execute(1);
        vm.warp(block.timestamp + 30);
        execute(2);
        vm.prank(user);
        vault.authorize(2 ether, 0.2 ether, 0.3 ether, 0.001 ether, 100, block.timestamp + 1 days);
        CommentTradeVault.Order memory o = order(3); o.grantVersion = 2;
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CommentTradeVault.Limit.selector);
        vm.prank(executor); vault.execute(o, "");
    }
    function testRevokeAndWithdrawalWhilePaused() public {
        vm.prank(user); vault.revoke();
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
        vault.setPaused(true);
        vm.prank(user); vault.withdraw(2 ether);
        assertEq(user.balance, 5 ether);
    }
    function testSingleBalanceCoversPrincipalAndFees() public {
        vm.prank(user); vault.withdraw(1.898 ether);
        execute(1);
        assertEq(vault.balanceOf(user), 0);
        assertEq(executor.balance, 0.001 ether);
    }
    function testInsufficientTotalBalanceReverts() public {
        vm.prank(user); vault.withdraw(1.898 ether + 1);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
        assertEq(vault.balanceOf(user), 0.102 ether - 1);
        assertFalse(vault.executed(bytes32(uint256(1))));
    }
    function testOnlyExecutorCanExecute() public {
        vm.expectRevert(CommentTradeVault.Unauthorized.selector); vault.execute(order(1), "");
    }
    function testOnlyOwnerCanSetNonzeroExecutor() public {
        address next = makeAddr("next-executor");
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setExecutor(next);
        vm.prank(executor);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setExecutor(next);
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.setExecutor(address(0));
        assertEq(vault.executor(), executor);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CommentTradeVault.ExecutorSet(executor, next);
        vault.setExecutor(next);
        assertEq(vault.executor(), next);
    }
    function testExecutorRotationPreservesLimitsAndPaysNewKeeper() public {
        execute(1);
        address next = makeAddr("next-executor");
        vm.deal(next, 0);
        vault.setExecutor(next);
        vm.expectRevert(CommentTradeVault.Unauthorized.selector);
        execute(2);

        vm.startPrank(next);
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.execute(order(1), "");
        vm.expectRevert(CommentTradeVault.Limit.selector);
        vault.execute(order(2), "");
        vm.warp(block.timestamp + 30);
        vault.execute(order(2), "");
        assertEq(token.balanceOf(user), 200);
        assertEq(executor.balance, 0.001 ether);
        assertEq(next.balance, 0.001 ether);
        assertEq(vault.balanceOf(user), 1.796 ether);
        (uint256 remaining,,,,, uint256 version,, uint256 spentDay,,,) = vault.grants(user);
        assertEq(remaining, 1.796 ether);
        assertEq(version, 1);
        assertEq(spentDay, 0.204 ether);
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CommentTradeVault.Limit.selector);
        vault.execute(order(3), "");
        vm.stopPrank();
    }
    function testStaleGrantDeadlineAndFeeCap() public {
        CommentTradeVault.Order memory o = order(1);
        o.executionFee = 0.002 ether;
        vm.expectRevert(CommentTradeVault.Limit.selector); vm.prank(executor); vault.execute(o, "");
        o = order(1); o.grantVersion = 2;
        vm.expectRevert(CommentTradeVault.Limit.selector); vm.prank(executor); vault.execute(o, "");
        o = order(1); o.deadline = block.timestamp - 1;
        vm.expectRevert(CommentTradeVault.Invalid.selector); vm.prank(executor); vault.execute(o, "");
    }
    function testEmbeddedFeesUseUnifiedBalanceAndCannotBeDoubleCharged() public {
        adapter.setRouteFee(0.0025 ether);
        CommentTradeVault.Order memory o = order(1);
        o.routingFee = 0.0025 ether;
        // Combined protocol + additional platform fee exceeds the fixed 3% ceiling.
        vm.expectRevert(CommentTradeVault.Limit.selector); vm.prank(executor); vault.execute(o, "");
        o.platformFee = 0;
        vm.prank(executor); vault.execute(o, "");
        assertEq(vault.balanceOf(user), 1.8965 ether);
        assertEq(address(adapter).balance, 0.1025 ether);
        assertEq(fees.balance, 0);
    }
    function testTradeIntervalPerUser() public {
        execute(1);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(2);
        vm.warp(block.timestamp + 29);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(2);
        vm.warp(block.timestamp + 1);
        execute(2);
        assertEq(vault.lastTradeAt(user), block.timestamp);
        vm.prank(user);
        vault.authorize(2 ether, 0.2 ether, 1 ether, 0.001 ether, 100, block.timestamp + 1 days);
        vault.setMinTradeInterval(0);
        CommentTradeVault.Order memory o = order(3); o.grantVersion = 2;
        vm.prank(executor); vault.execute(o, "");
    }
    function testOwnerSetsTradeInterval() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setMinTradeInterval(10);
        vault.setMinTradeInterval(3600);
        assertEq(vault.minTradeInterval(), 3600);
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.setMinTradeInterval(3601);
    }
    function testOwnerSetsAdapter() public {
        CommentTestAdapter next = new CommentTestAdapter();
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAdapter(address(next));
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.setAdapter(address(0x123));
        vault.setAdapter(address(next));
        assertEq(address(vault.adapter()), address(next));
    }
    function testAuthorizeFundsAndSetsGrantInOneTx() public {
        address other = address(0xabc);
        vm.deal(other, 1 ether);
        vm.prank(other);
        vault.authorize{value: 0.5 ether}(0.4 ether, 0.1 ether, 0.2 ether, 0, 500, block.timestamp + 1 days);
        assertEq(vault.balanceOf(other), 0.5 ether);
        (uint256 remaining,,,,,,,,,, bool enabled) = vault.grants(other);
        assertEq(remaining, 0.4 ether);
        assertTrue(enabled);
        vm.prank(other);
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.authorize{value: 0.1 ether}(0.4 ether, 0.3 ether, 0.2 ether, 0, 500, block.timestamp + 1 days);
        assertEq(vault.balanceOf(other), 0.5 ether); // invalid authorization rolls back the deposit too
    }
    function testDepositPreservesGrantExactlyIncludingDailySpend() public {
        execute(1);
        (bool ok, bytes memory beforeGrant) = address(vault).staticcall(abi.encodeWithSignature("grants(address)", user));
        assertTrue(ok);
        vm.prank(user); vault.deposit{value: 0.2 ether}();
        (, bytes memory afterGrant) = address(vault).staticcall(abi.encodeWithSignature("grants(address)", user));
        assertEq(beforeGrant, afterGrant);
        assertEq(vault.balanceOf(user), 2.098 ether);
        assertEq(vault.vaultVersion(), 2);
    }
    function testWithdrawalCannotReenterAuthorization() public {
        CommentReentrantUser receiver = new CommentReentrantUser(vault);
        vm.deal(address(this), 1 ether);
        receiver.fundAndWithdraw{value: 1 ether}();
        assertTrue(receiver.blocked());
        assertEq(address(receiver).balance, 1 ether);
        assertEq(vault.balanceOf(address(receiver)), 0);
        assertEq(vault.balanceOf(user), 2 ether);
    }
    function testZeroDepositAndOtherUserWithdrawalAreRejected() public {
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.deposit();
        vm.prank(address(0xbeef));
        vm.expectRevert();
        vault.withdraw(1);
        assertEq(vault.balanceOf(user), 2 ether);
    }
    function testCombinedUpdateKeepsDailySpendAndInvalidatesOldOrder() public {
        execute(1);
        vm.prank(user);
        vault.authorize{value: 0.1 ether}(1 ether, 0.2 ether, 0.3 ether, 0.001 ether, 500, block.timestamp + 7 days);
        (uint256 remaining,,,,, uint256 version,, uint256 spentDay,,,) = vault.grants(user);
        assertEq(remaining, 1 ether);
        assertEq(version, 2);
        assertEq(spentDay, 0.102 ether);
        assertEq(vault.balanceOf(user), 1.998 ether);
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(2);
    }
}
