// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPump} from "../interfaces/IPump.sol";
import {INutboxRouter} from "./INutboxRouter.sol";

interface IBuybackToken {
    function listingHook() external view returns (address);
    function indexToken() external view returns (address);
}

interface IBuybackBasketRouter {
    function settlementToken() external view returns (address);
    function buyExactSettlement(address basket, uint256 amount, uint256 minimum, bytes calldata data, address recipient)
        external
        returns (uint256);
}

/// @notice Converts a registered Token's Hook reserve into its index rewards.
/// @dev Anyone may trigger Hook.executeBuyback; only that Token's snapshotted Hook
/// can call this adapter and receive the output. No caller-supplied target or path.
contract TagAIBuybackRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error InvalidToken();
    error Unauthorized();
    error DeadlineExpired();
    error InvalidAmount();
    error SettlementSlippage();
    error IndexSlippage();
    error UnexpectedSettlementBalance();

    IPump public immutable pump;
    INutboxRouter public immutable nutboxRouter;
    IBuybackBasketRouter public immutable basketRouter;
    IERC20 public immutable settlementToken;

    constructor(address pump_, address nutboxRouter_, address basketRouter_, address settlementToken_) {
        if (
            pump_.code.length == 0 || nutboxRouter_.code.length == 0 || basketRouter_.code.length == 0
                || settlementToken_.code.length == 0
        ) revert InvalidConfiguration();
        if (IBuybackBasketRouter(basketRouter_).settlementToken() != settlementToken_) revert InvalidConfiguration();
        pump = IPump(pump_);
        nutboxRouter = INutboxRouter(nutboxRouter_);
        basketRouter = IBuybackBasketRouter(basketRouter_);
        settlementToken = IERC20(settlementToken_);
    }

    /// @param data abi.encode(uint256 minSettlementOut, bytes basketTradeData).
    /// Both conversion stages require explicit nonzero minimums. Basket trade data
    /// is forwarded unchanged, including first-mint per-leg bounds.
    function buyIndexWithBnb(
        address token,
        address indexToken,
        uint256 minIndexOut,
        uint256 deadline,
        bytes calldata data,
        address recipient
    ) external payable nonReentrant returns (uint256 indexOut) {
        if (
            indexToken == address(0) || pump.indexTokenOf(token) != indexToken
                || IBuybackToken(token).indexToken() != indexToken
        ) revert InvalidToken();
        if (msg.sender != IBuybackToken(token).listingHook() || recipient != msg.sender) revert Unauthorized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        (uint256 minSettlementOut, bytes memory basketData) = abi.decode(data, (uint256, bytes));
        if (msg.value == 0 || minIndexOut == 0 || minSettlementOut == 0) revert InvalidAmount();

        uint256 settlementBefore = settlementToken.balanceOf(address(this));
        nutboxRouter.swapExactInput{value: msg.value}(
            address(0), address(settlementToken), msg.value, minSettlementOut, address(this), deadline
        );
        uint256 received = settlementToken.balanceOf(address(this)) - settlementBefore;
        if (received < minSettlementOut) revert SettlementSlippage();
        // Spend this call's proceeds only; unsolicited balances never subsidize a buyback.
        settlementToken.safeApprove(address(basketRouter), 0);
        settlementToken.safeApprove(address(basketRouter), received);
        uint256 indexBefore = IERC20(indexToken).balanceOf(recipient);
        basketRouter.buyExactSettlement(indexToken, received, minIndexOut, basketData, recipient);
        indexOut = IERC20(indexToken).balanceOf(recipient) - indexBefore;
        if (indexOut < minIndexOut) revert IndexSlippage();
        settlementToken.safeApprove(address(basketRouter), 0);
        if (settlementToken.balanceOf(address(this)) != settlementBefore) revert UnexpectedSettlementBalance();
    }
}
