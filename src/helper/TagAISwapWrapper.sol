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
import "../router/INutboxRouter.sol";
import "../router/NutboxSpotPrice.sol";
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
    /// @dev 平台路由：V3/V4 quote 的第一跳走 NutboxSpotPrice，quote↔native 走 NutboxRouter.quote。
    INutboxRouter public nutboxRouter;

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
    event NutboxRouterUpdated(address indexed nutboxRouter);
    event V4PoolManagerUpdated(address indexed poolManager, bool allowed);

    /// @dev Transient PoolManager for the in-flight V4 unlock callback.
    IPoolManager private _activePoolManager;
    bytes32 private _activeV4CallbackHash;
    mapping(address => bool) public allowedV4PoolManager;

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
    error UnsupportedQuote();
    error InvalidAmount();
    error InvalidPoolManager();
    error InvalidCallbackData();
    error InvalidSwapDelta();

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

    /// @dev 部署后注入 NutboxRouter（Wrapper 先于 Router 部署，避免循环依赖）。
    function adminSetNutboxRouter(address nutboxRouter_) external onlyOwner {
        require(nutboxRouter_ != address(0), "zero nutboxRouter");
        nutboxRouter = INutboxRouter(nutboxRouter_);
        emit NutboxRouterUpdated(nutboxRouter_);
    }

    function adminSetV4PoolManager(address poolManager, bool allowed) external onlyOwner {
        if (poolManager == address(0)) revert InvalidPoolManager();
        allowedV4PoolManager[poolManager] = allowed;
        emit V4PoolManagerUpdated(poolManager, allowed);
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

    event NutboxTokenFeeAccrued(
        address indexed token, address indexed community, uint256 amount, uint256 pendingAmount
    );
    event NutboxTokenFeeInjected(address indexed token, address indexed community, uint256 amount);
    event NutboxTokenFeeInjectionFailed(address indexed token, address indexed community, uint256 amount, bytes reason);
    event FeeRatiosChanged(uint16 sellsmanRatio, uint16 tagaiRatio, uint16 nutboxTokenRatio);

    /// @dev 三参数费率设置（sellsman / tagai / nutboxToken）。
    function adminSetFeeRatios(uint16 sellsmanRatio_, uint16 tagaiRatio_, uint16 nutboxTokenRatio_) external onlyOwner {
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
        // 首笔 fee 起算 10 分钟窗口，避免 lastNutboxInjectionAt 默认 0 + 大 block.timestamp 导致首次立即注入。
        if (lastNutboxInjectionAt[token] == 0) lastNutboxInjectionAt[token] = block.timestamp;
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

        address calc;
        try ICommunity(community).rewardCalculator() returns (address calculator) {
            calc = calculator;
        } catch (bytes memory reason) {
            emit NutboxTokenFeeInjectionFailed(token, community, pending, reason);
            return;
        }
        if (calc == address(0)) return;

        // calculator.inject 通过 transferFrom 拉 token。非标准 approve 或 zero-first token
        // 都不得把维护动作升级成交易 DoS。
        if (!_forceApprove(token, calc, pending)) {
            emit NutboxTokenFeeInjectionFailed(token, community, pending, bytes("APPROVE_FAILED"));
            return;
        }
        try IHourlyTickCalculator(calc).inject(community, pending) {
            pendingNutboxInjection[token] = 0;
            lastNutboxInjectionAt[token] = block.timestamp;
            emit NutboxTokenFeeInjected(token, community, pending);
        } catch (bytes memory reason) {
            // 失败：保留 pending，回滚 approve，交易继续。
            _callOptionalReturnBool(token, abi.encodeCall(IERC20.approve, (calc, 0)));
            emit NutboxTokenFeeInjectionFailed(token, community, pending, reason);
        }
    }

    function _forceApprove(address token, address spender, uint256 amount) private returns (bool) {
        bytes memory approval = abi.encodeCall(IERC20.approve, (spender, amount));
        if (_callOptionalReturnBool(token, approval)) return true;
        return _callOptionalReturnBool(token, abi.encodeCall(IERC20.approve, (spender, 0)))
            && _callOptionalReturnBool(token, approval);
    }

    function _callOptionalReturnBool(address token, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = token.call(data);
        return success && token.code.length > 0
            && (returndata.length == 0 || (returndata.length >= 32 && abi.decode(returndata, (bool))));
    }

    /// @notice 手动触发注入（同样受 10 分钟窗口限制）。返回实际注入量。
    function flushNutboxInjection(address token) external nonReentrant returns (uint256) {
        uint256 pendingBefore = pendingNutboxInjection[token];
        _trySettleNutboxInjection(token);
        return pendingBefore - pendingNutboxInjection[token];
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
        address token = path[path.length - 1];
        sellsman = _resolveSellsman(token, sellsman);

        _trySettleNutboxInjection(token);

        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        // token 先进 Wrapper，扣 0.2% Nutbox fee 后净额转用户（已登记代币）。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IUniswapV2Router02(router).swapExactETHForTokens{value: buyFund}(amountOutMin, path, address(this), deadline);
        uint256 gross = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 net = _chargeNutboxTokenFee(token, gross);
        uint256 recipientBefore = IERC20(token).balanceOf(to);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
        if (IERC20(token).balanceOf(to) - recipientBefore < amountOutMin) revert Slippage();
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
        // 按余额差结算输入（支持 fee-on-transfer 代币）。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balBefore;
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, actualReceived);
        if (!erc20.approve(router, swapIn)) revert ApproveFailed();

        uint256 ethBefore = address(this).balance;
        IUniswapV2Router02(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapIn, 0, path, address(this), deadline
        );
        // Best-effort allowance reset.
        erc20.approve(router, 0);

        uint256 ethOut = address(this).balance - ethBefore;
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        if (remaining < amountOutMin) revert Slippage();
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    // ─── 报价（V2；V3/V4 暂不支持，前端用独立 quoter） ────────────────────────────

    /// @notice V2 买入报价：返回用户实际到账 token（扣 ETH 费 + token 侧 Nutbox fee 后）。
    /// @dev 与真实 buyToken 同向：先扣 ETH 侧 sellsman+tagai 费得 buyFund，再 getAmountsOut，
    ///      再扣已登记代币的 0.2% token fee。
    function quoteBuy(uint256 ethIn, address[] calldata path, address router)
        external
        view
        returns (uint256 netTokenOut)
    {
        if (path.length < 2 || path[0] != WETH) revert InvalidPath();
        address token = path[path.length - 1];
        // ETH 侧费（与 _takeFeesFromEth 一致）。
        uint256 ethFee = (ethIn * (uint256(sellsmanRatio) + uint256(tagaiRatio))) / BPS_DENOMINATOR;
        uint256 buyFund = ethIn - ethFee;
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(buyFund, path);
        uint256 grossTokenOut = amounts[amounts.length - 1];
        // 已登记代币扣 0.2% token fee。
        if (_importedCommunity(token) != address(0) && nutboxTokenRatio > 0) {
            uint256 tokenFee = (grossTokenOut * nutboxTokenRatio) / BPS_DENOMINATOR;
            netTokenOut = grossTokenOut - tokenFee;
        } else {
            netTokenOut = grossTokenOut;
        }
    }

    /// @notice V2 卖出报价：返回用户实际到账 ETH（扣 token 侧 Nutbox fee + ETH 费后）。
    /// @dev 与真实 sellToken 同向：先扣已登记代币 0.2% token fee 得 swapIn，再 getAmountsOut，
    ///      再扣 ETH 侧 sellsman+tagai 费。
    function quoteSell(uint256 amountIn, address[] calldata path, address router)
        external
        view
        returns (uint256 netEthOut)
    {
        if (path.length < 2 || path[path.length - 1] != WETH) revert InvalidPath();
        address token = path[0];
        // 已登记代币扣 0.2% token fee。
        uint256 swapIn = amountIn;
        if (_importedCommunity(token) != address(0) && nutboxTokenRatio > 0) {
            uint256 tokenFee = (amountIn * nutboxTokenRatio) / BPS_DENOMINATOR;
            swapIn = amountIn - tokenFee;
        }
        uint256[] memory amounts = IUniswapV2Router02(router).getAmountsOut(swapIn, path);
        uint256 grossEthOut = amounts[amounts.length - 1];
        uint256 ethFee = (grossEthOut * (uint256(sellsmanRatio) + uint256(tagaiRatio))) / BPS_DENOMINATOR;
        netEthOut = grossEthOut - ethFee;
    }

    /// @notice 任意 DEX 源买入报价：ETH 费 → native↔quote → 第一跳现货 → token Nutbox fee。
    /// @dev 与 BSC ImportedTokenSwapWrapper 同形。第一跳用 NutboxSpotPrice；quote≠WETH 时走 NutboxRouter.quote。
    function quoteBuy(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 nativeAmountIn
    ) external returns (uint256 tokenAmountOut) {
        if (nativeAmountIn == 0) revert InvalidAmount();
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);
        uint256 ethFee = (nativeAmountIn * (uint256(sellsmanRatio) + uint256(tagaiRatio))) / BPS_DENOMINATOR;
        uint256 quoteAmount = _quoteNativeToQuote(quoteToken, nativeAmountIn - ethFee);
        uint256 grossTokenAmount = _quoteFirstHop(sourceType, sourceData, quoteToken, token, quoteAmount);
        tokenAmountOut = _previewTokenFee(token, grossTokenAmount);
    }

    /// @notice 任意 DEX 源卖出报价：token Nutbox fee → 第一跳现货 → quote↔native → ETH 费。
    function quoteSell(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 tokenAmountIn
    ) external returns (uint256 nativeAmountOut) {
        if (tokenAmountIn == 0) revert InvalidAmount();
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);
        uint256 swapTokenAmount = _previewTokenFee(token, tokenAmountIn);
        uint256 quoteAmount = _quoteFirstHop(sourceType, sourceData, token, quoteToken, swapTokenAmount);
        uint256 grossNativeAmount = _quoteQuoteToNative(quoteToken, quoteAmount);
        uint256 ethFee = (grossNativeAmount * (uint256(sellsmanRatio) + uint256(tagaiRatio))) / BPS_DENOMINATOR;
        nativeAmountOut = grossNativeAmount - ethFee;
    }

    /// @dev 旧 ABI 保留：请改用 quoteBuy(token, V3_POOL, abi.encode(factory, pool), amount)。
    function quoteBuyV3(address, uint256, address, address, uint24) external pure returns (uint256) {
        revert UnsupportedQuote();
    }

    function quoteSellV3(uint256, address, address, uint24) external pure returns (uint256) {
        revert UnsupportedQuote();
    }

    function quoteBuyV4(PoolKey calldata, IPoolManager, uint160) external pure returns (uint256) {
        revert UnsupportedQuote();
    }

    function quoteSellV4(uint256, PoolKey calldata, IPoolManager, uint160) external pure returns (uint256) {
        revert UnsupportedQuote();
    }

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
        uint256 recipientBefore = IERC20(token).balanceOf(to);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
        if (IERC20(token).balanceOf(to) - recipientBefore < amountOutMin) revert Slippage();
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
        _trySettleNutboxInjection(token);

        // Snapshot balances so donated/residual ETH/WETH cannot inflate sell fees.
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));

        IERC20 erc20 = IERC20(token);
        // 按余额差结算输入（支持 fee-on-transfer）。
        uint256 tokenBalBefore = IERC20(token).balanceOf(address(this));
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - tokenBalBefore;
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, actualReceived);
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
        if (remaining < amountOutMin) revert Slippage();
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
        if (!allowedV4PoolManager[address(poolManager)]) revert InvalidPoolManager();
        sellsman = _resolveSellsman(token, sellsman);
        _trySettleNutboxInjection(token);
        uint256 buyFund = _takeFeesFromEth(msg.value, sellsman);

        // If the ETH leg is WETH (not native), wrap before unlock settle.
        if (!ethIsNative) {
            IWETH(WETH).deposit{value: buyFund}();
        }

        bool zeroForOne = ethIsCurrency0;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        // token 先 take 到 Wrapper，扣 0.2% 后净额转用户。
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        V4CallbackData memory cb = V4CallbackData({
            payer: address(this),
            recipient: address(this),
            key: poolKey,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(buyFund), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            amountOutMin: amountOutMin,
            ethIsCurrency0: ethIsCurrency0,
            ethIsNative: ethIsNative
        });

        bytes memory callbackData = abi.encode(cb);
        _activePoolManager = poolManager;
        _activeV4CallbackHash = keccak256(callbackData);
        poolManager.unlock(callbackData);
        _activeV4CallbackHash = bytes32(0);
        _activePoolManager = IPoolManager(address(0));

        uint256 gross = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 net = _chargeNutboxTokenFee(token, gross);
        uint256 recipientBefore = IERC20(token).balanceOf(to);
        if (net > 0) {
            if (!IERC20(token).transfer(to, net)) revert TransferFailed();
        }
        if (IERC20(token).balanceOf(to) - recipientBefore < amountOutMin) revert Slippage();
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
        if (!allowedV4PoolManager[address(poolManager)]) revert InvalidPoolManager();
        sellsman = _resolveSellsman(token, sellsman);
        _trySettleNutboxInjection(token);

        // Snapshot balances so donated/residual ETH/WETH cannot inflate sell fees.
        uint256 ethBefore = address(this).balance;
        uint256 wethBefore = ethIsNative ? 0 : IERC20(WETH).balanceOf(address(this));

        IERC20 erc20 = IERC20(token);
        // 按余额差结算输入（支持 fee-on-transfer）。
        uint256 tokenBalBefore = IERC20(token).balanceOf(address(this));
        if (!erc20.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - tokenBalBefore;
        // 已登记代币：从卖出 token 扣 0.2% Nutbox fee，剩余进 swap。
        uint256 swapIn = _chargeNutboxTokenFee(token, actualReceived);

        // Selling token for ETH: zeroForOne is true when token is currency0.
        bool zeroForOne = !ethIsCurrency0;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        V4CallbackData memory cb = V4CallbackData({
            payer: address(this),
            recipient: address(this), // take ETH/WETH here, then fee-split
            key: poolKey,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(swapIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            amountOutMin: amountOutMin,
            ethIsCurrency0: ethIsCurrency0,
            ethIsNative: ethIsNative
        });

        bytes memory callbackData = abi.encode(cb);
        _activePoolManager = poolManager;
        _activeV4CallbackHash = keccak256(callbackData);
        poolManager.unlock(callbackData);
        _activeV4CallbackHash = bytes32(0);
        _activePoolManager = IPoolManager(address(0));

        if (!ethIsNative) {
            uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
            if (wethOut > 0) {
                IWETH(WETH).withdraw(wethOut);
            }
        }

        uint256 ethOut = address(this).balance - ethBefore;
        uint256 remaining = _takeFeesFromEth(ethOut, sellsman);
        if (remaining < amountOutMin) revert Slippage();
        (bool ok,) = to.call{value: remaining}("");
        if (!ok) revert TransferToFailed();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(_activePoolManager)) revert OnlyPoolManager();
        if (keccak256(rawData) != _activeV4CallbackHash) revert InvalidCallbackData();
        IPoolManager manager = _activePoolManager;

        V4CallbackData memory data = abi.decode(rawData, (V4CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, bytes(""));

        // Exact-in: input currency delta is negative; output is positive.
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        int128 inputDelta = data.params.zeroForOne ? amount0 : amount1;
        int128 outputDelta = data.params.zeroForOne ? amount1 : amount0;
        uint256 expectedInput = uint256(-data.params.amountSpecified);
        if (
            inputDelta >= 0 || outputDelta <= 0 || uint256(uint128(-inputDelta)) != expectedInput
        ) revert InvalidSwapDelta();

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

    // ─── NutboxRouter 报价辅助 ─────────────────────────────────────────────────

    /// @dev 池的另一侧。Uniswap V4 native ETH 池可能返回 address(0)，与 WETH 同等视为 native hop。
    function _resolveQuoteToken(address token, INutboxRouter.SourceType sourceType, bytes memory sourceData)
        internal
        view
        returns (address quoteToken)
    {
        if (token == address(0) || address(nutboxRouter) == address(0)) revert UnsupportedQuote();
        quoteToken = NutboxSpotPrice.otherToken(token, sourceType, sourceData);
    }

    function _quoteNativeToQuote(address quoteToken, uint256 nativeAmount) internal view returns (uint256 quoteAmount) {
        if (quoteToken == address(0) || quoteToken == WETH) return nativeAmount;
        quoteAmount = nutboxRouter.quote(WETH, quoteToken, nativeAmount);
        if (quoteAmount == 0) revert UnsupportedQuote();
    }

    function _quoteQuoteToNative(address quoteToken, uint256 quoteAmount) internal view returns (uint256 nativeAmount) {
        if (quoteToken == address(0) || quoteToken == WETH) return quoteAmount;
        nativeAmount = nutboxRouter.quote(quoteToken, WETH, quoteAmount);
        if (nativeAmount == 0) revert UnsupportedQuote();
    }

    /// @dev 第一跳现货（无冲击）。V2/V3 不接受 native address(0)，先归一到 WETH。
    function _quoteFirstHop(
        INutboxRouter.SourceType sourceType,
        bytes memory sourceData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        if (sourceType != INutboxRouter.SourceType.UNISWAP_V4 && sourceType != INutboxRouter.SourceType.PANCAKE_V4_CL) {
            if (tokenIn == address(0)) tokenIn = WETH;
            if (tokenOut == address(0)) tokenOut = WETH;
        }
        amountOut = NutboxSpotPrice.quote(nutboxRouter, tokenIn, tokenOut, amountIn, sourceType, sourceData);
    }

    function _previewTokenFee(address token, uint256 tokenAmount) internal view returns (uint256 netAmount) {
        if (_importedCommunity(token) == address(0) || nutboxTokenRatio == 0) return tokenAmount;
        uint256 fee = (tokenAmount * nutboxTokenRatio) / BPS_DENOMINATOR;
        return tokenAmount - fee;
    }
}
