// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPump} from "../v14/IPump.sol";
import {INutboxRouter} from "./INutboxRouter.sol";

interface ITradeToken is IERC20 {
    function v4PoolId() external view returns (bytes32);
    function getPump() external view returns (address);
    function COMPONENT_POOL_TAX_BPS() external view returns (uint256);
    function listingHook() external view returns (address);
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

/// @notice Atomic exact-input ETH buys / ETH-output sells for registered compatible Pumps.
/// @dev Routing and optimization happen off chain. No arbitrary call targets, custody or
/// platform fee. The owner manages Pump admission, not execution targets. The main pool receives IPShare hookData directly; Nutbox handles external
/// component routes; the registered Uniswap V2 component pairs are executed directly for tax support.
contract TagAITradeRouter is ReentrancyGuard, Ownable2Step, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    struct Leg {
        uint8 routeIndex; // 0: registered BNB/T route; 1..N: componentAt(index - 1).
        uint256 amountIn; // BNB when buying, gross T when selling.
        uint256 minIntermediateOut; // Component A after the first swap; zero for route 0.
        uint256 minAmountOut; // Net T when buying, BNB when selling, for this leg.
        bytes32 routeHash; // Commitment to the Nutbox route's current sources.
    }

    error InvalidCallback();
    error InvalidMainPool();
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

    address private _activeManager;
    bytes32 private _callbackHash;

    /// @notice Initial Pump, retained for legacy clients. Use supportsToken for admission.
    IPump public immutable pump;
    address[] public supportedPumps;
    mapping(address => bool) public pumpEnabled;
    mapping(address => uint256) private _pumpIndexPlusOne;
    event PumpSupportSet(address indexed pump, bool enabled);
    INutboxRouter public immutable nutboxRouter;
    address public immutable pancakeV2Factory;
    uint256 public constant MAX_ROUTE_POOLS = 8;
    uint256 public constant MAX_COMPONENTS = 4;
    mapping(address => uint16) public factoryFeeBps;
    mapping(address => bool) public factoryEnabled;
    event FactorySet(address indexed factory, uint16 feeBps, bool enabled);

    function setFactory(address factory, uint16 feeBps, bool enabled) external onlyOwner {
        if (enabled && (factory.code.length == 0 || feeBps >= 10000)) revert InvalidConfiguration();
        factoryFeeBps[factory] = feeBps;
        factoryEnabled[factory] = enabled;
        emit FactorySet(factory, feeBps, enabled);
    }

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

    /// @dev subject is requested attribution; the Hook resolves zero/uncreated subjects to Token.getIPShare().
    event MainPoolExecuted(
        address indexed token, address indexed subject, bool isBuy, uint256 amountIn, uint256 amountOut
    );

    constructor(address pump_, address router_, address factory_) {
        if (pump_.code.length == 0 || router_.code.length == 0 || factory_.code.length == 0) {
            revert InvalidConfiguration();
        }
        pump = IPump(pump_);
        nutboxRouter = INutboxRouter(router_);
        pancakeV2Factory = factory_;
        _setPump(pump_, true);
        factoryEnabled[factory_] = true;
        factoryFeeBps[factory_] = 30;
    }

    function supportedPumpCount() external view returns (uint256) {
        return supportedPumps.length;
    }

    /// @notice Admit only reviewed Pumps with compatible Token/listing interfaces and infrastructure.
    function setPump(address candidate, bool enabled) external onlyOwner {
        _setPump(candidate, enabled);
    }

