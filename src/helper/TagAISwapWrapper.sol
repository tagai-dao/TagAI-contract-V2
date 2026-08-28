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
import "../interfaces/ICommunity.sol";
import "../interfaces/IHourlyTickCalculator.sol";
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

    /// @dev 导入代币市场登记（由 ImportHelper 调用 registerImportedToken 写入）。
    struct ImportedMarket {
        bool registered;
        address community;
        address deployer;
    }
    mapping(address => ImportedMarket) private _importedMarkets;

    event ImportedMarketRegistered(address indexed token, address indexed community, address indexed deployer);

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
    error TransferToFailed();
    error ApproveFailed();
    error TransferFailed();
    error Slippage();
    error InvalidPoolKey();
    error OnlyPoolManager();
    error UnauthorizedRegistrar();
    error MarketAlreadyRegistered();

    constructor(address importHelper_, address ipshare_, address weth_, address feeAddress_) {
        // importHelper 可在部署后通过 adminSetImportHelper 设置（解决与 ImportHelper 的循环依赖）。
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

    // ─── 导入代币市场登记 ───────────────────────────────────────────────────────

    /// @dev 仅 ImportHelper 可登记（registrar）。重复登记 revert。
    function registerImportedToken(address token, address community, address deployer) external {
        if (msg.sender != importHelper) revert UnauthorizedRegistrar();
        if (token == address(0)) revert InvalidPath();
        ImportedMarket storage m = _importedMarkets[token];
        if (m.registered) revert MarketAlreadyRegistered();
        _importedMarkets[token] = ImportedMarket({registered: true, community: community, deployer: deployer});
        emit ImportedMarketRegistered(token, community, deployer);
    }

    function getImportedMarket(address token)
        external
        view
        returns (bool registered, address community, address deployer)
    {
        ImportedMarket memory m = _importedMarkets[token];
        return (m.registered, m.community, m.deployer);
    }

    /// @dev 已登记代币绑定的 community（内部用，未登记返回 address(0)）。
    function _importedCommunity(address token) internal view returns (address) {
        return _importedMarkets[token].community;
    }

    // ─── 导入代币 Nutbox token 侧 fee + 10 分钟注入 ─────────────────────────────

    /// @dev 已登记代币交易时从 token 侧抽 0.2% 累计注入 Nutbox（与 main 导入对齐）。
    uint16 public nutboxTokenRatio = 20; // 20 bps = 0.2%
    uint256 public constant NUTBOX_INJECTION_INTERVAL = 600; // 10 分钟
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(address => uint256) public pendingNutboxInjection;
    mapping(address => uint256) public lastNutboxInjectionAt;

    event NutboxTokenFeeAccrued(address indexed token, address indexed community, uint256 amount, uint256 pendingAmount);
    event NutboxTokenFeeInjected(address indexed token, address indexed community, uint256 amount);
    event NutboxTokenFeeInjectionFailed(address indexed token, address indexed community, uint256 amount, bytes reason);
    event FeeRatiosChanged(uint16 sellsmanRatio, uint16 tagaiRatio, uint16 nutboxTokenRatio);

    /// @dev 三参数费率设置（sellsman / tagai / nutboxToken）。
    function adminSetFeeRatios(uint16 sellsmanRatio_, uint16 tagaiRatio_, uint16 nutboxTokenRatio_)
        external
        onlyOwner
    {
        require(sellsmanRatio_ < 1000 && tagaiRatio_ < 1000, "fee ratio too high");
        require(nutboxTokenRatio_ < 1000, "nutbox ratio too high");
        sellsmanRatio = sellsmanRatio_;
        tagaiRatio = tagaiRatio_;
        nutboxTokenRatio = nutboxTokenRatio_;
        emit FeeRatiosChanged(sellsmanRatio_, tagaiRatio_, nutboxTokenRatio_);
    }

    /// @dev 已登记代币：从毛 token 量扣 nutboxTokenRatio 累计到 pending；未登记：原样返回。
    function _chargeNutboxTokenFee(address token, uint256 grossAmount) internal returns (uint256 netAmount) {
        address community = _importedCommunity(token);
        if (community == address(0) || nutboxTokenRatio == 0 || grossAmount == 0) return grossAmount;
        uint256 fee = (grossAmount * nutboxTokenRatio) / BPS_DENOMINATOR;
        if (fee == 0) return grossAmount;
        pendingNutboxInjection[token] += fee;
        emit NutboxTokenFeeAccrued(token, community, fee, pendingNutboxInjection[token]);
        return grossAmount - fee;
    }

    /// @dev 10 分钟结算窗口到则尝试把 pending 注入 community 的 rewardCalculator；失败保留 pending，不阻断交易。
    function _trySettleNutboxInjection(address token) internal {
        address community = _importedCommunity(token);
        if (community == address(0)) return;
        uint256 pending = pendingNutboxInjection[token];
        if (pending == 0) return;
        if (block.timestamp < lastNutboxInjectionAt[token] + NUTBOX_INJECTION_INTERVAL) return;

        address calc = ICommunity(community).rewardCalculator();
        if (calc == address(0)) return;

        // calculator.inject 通过 safeTransferFrom 从本合约拉 token，需先 approve。
        IERC20(token).approve(calc, pending);
        try IHourlyTickCalculator(calc).inject(community, pending) {
            pendingNutboxInjection[token] = 0;
            lastNutboxInjectionAt[token] = block.timestamp;
            emit NutboxTokenFeeInjected(token, community, pending);
        } catch (bytes memory reason) {
            // 失败：保留 pending，回滚 approve，交易继续。
            IERC20(token).approve(calc, 0);
            emit NutboxTokenFeeInjectionFailed(token, community, pending, reason);
        }
    }

    /// @notice 手动触发注入（同样受 10 分钟窗口限制）。返回实际注入量。
    function flushNutboxInjection(address token) external nonReentrant returns (uint256) {
        _trySettleNutboxInjection(token);
        return pendingNutboxInjection[token];
    }

    // ─── Sellsman resolution ─────────────────────────────────────────────────────

    /// @dev 1) valid IPShare subject arg → 2) ImportHelper.importerOf(token) → 3) feeAddress
    function _resolveSellsman(address token, address sellsman) internal returns (address) {
        if (sellsman != address(0) && IIPShare(ipshare).ipshareCreated(sellsman)) {
            return sellsman;
        }
        if (importHelper != address(0)) {
            address importer = IImportHelper(importHelper).importerOf(token);
            if (importer != address(0)) {
                return importer;
            }
        }
        return feeAddress;
    }

    /// @dev 从 ETH 名义金额扣 sellsman + tagai 手续费，返回留给 swap / 用户的剩余。
    ///      sellsman 收款失败时静默归集到 feeAddress，不阻断真正交易。
    ///      feeAddress 由运营保证可收（可 admin 更换）。
    function _takeFeesFromEth(uint256 ethAmount, address sellsman) internal returns (uint256 remaining) {
        remaining = ethAmount;
        if (sellsmanRatio > 0) {
            uint256 sellsmanFee = (ethAmount * sellsmanRatio) / 10_000;
            remaining -= sellsmanFee;
            if (!_trySendEth(sellsman, sellsmanFee)) {
                // 拒收 / 无 receive → 归集到 feeAddress，交易继续
                _trySendEth(feeAddress, sellsmanFee);
            }
        }
        if (tagaiRatio > 0) {
            uint256 tagaiFee = (ethAmount * tagaiRatio) / 10_000;
            remaining -= tagaiFee;
            _trySendEth(feeAddress, tagaiFee);
        }
    }

    /// @dev 尽力转 ETH；失败只返回 false，绝不 revert（手续费不得拖垮成交）。
    function _trySendEth(address to, uint256 amount) private returns (bool ok) {
        if (amount == 0) return true;
        (ok,) = to.call{value: amount}("");
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

        _trySettleNutboxInjection(token);

        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        // token 先进 Wrapper，扣 0.2% Nutbox fee 后净额转用户（已登记代币）。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IUniswapV2Router02(router).swapExactETHForTokens{value: buyFund}(amountOutMin, path, address(this), deadline);
        uint256 gross = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 net = _chargeNutboxTokenFee(token, gross);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
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

        _trySettleNutboxInjection(token);

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, amountIn);
        if (!erc20.approve(router, swapIn)) revert ApproveFailed();

        uint256[] memory amounts = IUniswapV2Router02(router).swapExactTokensForETH(
            swapIn, amountOutMin, path, address(this), deadline
        );
        // Best-effort allowance reset.
        erc20.approve(router, 0);

        uint256 ethOut = amounts[amounts.length - 1];
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    // ─── V3 (SwapRouter02 ABI — no deadline in ExactInputSingleParams) ───────────

    /// @notice ETH → token via Uniswap V3 SwapRouter02.
    /// @dev `deadline` is kept for call-site ABI stability but is unused: Router02 has no
    ///      deadline field (classic SwapRouter encoding would misalign and revert on RH).
    function buyTokenV3(
        address sellsman,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline,
        address router,
        uint24 poolFee
    ) external payable nonReentrant {
        deadline; // unused — SwapRouter02 ExactInputSingleParams has no deadline
        sellsman = _resolveSellsman(token, sellsman);
        _trySettleNutboxInjection(token);
        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        // token 先进 Wrapper，扣 0.2% 后净额转用户。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: token,
            fee: poolFee,
            recipient: address(this),
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
        uint256 gross = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 net = _chargeNutboxTokenFee(token, gross);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
    }

    /// @notice Token → ETH via Uniswap V3 SwapRouter02.
    /// @dev `deadline` unused for the same Router02 ABI reason as buyTokenV3.
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
        deadline; // unused — SwapRouter02 ExactInputSingleParams has no deadline
        sellsman = _resolveSellsman(token, sellsman);

        // Snapshot balances so donated/residual ETH/WETH cannot inflate sell fees.
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, amountIn);
        if (!erc20.approve(router, swapIn)) revert ApproveFailed();

        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: WETH,
            fee: poolFee,
            recipient: address(this),
            amountIn: swapIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });
        IUniswapV3SwapRouter(router).exactInputSingle(params);
        erc20.approve(router, 0);

        uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        if (wethOut > 0) {
            IWETH(WETH).withdraw(wethOut);
        }

        uint256 ethOut = address(this).balance - ethBefore;
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
        _trySettleNutboxInjection(token);
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

        // token 先 take 到 Wrapper，扣 0.2% 后净额转用户。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        V4CallbackData memory cb = V4CallbackData({
            payer: address(this),
            recipient: address(this),
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

        uint256 gross = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 net = _chargeNutboxTokenFee(token, gross);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
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
        _trySettleNutboxInjection(token);

        // Snapshot balances so donated/residual ETH/WETH cannot inflate sell fees.
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = ethIsNative ? 0 : IERC20(WETH).balanceOf(address(this));

        IERC20 erc20 = IERC20(token);
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, amountIn);

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
                amountSpecified: -int256(swapIn),
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
            uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
            if (wethOut > 0) {
                IWETH(WETH).withdraw(wethOut);
            }
        }

        uint256 ethOut = address(this).balance - ethBefore;
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
