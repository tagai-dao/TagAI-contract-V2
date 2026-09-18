// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ICommentBuyAdapter {
    function outputFeeBps(address token, uint8 kind) external view returns (uint256);
    function quoteInput(address token, uint256 principal, uint8 kind) external view
        returns (uint256 gross, uint256 platformFee, uint256 subjectFee, uint256 buybackFee);
    function buy(address token, address recipient, address subject, uint256 minimum, uint256 deadline, uint8 kind, bytes calldata route)
        external payable returns (uint256);
}

/// @notice Separate, opt-in BNB trading custody. Never spends CoinPurse tipping deposits.
/// @dev Executor authenticates X replies, picks the trade kind off-chain, and quote/risk-checks
/// orders. User grants authorize the owner-managed executor role; rotation preserves grants and
/// their limits. The executor cannot change recipient or exceed limits. Kind is not re-derived
/// on-chain. Deploy only on BSC in production.
contract CommentTradeVault is ReentrancyGuard, Ownable2Step {
    struct Grant {
        uint256 remaining;
        uint256 perTrade;
        uint256 perDay;
        uint256 maxExecutionFee;
        uint256 expiresAt;
        uint256 version;
        uint256 startsAt;
        uint256 spentDay;
        uint256 day;
        uint16 maxSlippageBps;
        bool enabled;
    }

    struct Order {
        bytes32 id; // keccak256("tagai:x:buy:" + immutable X reply ID), globally unique
        address user; // verified wallet; also immutable recipient
        address token;
        address subject;
        uint256 principal;
        uint256 platformFee;
        uint256 executionFee;
        uint256 minimumOut;
        uint256 deadline;
        uint256 grantVersion;
        uint256 quotedOut;
        uint256 routingFee;
        uint8 kind; // executor-selected: 0 inner, 1 V13 main pool, 2 imported/external router
    }

    uint256 public constant MAX_TRADE_INTERVAL = 1 hours; // cap on owner-set cooldown, not the default
    // Safety ceiling, NOT a charged rate. Fixed execution fees are checked separately.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 300;

    address public executor;
    address public immutable feeReceiver;
    ICommentBuyAdapter public adapter;
    bool public paused = false;
    uint256 public minTradeInterval = 30;
    /// @notice One BNB balance pays buy principal and every separately charged fee.
    mapping(address => uint256) public balanceOf;
    mapping(address => Grant) public grants;
    mapping(bytes32 => bool) public executed;
    mapping(address => uint256) public lastTradeAt;

    error Invalid();
    error Unauthorized();
    error Limit();
    error Delivery();
    error TransferFailed();
    event Authorization(address indexed user, uint256 version, bool enabled);
    event Funded(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event TradeIntervalSet(uint256 seconds_);
    event AdapterSet(address indexed adapter);
    event ExecutorSet(address indexed previousExecutor, address indexed newExecutor);
    event Settled(bytes32 indexed id, address indexed user, address indexed token, uint256 principal,
        uint256 platformFee, uint256 executionFee, uint256 received, address subject,
        uint256 routingFee, uint256 subjectFee, uint256 buybackFee, uint256 rounding);
    event OutputFeePolicy(bytes32 indexed id, uint256 bps);

    constructor(address executor_, address feeReceiver_, address adapter_) {
        if (executor_ == address(0) || feeReceiver_ == address(0) || adapter_.code.length == 0) revert Invalid();
        executor = executor_;
        feeReceiver = feeReceiver_;
        adapter = ICommentBuyAdapter(adapter_);
        emit ExecutorSet(address(0), executor_);
        emit AdapterSet(adapter_);
    }

    function setPaused(bool value) external onlyOwner { paused = value; }

    /// @notice Version 2 uses unified balances and a six-argument payable authorize.
    function vaultVersion() external pure returns (uint256) { return 2; }

    /// @notice Rotate the keeper without resetting user grants or spending limits.
    function setExecutor(address executor_) external onlyOwner nonReentrant {
        if (executor_ == address(0)) revert Invalid();
        address previousExecutor = executor;
        executor = executor_;
        emit ExecutorSet(previousExecutor, executor_);
    }

    function setAdapter(address adapter_) external onlyOwner {
        if (adapter_.code.length == 0) revert Invalid();
        adapter = ICommentBuyAdapter(adapter_);
        emit AdapterSet(adapter_);
    }

    function setMinTradeInterval(uint256 seconds_) external onlyOwner {
        if (seconds_ > MAX_TRADE_INTERVAL) revert Invalid();
        minTradeInterval = seconds_;
        emit TradeIntervalSet(seconds_);
    }

    /// @notice Limits are ALL-IN (principal + routing + platform + execution), day resets at 00:00 UTC.
    /// Reauthorization never resets today's spend. Updating/revoking invalidates queued versions.
    /// Optional `msg.value` funds the unified balance in the same transaction as the grant.
    /// Use deposit() instead to preserve an existing grant, expiry and remaining budget exactly.
    function authorize(uint256 budget, uint256 perTrade, uint256 perDay, uint256 maxExecutionFee,
        uint16 maxSlippageBps, uint256 expiresAt) external payable nonReentrant {
        if (budget == 0 || perTrade == 0 || perDay < perTrade || budget < perTrade ||
            maxSlippageBps > 1000 || expiresAt <= block.timestamp || expiresAt > block.timestamp + 90 days) revert Invalid();
        if (msg.value > 0) _credit(msg.value);
        Grant storage g = grants[msg.sender];
        g.remaining = budget;
        g.perTrade = perTrade;
        g.perDay = perDay;
        g.maxExecutionFee = maxExecutionFee;
        g.maxSlippageBps = maxSlippageBps;
        g.expiresAt = expiresAt;
        g.startsAt = block.timestamp;
        g.enabled = true;
        ++g.version;
        emit Authorization(msg.sender, g.version, true);
    }

    function revoke() external nonReentrant {
        Grant storage g = grants[msg.sender];
        g.enabled = false;
        ++g.version;
        emit Authorization(msg.sender, g.version, false);
    }

    function deposit() external payable nonReentrant {
        _credit(msg.value);
    }

    /// Withdraw remains possible while paused or revoked; no administrator withdrawal.
    function withdraw(uint256 amount) external nonReentrant {
        balanceOf[msg.sender] -= amount;
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function execute(Order calldata o, bytes calldata route) external nonReentrant returns (uint256 received) {
        if (msg.sender != executor) revert Unauthorized();
        if (paused || executed[o.id] || o.id == bytes32(0) || o.token.code.length == 0 || o.principal == 0 ||
            o.minimumOut == 0 || o.deadline < block.timestamp || o.deadline > block.timestamp + 120) revert Invalid();
        Grant storage g = grants[o.user];
        (uint256 gross, uint256 routePlatform, uint256 subjectFee, uint256 buybackFee) = adapter.quoteInput(o.token, o.principal, o.kind);
        uint256 outputBps = adapter.outputFeeBps(o.token, o.kind);
        // Conservative BNB-equivalent check ONLY; the output fee is not debited again.
        uint256 outputFeeCapCharge = (o.principal * outputBps + 9999) / 10000;
        if (gross != o.principal + o.routingFee) revert Invalid();
        uint256 total = gross + o.platformFee + o.executionFee;
        uint256 day = block.timestamp / 1 days;
        if (g.day != day) { g.day = day; g.spentDay = 0; }
        if (!g.enabled || g.expiresAt < block.timestamp || g.version != o.grantVersion ||
            o.quotedOut == 0 || o.minimumOut < (o.quotedOut * (10000 - g.maxSlippageBps) + 9999) / 10000 ||
            total > g.remaining || total > g.perTrade || total + g.spentDay > g.perDay ||
            o.executionFee > g.maxExecutionFee || o.platformFee + o.routingFee + outputFeeCapCharge > o.principal * MAX_PROTOCOL_FEE_BPS / 10000 ||
            total > balanceOf[o.user] ||
            block.timestamp < lastTradeAt[o.user] + minTradeInterval) revert Limit();
        executed[o.id] = true;
        g.remaining -= total;
        g.spentDay += total;
        balanceOf[o.user] -= total;
        uint256 beforeBalance = IERC20(o.token).balanceOf(o.user);
        adapter.buy{value: gross}(o.token, o.user, o.subject, o.minimumOut, o.deadline, o.kind, route);
        received = IERC20(o.token).balanceOf(o.user) - beforeBalance;
        if (received < o.minimumOut) revert Delivery();
        lastTradeAt[o.user] = block.timestamp;
        _send(feeReceiver, o.platformFee);
        _send(executor, o.executionFee);
        emit Settled(o.id, o.user, o.token, o.principal, o.platformFee, o.executionFee, received, o.subject,
            o.routingFee, subjectFee, buybackFee, o.routingFee - routePlatform - subjectFee - buybackFee);
        emit OutputFeePolicy(o.id, outputBps);
    }

    function _credit(uint256 value) private {
        if (value == 0) revert Invalid();
        balanceOf[msg.sender] += value;
        emit Funded(msg.sender, value);
    }

    function _send(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