    function _setPump(address candidate, bool enabled) private {
        if (pumpEnabled[candidate] == enabled) return;
        if (enabled) {
            if (candidate.code.length == 0) revert InvalidConfiguration();
            // Reject non-Pump contracts before adding them to the registry.
            try IPump(candidate).createdTokens(address(0)) returns (bool created) {
                if (created) revert InvalidConfiguration();
            } catch {
                revert InvalidConfiguration();
            }
            supportedPumps.push(candidate);
            _pumpIndexPlusOne[candidate] = supportedPumps.length;
        } else {
            uint256 i = _pumpIndexPlusOne[candidate] - 1;
            address last = supportedPumps[supportedPumps.length - 1];
            supportedPumps[i] = last;
            _pumpIndexPlusOne[last] = i + 1;
            supportedPumps.pop();
            delete _pumpIndexPlusOne[candidate];
        }
        pumpEnabled[candidate] = enabled;
        emit PumpSupportSet(candidate, enabled);
    }

    /// @notice Membership only; execution additionally validates listing, pools and infrastructure.
    function supportsToken(address token) public view returns (bool) {
        if (token.code.length == 0) return false;
        try ITradeToken(token).getPump() returns (address origin) {
            if (!pumpEnabled[origin]) return false;
            try IPump(origin).createdTokens(token) returns (bool created) {
                return created;
            }
                catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    receive() external payable {
        if (msg.sender != address(nutboxRouter) && msg.sender != _activeManager) revert InvalidConfiguration();
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

    /// @notice Spend exactly the sum of the legs' ETH allocations, refunding any execution remainder.
    function buy(
        address token,
        Leg[] calldata legs,
        uint256 minTokenOut,
        uint256 deadline,
        address recipient,
        address subject
    ) external payable nonReentrant returns (uint256 tokenOut) {
        _validate(token, legs, msg.value, minTokenOut, deadline, recipient);
        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        for (uint256 i; i < legs.length; ++i) {
            _buyLeg(token, legs[i], deadline, subject);
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
            token, msg.sender, recipient, true, msg.value, tokenOut, refundAmount, keccak256(abi.encode(subject, legs))
        );
    }

    /// @notice Pull the caller's gross T once; deliver ETH and refund unspent input to the caller.
    function sell(
        address token,
        uint256 amountIn,
        Leg[] calldata legs,
        uint256 minBnbOut,
        uint256 deadline,
        address recipient,
        address subject
    ) external nonReentrant returns (uint256 bnbOut) {
        _validate(token, legs, amountIn, minBnbOut, deadline, recipient);
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(token).balanceOf(address(this)) - tokenBefore != amountIn) revert UnexpectedBalance();
        for (uint256 i; i < legs.length; ++i) {
            _sellLeg(token, legs[i], deadline, subject);
        }
        bnbOut = address(this).balance - nativeBefore;
        if (bnbOut < minBnbOut) revert Slippage();
        uint256 refundAmount = IERC20(token).balanceOf(address(this)) - tokenBefore;
        _refundToken(token, tokenBefore);
        _sendNative(recipient, bnbOut);
        emit TradeExecuted(
            token, msg.sender, recipient, false, amountIn, bnbOut, refundAmount, keccak256(abi.encode(subject, legs))
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
        if (!supportsToken(token) || !ITradeToken(token).listed()) revert InvalidToken();
        (address router,,,) = ITradeToken(token).listingInfrastructure();
        if (router != address(nutboxRouter) || !factoryEnabled[ITradeToken(token).pancakeV2Factory()]) {
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

    function _buyLeg(address token, Leg calldata leg, uint256 deadline, address subject) private {
        uint256 beforeNative = address(this).balance;
        uint256 beforeT = IERC20(token).balanceOf(address(this));
        if (leg.routeIndex == 0) {
            _checkRoute(address(0), token, leg.routeHash);
            _swapMain(token, leg.amountIn, true, subject);
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

    function _sellLeg(address token, Leg calldata leg, uint256 deadline, address subject) private {
        uint256 beforeNative = address(this).balance;
        uint256 beforeT = IERC20(token).balanceOf(address(this));
        if (leg.routeIndex == 0) {
            _checkRoute(token, address(0), leg.routeHash);
            _swapMain(token, leg.amountIn, false, subject);
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

    /// @dev The deployed NutboxRouter cannot forward hookData. Execute only the token's
    /// registered native/T listing pool directly; component conversion routes stay on Nutbox.
    function _swapMain(address token, uint256 amount, bool isBuy, address subject) private {
        if (amount > uint256(uint128(type(int128).max))) revert InvalidPlan();
        address input = isBuy ? address(0) : token;
        address output = isBuy ? token : address(0);
        if (nutboxRouter.routePoolCount(input, output) != 1) revert InvalidMainPool();
        (bool enabled,,,, INutboxRouter.SourceType kind, bytes memory sourceData) =
            nutboxRouter.pricePool(nutboxRouter.routePoolAt(input, output, 0));
        if (!enabled || kind != INutboxRouter.SourceType.UNISWAP_V4) revert InvalidMainPool();
        INutboxRouter.UniswapV4Source memory source = abi.decode(sourceData, (INutboxRouter.UniswapV4Source));
        (,,, address manager) = ITradeToken(token).listingInfrastructure();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(source.currency0),
            currency1: Currency.wrap(source.currency1),
            hooks: IHooks(source.hooks),
            fee: source.fee,
            tickSpacing: source.tickSpacing
        });
        if (
            source.currency0 != address(0) || source.currency1 != token || source.poolManager != manager
                || source.hooks != ITradeToken(token).listingHook()
                || PoolId.unwrap(key.toId()) != ITradeToken(token).v4PoolId()
        ) revert InvalidMainPool();
        if (!nutboxRouter.allowedUniswapV4Manager(manager)) revert InvalidMainPool();
        bytes memory data = abi.encode(key, isBuy, amount, subject);
        _activeManager = manager;
        _callbackHash = keccak256(data);
        IPoolManager(manager).unlock(data);
        if (_callbackHash != bytes32(0)) revert InvalidCallback();
        _activeManager = address(0);
    }

    /// @dev Authenticated, single-use callback. The key and amount were checked before locking.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeManager || _callbackHash == bytes32(0) || keccak256(data) != _callbackHash) {
            revert InvalidCallback();
        }
        _callbackHash = bytes32(0);
        (PoolKey memory key, bool isBuy, uint256 amount, address subject) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta delta = IPoolManager(msg.sender)
            .swap(
                key,
                IPoolManager.SwapParams({
                zeroForOne: isBuy,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
                abi.encode(subject)
            );
        int128 inputDelta = isBuy ? delta.amount0() : delta.amount1();
        int128 outputDelta = isBuy ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0 || uint256(-int256(inputDelta)) != amount) revert UnexpectedBalance();
        IPoolManager manager = IPoolManager(msg.sender);
        if (isBuy) {
            manager.settle{value: amount}();
        } else {
            manager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(manager), amount);
            manager.settle();
        }
        uint256 out = uint256(uint128(outputDelta));
        manager.take(isBuy ? key.currency1 : key.currency0, address(this), out);
        emit MainPoolExecuted(Currency.unwrap(key.currency1), subject, isBuy, amount, out);
        return abi.encode(out);
    }

    function _routerSell(address asset, uint256 amount, uint256 minimum, uint256 deadline) private {
        IERC20(asset).forceApprove(address(nutboxRouter), amount);
        nutboxRouter.swapExactInput(asset, address(0), amount, minimum, address(this), deadline);
        IERC20(asset).forceApprove(address(nutboxRouter), 0);
    }

    function _component(address token, uint8 routeIndex) private view returns (address asset, address pair) {
        (asset,, pair) = ITradeToken(token).componentAt(routeIndex - 1);
        address factory = ITradeToken(token).pancakeV2Factory();
        if (
            asset == address(0) || asset == token || pair.code.length == 0
                || ITradeFactory(factory).getPair(token, asset) != pair || ITradePair(pair).factory() != factory
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
        uint256 withFee = actualIn * (10000 - factoryFeeBps[ITradePair(pair).factory()]);
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
