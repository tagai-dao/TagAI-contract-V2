// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import "../interfaces/IImportHelper.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV3SwapRouter.sol";
import "../interfaces/IWETH.sol";
import "../utils/CurrencySettler.sol";

/// @title TagAISwapWrapper
/// @notice Fee-on-trade wrapper for Uniswap V2 / V3 / V4 buys & sells.
/// @dev V4: this contract implements IUnlockCallback. PoolKey.hooks may be address(0)
///      for generic (non-TagAI) pools — callers supply the full PoolKey.
contract TagAISwapWrapper is Ownable, ReentrancyGuard, IUnlockCallback {
    using CurrencyLibrary for Currency;

    address public importHelper;
    address public ipshare;
    address public WETH;
    address public feeAddress;

    /// @dev Basis points / 10000. Defaults match legacy WrappedUniV2ForTagAI (1% each).
    uint16 public sellsmanRatio = 100;
    uint16 public tagaiRatio = 100;

    /// @dev Transient PoolManager for the in-flight V4 unlock callback.
    IPoolManager private _activePoolManager;

    struct V4CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        IPoolManager.SwapParams params;
        uint256 amountOutMin;
        bool ethIsCurrency0;
        bool ethIsNative;
    }

    error InvalidPath();
    error PaySellsmanFeeFail();
    error PayFeeFail();
    error TransferToFailed();
    error ApproveFailed();
    error TransferFailed();
    error Slippage();
    error InvalidPoolKey();
    error OnlyPoolManager();

    constructor(address importHelper_, address ipshare_, address weth_, address feeAddress_) {
        require(importHelper_ != address(0), "zero importHelper");
        require(ipshare_ != address(0), "zero ipshare");
        require(weth_ != address(0), "zero weth");
        require(feeAddress_ != address(0), "zero feeAddress");
        importHelper = importHelper_;
        ipshare = ipshare_;
        WETH = weth_;
        feeAddress = feeAddress_;
    }

    receive() external payable {}

    // ─── Admin ───────────────────────────────────────────────────────────────────

    function adminSetFeeRatio(uint16 sellsmanRatio_, uint16 tagaiRatio_) external onlyOwner {
        require(sellsmanRatio_ < 1000 && tagaiRatio_ < 1000, "fee ratio too high");
        sellsmanRatio = sellsmanRatio_;
        tagaiRatio = tagaiRatio_;
    }

    function adminSetFeeAddress(address feeAddress_) external onlyOwner {
        require(feeAddress_ != address(0), "zero feeAddress");
        feeAddress = feeAddress_;
    }

    function adminSetWeth(address weth_) external onlyOwner {
        require(weth_ != address(0), "zero weth");
        WETH = weth_;
    }

    function adminSetImportHelper(address importHelper_) external onlyOwner {
        require(importHelper_ != address(0), "zero importHelper");
        importHelper = importHelper_;
    }

    function adminSetIpshare(address ipshare_) external onlyOwner {
        require(ipshare_ != address(0), "zero ipshare");
        ipshare = ipshare_;
    }

    // ─── Sellsman resolution ─────────────────────────────────────────────────────

    /// @dev 1) valid IPShare subject arg → 2) ImportHelper.importerOf(token) → 3) feeAddress
    function _resolveSellsman(address token, address sellsman) internal returns (address) {
        if (sellsman != address(0) && IIPShare(ipshare).ipshareCreated(sellsman)) {
            return sellsman;
        }
        address importer = IImportHelper(importHelper).importerOf(token);
        if (importer != address(0)) {
            return importer;
        }
        return feeAddress;
    }

    /// @dev Take sellsman + tagai fees from an ETH notional; return remainder for the swap.
    function _takeFeesFromEth(uint256 ethAmount, address sellsman) internal returns (uint256 remaining) {
        remaining = ethAmount;
        if (sellsmanRatio > 0) {
            uint256 sellsmanFee = (ethAmount * sellsmanRatio) / 10_000;
            remaining -= sellsmanFee;
            (bool ok,) = sellsman.call{value: sellsmanFee}("");
            if (!ok) revert PaySellsmanFeeFail();
        }
        if (tagaiRatio > 0) {
            uint256 tagaiFee = (ethAmount * tagaiRatio) / 10_000;
            remaining -= tagaiFee;
            (bool ok,) = feeAddress.call{value: tagaiFee}("");
            if (!ok) revert PayFeeFail();
        }
    }

    // ─── V2 ──────────────────────────────────────────────────────────────────────

    function buyToken(
        address sellsman,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        address router
    ) external payable nonReentrant {
        if (path.length < 2 || path[0] != WETH) revert InvalidPath();
        address token = path[1];
        sellsman = _resolveSellsman(token, sellsman);

        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        IUniswapV2Router02(router).swapExactETHForTokens{value: buyFund}(amountOutMin, path, to, deadline);
    }

    function sellToken(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        address sellsman,
        address router
    ) external nonReentrant {
        if (path.length < 2 || path[path.length - 1] != WETH) revert InvalidPath();
        address token = path[0];
        sellsman = _resolveSellsman(token, sellsman);

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        if (!erc20.approve(router, amountIn)) revert ApproveFailed();

        uint256[] memory amounts = IUniswapV2Router02(router).swapExactTokensForETH(
            amountIn, amountOutMin, path, address(this), deadline
        );
        // Best-effort allowance reset.
        erc20.approve(router, 0);

        uint256 ethOut = amounts[amounts.length - 1];
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    // ─── V3 ──────────────────────────────────────────────────────────────────────

    function buyTokenV3(
        address sellsman,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline,
        address router,
        uint24 poolFee
    ) external payable nonReentrant {
        sellsman = _resolveSellsman(token, sellsman);
        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: token,
            fee: poolFee,
            recipient: to,
            deadline: deadline,
            amountIn: buyFund,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });
        IUniswapV3SwapRouter(router).exactInputSingle{value: buyFund}(params);
        IUniswapV3SwapRouter(router).refundETH();
        if (address(this).balance > 0) {
            (bool ok,) = to.call{value: address(this).balance}("");
            if (!ok) revert TransferToFailed();
        }
    }

    function sellTokenV3(
        uint256 amountIn,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline,
        address sellsman,
        address router,
        uint24 poolFee
    ) external nonReentrant {
        sellsman = _resolveSellsman(token, sellsman);

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        if (!erc20.approve(router, amountIn)) revert ApproveFailed();

        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: WETH,
            fee: poolFee,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });
        IUniswapV3SwapRouter(router).exactInputSingle(params);
        erc20.approve(router, 0);

        uint256 wethBal = IERC20(WETH).balanceOf(address(this));
        if (wethBal > 0) {
            IWETH(WETH).withdraw(wethBal);
        }

        uint256 ethOut = address(this).balance;
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    // ─── V4 (PoolManager + unlock callback) ──────────────────────────────────────

    /// @notice Exact-in ETH → token via PoolManager. `poolKey.hooks` may be zero for generic pools.
    function buyTokenV4(
        address sellsman,
        uint256 amountOutMin,
        PoolKey calldata poolKey,
        address to,
        IPoolManager poolManager,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        (bool ethIsCurrency0, bool ethIsNative, address token) = _parseEthPool(poolKey);
        sellsman = _resolveSellsman(token, sellsman);
        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        // If the ETH leg is WETH (not native), wrap before unlock settle.
        if (!ethIsNative) {
            IWETH(WETH).deposit{value: buyFund}();
        }

        bool zeroForOne = ethIsCurrency0;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 =
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        V4CallbackData memory cb = V4CallbackData({
            payer: address(this),
            recipient: to,
            key: poolKey,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(buyFund),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            amountOutMin: amountOutMin,
            ethIsCurrency0: ethIsCurrency0,
            ethIsNative: ethIsNative
        });

        _activePoolManager = poolManager;
        poolManager.unlock(abi.encode(cb));
        _activePoolManager = IPoolManager(address(0));
    }

    /// @notice Exact-in token → ETH via PoolManager. `poolKey.hooks` may be zero for generic pools.
    function sellTokenV4(
        uint256 amountIn,
        uint256 amountOutMin,
        PoolKey calldata poolKey,
        address to,
        address sellsman,
        IPoolManager poolManager,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant {
        (bool ethIsCurrency0, bool ethIsNative, address token) = _parseEthPool(poolKey);
        sellsman = _resolveSellsman(token, sellsman);

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();

        // Selling token for ETH: zeroForOne is true when token is currency0.
        bool zeroForOne = !ethIsCurrency0;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 =
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        V4CallbackData memory cb = V4CallbackData({
            payer: address(this),
            recipient: address(this), // take ETH/WETH here, then fee-split
            key: poolKey,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            amountOutMin: amountOutMin,
            ethIsCurrency0: ethIsCurrency0,
            ethIsNative: ethIsNative
        });

        _activePoolManager = poolManager;
        poolManager.unlock(abi.encode(cb));
        _activePoolManager = IPoolManager(address(0));

        if (!ethIsNative) {
            uint256 wethBal = IERC20(WETH).balanceOf(address(this));
            if (wethBal > 0) {
                IWETH(WETH).withdraw(wethBal);
            }
        }

        uint256 ethOut = address(this).balance;
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(_activePoolManager)) revert OnlyPoolManager();
        IPoolManager manager = _activePoolManager;

        V4CallbackData memory data = abi.decode(rawData, (V4CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, bytes(""));

        // Exact-in: input currency delta is negative; output is positive.
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) {
            CurrencySettler.settle(data.key.currency0, manager, data.payer, uint256(uint128(-amount0)), false);
        }
        if (amount1 < 0) {
            CurrencySettler.settle(data.key.currency1, manager, data.payer, uint256(uint128(-amount1)), false);
        }

        // Slippage on the non-ETH (token) output for buys; on ETH output for sells.
        if (data.params.zeroForOne == data.ethIsCurrency0) {
            // Buy path: eth → token. Token out is the positive non-eth delta.
            int128 tokenOut = data.ethIsCurrency0 ? amount1 : amount0;
            if (tokenOut < 0 || uint256(uint128(tokenOut)) < data.amountOutMin) revert Slippage();
        } else {
            // Sell path: token → eth.
            int128 ethOut = data.ethIsCurrency0 ? amount0 : amount1;
            if (ethOut < 0 || uint256(uint128(ethOut)) < data.amountOutMin) revert Slippage();
        }

        if (amount0 > 0) {
            CurrencySettler.take(data.key.currency0, manager, data.recipient, uint256(uint128(amount0)), false);
        }
        if (amount1 > 0) {
            CurrencySettler.take(data.key.currency1, manager, data.recipient, uint256(uint128(amount1)), false);
        }

        return abi.encode(delta);
    }

    /// @dev Require exactly one pool side is native ETH or WETH; return token address.
    function _parseEthPool(PoolKey calldata key)
        internal
        view
        returns (bool ethIsCurrency0, bool ethIsNative, address token)
    {
        bool c0 = _isEthLeg(key.currency0);
        bool c1 = _isEthLeg(key.currency1);
        if (c0 == c1) revert InvalidPoolKey();
        if (c0) {
            ethIsCurrency0 = true;
            ethIsNative = Currency.unwrap(key.currency0) == address(0);
            token = Currency.unwrap(key.currency1);
        } else {
            ethIsCurrency0 = false;
            ethIsNative = Currency.unwrap(key.currency1) == address(0);
            token = Currency.unwrap(key.currency0);
        }
    }

    function _isEthLeg(Currency c) internal view returns (bool) {
        address a = Currency.unwrap(c);
        return a == address(0) || a == WETH;
    }
}
