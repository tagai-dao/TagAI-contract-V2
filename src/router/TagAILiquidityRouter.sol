// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {TagAITradeRouter, ITradeToken, ITradeFactory} from "./TagAITradeRouter.sol";
import {IPump} from "../interfaces/IPump.sol";
import {INutboxRouter} from "./INutboxRouter.sol";

interface ILiquidityPair is IERC20 {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address) external returns (uint256);
    function burn(address) external returns (uint256, uint256);
}

/// @notice Adds/removes component liquidity with actual LP/net-output limits.
/// @dev No staking on behalf of a user: minted LP is delivered to the payer.
/// No arbitrary calls, owner, custody or protocol fee. Existing stray balances are never spent.
contract TagAILiquidityRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPump public immutable pump;
    TagAITradeRouter public immutable tradeRouter;
    INutboxRouter public immutable nutboxRouter;
    address public immutable factory;
    error InvalidPool();
    error InvalidAmount();
    error Slippage();
    error Expired();
    error TransferFailed();
    event NativeRefund(address indexed user, uint256 amount);
    event DustRefund(address indexed user, address indexed asset, uint256 amount);
    event LiquidityAdded(address indexed token, address indexed pair, address indexed user, uint256 liquidity);
    event LiquidityRemoved(
        address indexed token, address indexed pair, address indexed user, uint256 tokenOut, uint256 assetOut
    );

    constructor(TagAITradeRouter trade_) {
        require(address(trade_).code.length != 0);
        tradeRouter = trade_;
        pump = trade_.pump();
        nutboxRouter = trade_.nutboxRouter();
        factory = trade_.pancakeV2Factory();
    }

    receive() external payable {
        if (msg.sender != address(tradeRouter) && msg.sender != address(nutboxRouter)) revert TransferFailed();
    }

    function _pool(address token, uint256 index, uint256 deadline)
        private
        view
        returns (address asset, ILiquidityPair pair)
    {
        if (block.timestamp > deadline) revert Expired();
        if (!pump.createdTokens(token) || !ITradeToken(token).listed() || index >= ITradeToken(token).componentCount())
        {
            revert InvalidPool();
        }
        address p;
        (asset,, p) = ITradeToken(token).componentAt(index);
        pair = ILiquidityPair(p);
        if (
            asset == token || p == address(0) || ITradeFactory(factory).getPair(token, asset) != p
                || pair.factory() != factory
        ) {
            revert InvalidPool();
        }
        address a = pair.token0();
        address b = pair.token1();
        if (!((a == token && b == asset) || (b == token && a == asset))) revert InvalidPool();
        (address router,,,) = ITradeToken(token).listingInfrastructure();
        if (router != address(nutboxRouter) || ITradeToken(token).pancakeV2Factory() != factory) revert InvalidPool();
    }

    function add(address token, uint256 index, uint256 tokenIn, uint256 assetIn, uint256 minLP, uint256 deadline)
        external
        nonReentrant
        returns (uint256 lp)
    {
        (address asset, ILiquidityPair pair) = _pool(token, index, deadline);
        if (tokenIn == 0 || assetIn == 0 || minLP == 0) revert InvalidAmount();
        uint256 t = IERC20(token).balanceOf(address(this));
        uint256 a = IERC20(asset).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenIn);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assetIn);
        lp = _mint(token, asset, pair, t, a, minLP);
        _refundAssets(token, asset, t, a);
    }

    struct Zap {
        address token;
        uint256 component;
        uint256 tokenBnb;
        uint256 minToken;
        uint256 minAsset;
        uint256 minLP;
        uint256 deadline;
        address subject;
        bytes32 mainRouteHash;
        bytes32 assetRouteHash;
        uint256 minTokenRefundRateX128;
        uint256 minAssetRefundRateX128;
    }

    function addWithBNB(Zap calldata z) external payable nonReentrant returns (uint256 lp) {
        (address asset, ILiquidityPair pair) = _pool(z.token, z.component, z.deadline);
        if (z.tokenBnb == 0 || z.tokenBnb >= msg.value || z.minToken == 0 || z.minAsset == 0 || z.minLP == 0) {
            revert InvalidAmount();
        }
        if (z.minTokenRefundRateX128 == 0 || z.minAssetRefundRateX128 == 0) revert InvalidAmount();
        if (tradeRouter.routeHash(address(0), asset) != z.assetRouteHash) revert InvalidPool();
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = TagAITradeRouter.Leg(0, z.tokenBnb, 0, z.minToken, z.mainRouteHash);
        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 t = IERC20(z.token).balanceOf(address(this));
        uint256 a = IERC20(asset).balanceOf(address(this));
        tradeRouter.buy{value: z.tokenBnb}(z.token, legs, z.minToken, z.deadline, address(this), z.subject);
        nutboxRouter.swapExactInput{value: msg.value - z.tokenBnb}(
            address(0), asset, msg.value - z.tokenBnb, z.minAsset, address(this), z.deadline
        );
        if (IERC20(asset).balanceOf(address(this)) - a < z.minAsset) revert Slippage();
        lp = _mint(z.token, asset, pair, t, a, z.minLP);
        _sellRemainder(z, z.token, t, true);
        _sellRemainder(z, asset, a, false);
        uint256 refund = address(this).balance - nativeBefore;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
        emit NativeRefund(msg.sender, refund);
    }

    /// @dev Rates protect actual remaining amounts, which can differ from the quote after reserve changes.
    function _sellRemainder(Zap calldata z, address asset, uint256 beforeBalance, bool isToken) private {
        uint256 amount = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        if (amount == 0) return;
        uint256 minimum = Math.mulDiv(amount, isToken ? z.minTokenRefundRateX128 : z.minAssetRefundRateX128, 1 << 128);
        // Sub-wei native output cannot pass a swap's nonzero output requirement.
        if (minimum == 0) {
            IERC20(asset).safeTransfer(msg.sender, amount);
            emit DustRefund(msg.sender, asset, amount);
            return;
        }
        uint256 nativeBefore = address(this).balance;
        if (isToken) {
            if (tradeRouter.routeHash(address(0), asset) != z.mainRouteHash) revert InvalidPool();
            TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
            legs[0] = TagAITradeRouter.Leg(0, amount, 0, minimum, tradeRouter.routeHash(asset, address(0)));
            IERC20(asset).forceApprove(address(tradeRouter), amount);
            tradeRouter.sell(asset, amount, legs, minimum, z.deadline, address(this), z.subject);
            IERC20(asset).forceApprove(address(tradeRouter), 0);
        } else {
            if (tradeRouter.routeHash(address(0), asset) != z.assetRouteHash) revert InvalidPool();
            IERC20(asset).forceApprove(address(nutboxRouter), amount);
            nutboxRouter.swapExactInput(asset, address(0), amount, minimum, address(this), z.deadline);
            IERC20(asset).forceApprove(address(nutboxRouter), 0);
        }
        if (address(this).balance - nativeBefore < minimum || IERC20(asset).balanceOf(address(this)) != beforeBalance) {
            revert Slippage();
        }
    }

    function _mint(address token, address asset, ILiquidityPair pair, uint256 beforeT, uint256 beforeA, uint256 minLP)
        private
        returns (uint256 lp)
    {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rt, uint256 ra) = pair.token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rt == 0 || ra == 0) revert InvalidPool(); // only seeded, listed component pairs
        uint256 gross = IERC20(token).balanceOf(address(this)) - beforeT;
        uint256 availableA = IERC20(asset).balanceOf(address(this)) - beforeA;
        uint256 net = gross - gross / 1000; // Token13 pair transfer tax, rounded exactly as the token
        uint256 desiredA = net * ra / rt;
        if (desiredA > availableA) {
            desiredA = availableA;
            net = desiredA * rt / ra;
            if (net == 0) revert InvalidAmount();
            gross = net + (net - 1) / 999;
        }
        if (gross == 0 || desiredA == 0) revert InvalidAmount();
        IERC20(token).safeTransfer(address(pair), gross);
        IERC20(asset).safeTransfer(address(pair), desiredA);
        uint256 beforeLP = pair.balanceOf(msg.sender);
        pair.mint(msg.sender);
        lp = pair.balanceOf(msg.sender) - beforeLP;
        if (lp < minLP) revert Slippage();
        emit LiquidityAdded(token, address(pair), msg.sender, lp);
    }

    function _refundAssets(address token, address asset, uint256 beforeT, uint256 beforeA) private {
        uint256 remainT = IERC20(token).balanceOf(address(this)) - beforeT;
        uint256 remainA = IERC20(asset).balanceOf(address(this)) - beforeA;
        if (remainT != 0) IERC20(token).safeTransfer(msg.sender, remainT);
        if (remainA != 0) IERC20(asset).safeTransfer(msg.sender, remainA);
    }

    function remove(address token, uint256 index, uint256 lp, uint256 minToken, uint256 minAsset, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenOut, uint256 assetOut)
    {
        (address asset, ILiquidityPair pair) = _pool(token, index, deadline);
        if (lp == 0 || minToken == 0 || minAsset == 0) revert InvalidAmount();
        uint256 t = IERC20(token).balanceOf(msg.sender);
        uint256 a = IERC20(asset).balanceOf(msg.sender);
        // A pair burns its entire own LP balance. Refuse pre-existing LP donations.
        if (pair.balanceOf(address(pair)) != 0) revert InvalidPool();
        IERC20(address(pair)).safeTransferFrom(msg.sender, address(pair), lp);
        pair.burn(msg.sender);
        tokenOut = IERC20(token).balanceOf(msg.sender) - t;
        assetOut = IERC20(asset).balanceOf(msg.sender) - a;
        if (tokenOut < minToken || assetOut < minAsset) revert Slippage();
        emit LiquidityRemoved(token, address(pair), msg.sender, tokenOut, assetOut);
    }
}
