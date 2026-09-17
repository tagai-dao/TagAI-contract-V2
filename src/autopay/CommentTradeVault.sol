// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ICommentBuyAdapter {
    function outputFeeBps(address token) external view returns (uint256);
    function quoteInput(address token, uint256 principal) external view
        returns (uint256 gross, uint256 platformFee, uint256 subjectFee, uint256 buybackFee);
    function buy(address token, address recipient, address subject, uint256 minimum, uint256 deadline, bytes calldata route)
        external payable returns (uint256);
}

/// @notice Separate, opt-in BNB trading custody. Never spends CoinPurse tipping deposits.
/// @dev Executor is trusted to authenticate X replies and quote/risk-check orders. Users authorize
/// that executor explicitly; it cannot change recipient, exceed limits, or call arbitrary targets.
/// Must be independently audited before funding. Deploy only on BSC in production.
contract CommentTradeVault is ReentrancyGuard {
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
        uint16 maxPlatformBps;
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
    }

    address public immutable admin;
    address public immutable executor;
    address public immutable feeReceiver;
    ICommentBuyAdapter public immutable adapter;
    bool public paused = true;
    mapping(address => uint256) public principalBalance;
    mapping(address => uint256) public feeBalance;
    mapping(address => Grant) public grants;
    mapping(bytes32 => bool) public executed;
    mapping(address => bool) public allowedTokens;

    error Invalid();
    error Unauthorized();
    error Limit();
    error Delivery();
    error TransferFailed();
    event Authorization(address indexed user, uint256 version, bool enabled);
    event Funded(address indexed user, uint256 principal, uint256 fees);
    event Withdrawn(address indexed user, uint256 principal, uint256 fees);
    event Settled(bytes32 indexed id, address indexed user, address indexed token, uint256 principal,
        uint256 platformFee, uint256 executionFee, uint256 received, address subject,
        uint256 routingFee, uint256 subjectFee, uint256 buybackFee, uint256 rounding);
    event OutputFeePolicy(bytes32 indexed id, uint256 bps);

    constructor(address executor_, address feeReceiver_, address adapter_) {
        if (executor_ == address(0) || feeReceiver_ == address(0) || adapter_.code.length == 0) revert Invalid();
        admin = msg.sender;
        executor = executor_;
        feeReceiver = feeReceiver_;
        adapter = ICommentBuyAdapter(adapter_);
    }

    function setPaused(bool value) external { if (msg.sender != admin) revert Unauthorized(); paused = value; }
    function setAllowedToken(address token, bool value) external {
        if (msg.sender != admin) revert Unauthorized();
        if (token.code.length == 0) revert Invalid();
        allowedTokens[token] = value;
    }

    /// @notice Limits are ALL-IN (principal + platform + execution), day resets at 00:00 UTC.
    /// Reauthorization never resets today's spend. Updating/revoking invalidates queued versions.
    function authorize(uint256 budget, uint256 perTrade, uint256 perDay, uint256 maxExecutionFee,
        uint16 maxPlatformBps, uint16 maxSlippageBps, uint256 expiresAt) external {
        if (budget == 0 || perTrade == 0 || perDay < perTrade || budget < perTrade ||
            maxPlatformBps > 1000 || maxSlippageBps > 1000 || expiresAt <= block.timestamp || expiresAt > block.timestamp + 90 days) revert Invalid();
        Grant storage g = grants[msg.sender];
        g.remaining = budget;
        g.perTrade = perTrade;
        g.perDay = perDay;
        g.maxExecutionFee = maxExecutionFee;
        g.maxPlatformBps = maxPlatformBps;
        g.maxSlippageBps = maxSlippageBps;
        g.expiresAt = expiresAt;
        g.startsAt = block.timestamp;
        g.enabled = true;
        ++g.version;
        emit Authorization(msg.sender, g.version, true);
    }

    function revoke() external {
        Grant storage g = grants[msg.sender];
        g.enabled = false;
        ++g.version;
        emit Authorization(msg.sender, g.version, false);
    }

    function deposit(uint256 fees) external payable {
        if (msg.value == 0 || fees > msg.value) revert Invalid();
        principalBalance[msg.sender] += msg.value - fees;
        feeBalance[msg.sender] += fees;
        emit Funded(msg.sender, msg.value - fees, fees);
    }

    /// Withdraw remains possible while paused or revoked; no administrator withdrawal.
    function withdraw(uint256 principal, uint256 fees) external nonReentrant {
        principalBalance[msg.sender] -= principal;
        feeBalance[msg.sender] -= fees;
        _send(msg.sender, principal + fees);
        emit Withdrawn(msg.sender, principal, fees);
    }

    function execute(Order calldata o, bytes calldata route) external nonReentrant returns (uint256 received) {
        if (msg.sender != executor) revert Unauthorized();
        if (paused || executed[o.id] || o.id == bytes32(0) || !allowedTokens[o.token] || o.principal == 0 ||
            o.minimumOut == 0 || o.deadline < block.timestamp || o.deadline > block.timestamp + 120) revert Invalid();
        Grant storage g = grants[o.user];
        (uint256 gross, uint256 routePlatform, uint256 subjectFee, uint256 buybackFee) = adapter.quoteInput(o.token, o.principal);
        uint256 outputBps = adapter.outputFeeBps(o.token);
        // Conservative BNB-equivalent check ONLY; the output fee is not debited again.
        uint256 outputFeeCapCharge = (o.principal * outputBps + 9999) / 10000;
        if (gross != o.principal + o.routingFee) revert Invalid();
        uint256 total = gross + o.platformFee + o.executionFee;
        uint256 day = block.timestamp / 1 days;
        if (g.day != day) { g.day = day; g.spentDay = 0; }
        if (!g.enabled || g.expiresAt < block.timestamp || g.version != o.grantVersion ||
            o.quotedOut == 0 || o.minimumOut < (o.quotedOut * (10000 - g.maxSlippageBps) + 9999) / 10000 ||
            total > g.remaining || total > g.perTrade || total + g.spentDay > g.perDay ||
            o.executionFee > g.maxExecutionFee || o.platformFee + o.routingFee + outputFeeCapCharge > o.principal * g.maxPlatformBps / 10000 ||
            o.principal > principalBalance[o.user] || o.platformFee + o.routingFee + o.executionFee > feeBalance[o.user]) revert Limit();
        executed[o.id] = true;
        g.remaining -= total;
        g.spentDay += total;
        principalBalance[o.user] -= o.principal;
        feeBalance[o.user] -= o.platformFee + o.routingFee + o.executionFee;
        uint256 beforeBalance = IERC20(o.token).balanceOf(o.user);
        adapter.buy{value: gross}(o.token, o.user, o.subject, o.minimumOut, o.deadline, route);
        received = IERC20(o.token).balanceOf(o.user) - beforeBalance;
        if (received < o.minimumOut) revert Delivery();
        _send(feeReceiver, o.platformFee);
        _send(executor, o.executionFee);
        emit Settled(o.id, o.user, o.token, o.principal, o.platformFee, o.executionFee, received, o.subject,
            o.routingFee, subjectFee, buybackFee, o.routingFee - routePlatform - subjectFee - buybackFee);
        emit OutputFeePolicy(o.id, outputBps);
    }

    function _send(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
