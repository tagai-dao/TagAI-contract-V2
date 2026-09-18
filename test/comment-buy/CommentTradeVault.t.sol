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
        vault.deposit{value: 2 ether}(0.1 ether);
        vault.authorize(2 ether, 0.2 ether, 0.3 ether, 0.001 ether, 100, 100, block.timestamp + 1 days, 0);
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
        assertEq(vault.principalBalance(user), 1.8 ether);
        assertEq(vault.feeBalance(user), 0.098 ether);
        assertEq(fees.balance, 0.001 ether);
        assertEq(executor.balance, 0.001 ether);
        vm.expectRevert(CommentTradeVault.Invalid.selector); execute(1);
    }
    function testOutputProtocolFeeCountsTowardsCapWithoutSecondDebit() public {
        adapter.setOutputBps(20);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
        vm.prank(user);
        vault.authorize(2 ether, 0.2 ether, 0.3 ether, 0.001 ether, 120, 100, block.timestamp + 1 days, 0);
        CommentTradeVault.Order memory o = order(1); o.grantVersion = 2;
        vm.prank(executor); vault.execute(o, "");
        assertEq(vault.feeBalance(user), 0.098 ether); // still only BNB platform + execution
    }
    function testRevertedDeliveryRollsBackEverything() public {
        adapter.setOutput(99);
        vm.expectRevert(CommentTradeVault.Delivery.selector); execute(1);
        assertFalse(vault.executed(bytes32(uint256(1))));
        assertEq(vault.principalBalance(user), 1.9 ether);
        assertEq(vault.feeBalance(user), 0.1 ether);
        assertEq(token.balanceOf(user), 0);
        assertEq(fees.balance, 0);
        assertEq(vault.lastTradeAt(user), 0);
    }
    function testDailyLimitIncludesFeesAndReauthorizationDoesNotReset() public {
        execute(1);
        vm.warp(block.timestamp + 30);
        execute(2);
        vm.prank(user);
        vault.authorize(2 ether, 0.2 ether, 0.3 ether, 0.001 ether, 100, 100, block.timestamp + 1 days, 0);
        CommentTradeVault.Order memory o = order(3); o.grantVersion = 2;
        vm.warp(block.timestamp + 30);
        vm.expectRevert(CommentTradeVault.Limit.selector);
        vm.prank(executor); vault.execute(o, "");
    }
    function testRevokeAndWithdrawalWhilePaused() public {
        vm.prank(user); vault.revoke();
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
        vault.setPaused(true);
        vm.prank(user); vault.withdraw(1.9 ether, 0.1 ether);
        assertEq(user.balance, 5 ether);
    }
    function testFeesCannotUsePrincipalBalance() public {
        vm.prank(user); vault.withdraw(0, 0.1 ether);
        vm.expectRevert(CommentTradeVault.Limit.selector); execute(1);
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
        assertEq(vault.principalBalance(user), 1.7 ether);
        assertEq(vault.feeBalance(user), 0.096 ether);
        (uint256 remaining,,,,, uint256 version,, uint256 spentDay,,,,) = vault.grants(user);
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
    function testEmbeddedFeesUseFeeBalanceAndCannotBeDoubleCharged() public {
        adapter.setRouteFee(0.0005 ether);
        CommentTradeVault.Order memory o = order(1);
        o.routingFee = 0.0005 ether;
        // Combined protocol + additional platform fee exceeds 1% authorization.
        vm.expectRevert(CommentTradeVault.Limit.selector); vm.prank(executor); vault.execute(o, "");
        o.platformFee = 0;
        vm.prank(executor); vault.execute(o, "");
        assertEq(vault.principalBalance(user), 1.8 ether);
        assertEq(vault.feeBalance(user), 0.0985 ether);
        assertEq(address(adapter).balance, 0.1005 ether);
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
        vault.authorize(2 ether, 0.2 ether, 1 ether, 0.001 ether, 100, 100, block.timestamp + 1 days, 0);
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
        vault.authorize{value: 0.5 ether}(0.4 ether, 0.1 ether, 0.2 ether, 0, 100, 100, block.timestamp + 1 days, 0.05 ether);
        assertEq(vault.principalBalance(other), 0.45 ether);
        assertEq(vault.feeBalance(other), 0.05 ether);
        (uint256 remaining,,,,,,,,,,, bool enabled) = vault.grants(other);
        assertEq(remaining, 0.4 ether);
        assertTrue(enabled);
        vm.prank(other);
        vm.expectRevert(CommentTradeVault.Invalid.selector);
        vault.authorize(0.4 ether, 0.1 ether, 0.2 ether, 0, 100, 100, block.timestamp + 1 days, 1);
    }
}
