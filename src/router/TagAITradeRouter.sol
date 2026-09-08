// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IPump} from "../interfaces/IPump.sol";
import {INutboxRouter} from "./INutboxRouter.sol";

interface ITradeToken is IERC20 {
    function listed() external view returns (bool);
    function pancakeV2Factory() external view returns (address);
    function componentCount() external view returns (uint256);
    function componentAt(uint256 index) external view returns (address asset, uint16 weight, address pair);
    function listingInfrastructure() external view returns (address, address, address, address);
}

interface ITradePair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
}

interface ITradeFactory {
    function getPair(address, address) external view returns (address);
}

/// @notice Atomic exact-input BNB buys / BNB-output sells for one Pump V13 deployment.
/// @dev Routing and optimization happen off chain. No arbitrary call targets, custody,
/// platform fee, owner or upgrade mechanism. Nutbox handles the registered external
/// routes; the registered Pancake V2 component pairs are executed directly for tax support.
contract TagAITradeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Leg {
        uint8 routeIndex; // 0: registered BNB/T route; 1..N: componentAt(index - 1).
        uint256 amountIn; // BNB when buying, gross T when selling.
        uint256 minIntermediateOut; // Component A after the first swap; zero for route 0.
        uint256 minAmountOut; // Net T when buying, BNB when selling, for this leg.
        bytes32 routeHash; // Commitment to the Nutbox route's current sources.
    }

    error InvalidConfiguration();
    error InvalidToken();
    error InvalidRecipient();
    error InvalidPlan();
    error InvalidPair();
    error DeadlineExpired();
    error RouteChanged();
    error Slippage();
    error UnexpectedBalance();
    error NativeTransferFailed();

    IPump public immutable pump;
    INutboxRouter public immutable nutboxRouter;
    address public immutable pancakeV2Factory;
    uint256 public constant MAX_ROUTE_POOLS = 8;
    uint256 public constant MAX_COMPONENTS = 4;
    uint256 private constant V2_FEE_NUMERATOR = 9975; // Pancake V2: 25 bps.

    event TradeExecuted(
        address indexed token,
        address indexed payer,
        address indexed recipient,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 refundAmount,
        bytes32 planHash
    );
    event LegExecuted(
        address indexed token, uint8 indexed routeIndex, bool isBuy, uint256 amountSpent, uint256 amountOut
    );

    constructor(address pump_, address router_, address factory_) {
        if (pump_.code.length == 0 || router_.code.length == 0 || factory_.code.length == 0) {
            revert InvalidConfiguration();
        }
        pump = IPump(pump_);
        nutboxRouter = INutboxRouter(router_);
        pancakeV2Factory = factory_;
    }

    receive() external payable {
        if (msg.sender != address(nutboxRouter)) revert InvalidConfiguration();
    }

    /// @notice Compute at the same block used to simulate/quote the complete plan.
    /// Includes source data so replacing a pool without changing its registry ID invalidates a quote.
    function routeHash(address tokenIn, address tokenOut) public view returns (bytes32 hash) {
        if (!nutboxRouter.hasRoute(tokenIn, tokenOut)) revert InvalidPlan();
        uint256 count = nutboxRouter.routePoolCount(tokenIn, tokenOut);
        if (count == 0 || count > MAX_ROUTE_POOLS) revert InvalidPlan();
        hash = keccak256(abi.encode(block.chainid, address(nutboxRouter), tokenIn, tokenOut, count));
        for (uint256 i; i < count; ++i) {
            bytes32 id = nutboxRouter.routePoolAt(tokenIn, tokenOut, i);
            (bool enabled,, address a, address b, INutboxRouter.SourceType kind, bytes memory data) =
                nutboxRouter.pricePool(id);
            if (!enabled) revert InvalidPlan();
            hash = keccak256(abi.encode(hash, id, a, b, kind, data));
        }
    }

    /// @notice Spend exactly the sum of the legs' BNB allocations, refunding any execution remainder.
    function buy(address token, Leg[] calldata legs, uint256 minTokenOut, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokenOut)
    {
        _validate(token, legs, msg.value, minTokenOut, deadline, recipient);
        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        for (uint256 i; i < legs.length; ++i) {
            _buyLeg(token, legs[i], deadline);
        }
        tokenOut = IERC20(token).balanceOf(address(this)) - tokenBefore;
        if (tokenOut < minTokenOut) revert Slippage();
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, tokenOut);
        tokenOut = IERC20(token).balanceOf(recipient) - recipientBefore;
        if (tokenOut < minTokenOut) revert Slippage();
        if (IERC20(token).balanceOf(address(this)) != tokenBefore) revert UnexpectedBalance();
        uint256 refundAmount = address(this).balance - nativeBefore;
        _sendNative(msg.sender, refundAmount);
        emit TradeExecuted(
            token, msg.sender, recipient, true, msg.value, tokenOut, refundAmount, keccak256(abi.encode(legs))
        );
    }

    /// @notice Pull the caller's gross T once; deliver BNB and refund unspent input to the caller.
    function sell(
        address token,
        uint256 amountIn,
        Leg[] calldata legs,
        uint256 minBnbOut,
        uint256 deadline,
        address recipient
    ) external nonReentrant returns (uint256 bnbOut) {
        _validate(token, legs, amountIn, minBnbOut, deadline, recipient);
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(token).balanceOf(address(this)) - tokenBefore != amountIn) revert UnexpectedBalance();
        for (uint256 i; i < legs.length; ++i) {
            _sellLeg(token, legs[i], deadline);
        }
        bnbOut = address(this).balance - nativeBefore;
        if (bnbOut < minBnbOut) revert Slippage();
        uint256 refundAmount = IERC20(token).balanceOf(address(this)) - tokenBefore;
        _refundToken(token, tokenBefore);
        _sendNative(recipient, bnbOut);
        emit TradeExecuted(
            token, msg.sender, recipient, false, amountIn, bnbOut, refundAmount, keccak256(abi.encode(legs))
        );
    }

    function _validate(
        address token,
        Leg[] calldata legs,
        uint256 amount,
        uint256 minimum,
        uint256 deadline,
        address recipient
    ) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (!pump.createdTokens(token) || !ITradeToken(token).listed()) revert InvalidToken();
        (address router,,,) = ITradeToken(token).listingInfrastructure();
        if (router != address(nutboxRouter) || ITradeToken(token).pancakeV2Factory() != pancakeV2Factory) {
            revert InvalidToken();
        }
        uint256 count = ITradeToken(token).componentCount();
        if (count == 0 || count > MAX_COMPONENTS || legs.length == 0 || legs.length > count + 1) revert InvalidPlan();
        uint256 total;
        uint256 seen;
        for (uint256 i; i < legs.length; ++i) {
            Leg calldata leg = legs[i];
            uint256 bit = 1 << leg.routeIndex;
            if (
                leg.routeIndex > count || (seen & bit) != 0 || leg.amountIn == 0 || leg.minAmountOut == 0
                    || leg.routeHash == bytes32(0)
                    || (leg.routeIndex == 0 ? leg.minIntermediateOut != 0 : leg.minIntermediateOut == 0)
            ) {
                revert InvalidPlan();
            }
            seen |= bit;
            total += leg.amountIn;
        }
        if (amount == 0 || minimum == 0 || total != amount) revert InvalidPlan();
    }

    function _buyLeg(address token, Leg calldata leg, uint256 deadline) private {
        uint256 beforeNative = address(this).balance;
        uint256 beforeT = IERC20(token).balanceOf(address(this));
        if (leg.routeIndex == 0) {
            _checkRoute(address(0), token, leg.routeHash);
            nutboxRouter.swapExactInput{value: leg.amountIn}(
                address(0), token, leg.amountIn, leg.minAmountOut, address(this), deadline
            );
        } else {
            (address asset, address pair) = _component(token, leg.routeIndex);
            _checkRoute(address(0), asset, leg.routeHash);
            uint256 beforeA = IERC20(asset).balanceOf(address(this));
            nutboxRouter.swapExactInput{value: leg.amountIn}(
                address(0), asset, leg.amountIn, leg.minIntermediateOut, address(this), deadline
            );
            uint256 received = IERC20(asset).balanceOf(address(this)) - beforeA;
            if (received < leg.minIntermediateOut) revert Slippage();
            _swapPair(pair, asset, received);
            _refundToken(asset, beforeA);
        }
        // Do not trust the router return value or the pair's gross output: T has a component tax.
        uint256 out = IERC20(token).balanceOf(address(this)) - beforeT;
        if (out < leg.minAmountOut) revert Slippage();
        emit LegExecuted(token, leg.routeIndex, true, beforeNative - address(this).balance, out);
    }

    function _sellLeg(address token, Leg calldata leg, uint256 deadline) private {
        uint256 beforeNative = address(this).balance;
        uint256 beforeT = IERC20(token).balanceOf(address(this));
        if (leg.routeIndex == 0) {
            _checkRoute(token, address(0), leg.routeHash);
            _routerSell(token, leg.amountIn, leg.minAmountOut, deadline);
        } else {
            (address asset, address pair) = _component(token, leg.routeIndex);
            _checkRoute(asset, address(0), leg.routeHash);
            uint256 beforeA = IERC20(asset).balanceOf(address(this));
            _swapPair(pair, token, leg.amountIn);
            uint256 received = IERC20(asset).balanceOf(address(this)) - beforeA;
            if (received < leg.minIntermediateOut) revert Slippage();
            _routerSell(asset, received, leg.minAmountOut, deadline);
            _refundToken(asset, beforeA);
        }
        uint256 out = address(this).balance - beforeNative;
        if (out < leg.minAmountOut) revert Slippage();
        emit LegExecuted(token, leg.routeIndex, false, beforeT - IERC20(token).balanceOf(address(this)), out);
    }

    function _routerSell(address asset, uint256 amount, uint256 minimum, uint256 deadline) private {
        IERC20(asset).forceApprove(address(nutboxRouter), amount);
        nutboxRouter.swapExactInput(asset, address(0), amount, minimum, address(this), deadline);
        IERC20(asset).forceApprove(address(nutboxRouter), 0);
    }

    function _component(address token, uint8 routeIndex) private view returns (address asset, address pair) {
        (asset,, pair) = ITradeToken(token).componentAt(routeIndex - 1);
        if (
            asset == address(0) || asset == token || pair.code.length == 0
                || ITradeFactory(pancakeV2Factory).getPair(token, asset) != pair
                || ITradePair(pair).factory() != pancakeV2Factory
        ) revert InvalidPair();
        address a = ITradePair(pair).token0();
        address b = ITradePair(pair).token1();
        if (!((a == token && b == asset) || (a == asset && b == token))) revert InvalidPair();
    }

    function _swapPair(address pair, address input, uint256 amount) private {
        bool input0 = ITradePair(pair).token0() == input;
        (uint112 r0, uint112 r1,) = ITradePair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = input0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert InvalidPair();
        uint256 beforeInput = IERC20(input).balanceOf(pair);
        IERC20(input).safeTransfer(pair, amount);
        // Only credit this call's net input, never another account's donation to the pair.
        uint256 actualIn = IERC20(input).balanceOf(pair) - beforeInput;
        uint256 withFee = actualIn * V2_FEE_NUMERATOR;
        uint256 output = withFee * reserveOut / (reserveIn * 10000 + withFee);
        if (output == 0) revert Slippage();
        ITradePair(pair).swap(input0 ? 0 : output, input0 ? output : 0, address(this), "");
    }

    function _checkRoute(address input, address output, bytes32 expected) private view {
        if (routeHash(input, output) != expected) revert RouteChanged();
    }

    function _refundToken(address asset, uint256 beforeBalance) private {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < beforeBalance) revert UnexpectedBalance();
        if (balance > beforeBalance) IERC20(asset).safeTransfer(msg.sender, balance - beforeBalance);
        if (IERC20(asset).balanceOf(address(this)) != beforeBalance) revert UnexpectedBalance();
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}
