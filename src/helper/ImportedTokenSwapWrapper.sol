// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import {ICLPoolManager as IPancakeV4CLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IPoolManager as IPancakeV4PoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IVault as IPancakeV4Vault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks as IPancakeV4Hooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey as PancakeV4PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency as PancakeV4Currency} from "infinity-core/src/types/Currency.sol";
import {
    BalanceDelta as PancakeV4BalanceDelta,
    BalanceDeltaLibrary as PancakeV4BalanceDeltaLibrary
} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath as PancakeV4TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import "../router/INutboxRouter.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IHourlyTickCalculator.sol";
import "../interfaces/ICommunity.sol";

interface IImportedV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IImportedV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IImportedPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IImportedPancakeV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IImportedPancakeV4Quoter {
    struct QuoteExactInputSingleParams {
        PancakeV4PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IImportedV3Pool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function fee() external view returns (uint24);
}

interface IImportedWrappedNative {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

/**
 * @title ImportedTokenSwapWrapper
 * @notice Trades imported tokens through a caller-supplied external pool and uses NutboxRouter only
 *         for the quote-token/native bridge when the pool is not paired with wrapped native.
 * @dev ImportHelper binds imported tokens to their Community and deployer. Every quote and trade
 *      uses caller-supplied DEX data. Registered tokens accrue their token-side fee to the bound
 *      Community. NutboxRouter is used only for an optional quote-token/native bridge. Supports V2
 *      Router02, Pancake/SwapRouter02-compatible V3 and Pancake Infinity CL; Uniswap V4 is excluded.
 *      V2 trades account by actual balance deltas so fee-on-transfer tokens are supported. V3 buys
 *      also accept taxed output tokens, while V3 sells and Infinity CL retain exact-input accounting.
 */
contract ImportedTokenSwapWrapper is Ownable2Step, Pausable, ReentrancyGuard, ILockCallback {
    using Address for address payable;
    using PancakeV4BalanceDeltaLibrary for PancakeV4BalanceDelta;
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_TOTAL_FEE_BPS = 2_000;
    uint256 public constant NUTBOX_INJECTION_INTERVAL = 10 minutes;

    INutboxRouter public immutable nutboxRouter;
    address public immutable wrappedNative;

    address public feeAddress;
    IIPShare public ipshare;
    address public registrar;
    uint16 public sellsmanRatio = 20;
    uint16 public tagaiRatio = 20;
    uint16 public nutboxTokenRatio = 20;

    struct V2Source {
        address router;
        address pair;
    }

    struct V3Source {
        address router;
        address quoter;
        address pool;
    }

    struct PancakeV4Source {
        address quoter;
        INutboxRouter.PancakeV4CLSource pool;
    }

    struct ImportedMarket {
        bool registered;
        address community;
        address deployer;
    }

    mapping(address => ImportedMarket) private _importedMarkets;
    mapping(address => uint256) public pendingNutboxInjection;
    mapping(address => uint256) public lastNutboxInjectionAt;

    address private _activeCallback;
    bytes32 private _activeCallbackHash;

    event FeeAddressChanged(address indexed previousFeeAddress, address indexed newFeeAddress);
    event IPShareChanged(address indexed previousIPShare, address indexed newIPShare);
    event RegistrarChanged(address indexed previousRegistrar, address indexed newRegistrar);
    event FeeRatiosChanged(uint16 sellsmanRatio, uint16 tagaiRatio, uint16 nutboxTokenRatio);
    event ImportedMarketRegistered(address indexed token, address indexed community, address indexed deployer);
    event ImportedMarketUpdated(
        address indexed token,
        address indexed previousCommunity,
        address indexed newCommunity,
        address previousDeployer,
        address newDeployer
    );
    event NutboxTokenFeeAccrued(
        address indexed token, address indexed community, uint256 amount, uint256 pendingAmount
    );
    event NutboxTokenFeeInjected(address indexed token, address indexed community, uint256 amount);
    event NutboxTokenFeeInjectionFailed(address indexed token, address indexed community, uint256 amount, bytes reason);
    event Trade(
        address indexed buyer,
        address indexed sellsman,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tiptagFee,
        uint256 sellsmanFee
    );
    /// @notice Canonical wrapper trade event for subgraphs and accounting consumers.
    /// @dev Native amounts are gross/net around wrapper fees; tokenAmount is the actual amount delivered/received.
    event ImportedTokenTrade(
        address indexed trader,
        address indexed token,
        address indexed sellsman,
        bool isBuy,
        address quoteToken,
        INutboxRouter.SourceType sourceType,
        bytes32 sourceHash,
        uint256 tokenAmount,
        uint256 grossNativeAmount,
        uint256 netNativeAmount,
        uint256 tagaiFee,
        uint256 sellsmanFee,
        uint256 nutboxTokenFee,
        address recipient
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidMarket();
    error InvalidFeeRatio();
    error UnauthorizedRegistrar();
    error MarketAlreadyRegistered();
    error MarketNotRegistered();
    error PendingNutboxInjectionExists(address token, uint256 amount);
    error InjectionIntervalActive();
    error DeadlineExpired();
    error UnsupportedSwapSource();
    error UnsupportedInputToken();
    error InvalidSwapOutput();
    error SlippageExceeded();
    error InvalidNativeSender();
    error InvalidCallback();
    error NativeTransferFailed();

    constructor(address nutboxRouter_, address feeAddress_, address ipshare_) {
        if (
            nutboxRouter_.code.length == 0 || ipshare_.code.length == 0 || feeAddress_ == address(0)
                || feeAddress_ == address(this)
        ) {
            revert InvalidAddress();
        }
        nutboxRouter = INutboxRouter(nutboxRouter_);
        address wrappedNative_ = INutboxRouter(nutboxRouter_).wrappedNative();
        if (wrappedNative_.code.length == 0) revert InvalidAddress();
        wrappedNative = wrappedNative_;
        feeAddress = feeAddress_;
        ipshare = IIPShare(ipshare_);
    }

    receive() external payable {
        if (msg.sender != wrappedNative && msg.sender != address(nutboxRouter) && msg.sender != _activeCallback) {
            revert InvalidNativeSender();
        }
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    function setFeeAddress(address newFeeAddress) external onlyOwner {
        if (newFeeAddress == address(0) || newFeeAddress == address(this)) revert InvalidAddress();
        address previousFeeAddress = feeAddress;
        feeAddress = newFeeAddress;
        emit FeeAddressChanged(previousFeeAddress, newFeeAddress);
    }

    function setIPShare(address newIPShare) external onlyOwner {
        if (newIPShare == address(this) || newIPShare.code.length == 0) revert InvalidAddress();
        address previousIPShare = address(ipshare);
        ipshare = IIPShare(newIPShare);
        emit IPShareChanged(previousIPShare, newIPShare);
    }

    function setFeeRatios(uint16 sellsmanRatio_, uint16 tagaiRatio_, uint16 nutboxTokenRatio_) external onlyOwner {
        if (uint256(sellsmanRatio_) + uint256(tagaiRatio_) > MAX_TOTAL_FEE_BPS || nutboxTokenRatio_ > MAX_TOTAL_FEE_BPS)
        {
            revert InvalidFeeRatio();
        }
        sellsmanRatio = sellsmanRatio_;
        tagaiRatio = tagaiRatio_;
        nutboxTokenRatio = nutboxTokenRatio_;
        emit FeeRatiosChanged(sellsmanRatio_, tagaiRatio_, nutboxTokenRatio_);
    }

    function setRegistrar(address newRegistrar) external onlyOwner {
        if (newRegistrar == address(this)) revert InvalidAddress();
        address previousRegistrar = registrar;
        registrar = newRegistrar;
        emit RegistrarChanged(previousRegistrar, newRegistrar);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function registerImportedToken(address token, address community, address deployer) external {
        if (msg.sender != registrar && msg.sender != owner()) revert UnauthorizedRegistrar();
        if (_importedMarkets[token].registered) revert MarketAlreadyRegistered();
        _storeImportedMarket(token, community, deployer);
        emit ImportedMarketRegistered(token, community, deployer);
    }

    /// @notice Manually updates the Community and deployer bound to a registered imported token.
    /// @dev Only the owner may correct a binding. A Community change is rejected while token
    ///      rewards are pending so fees accrued for the previous Community cannot be redirected.
    function updateImportedMarket(address token, address community, address deployer) external onlyOwner {
        ImportedMarket storage market = _importedMarkets[token];
        if (!market.registered) revert MarketNotRegistered();
        if (token.code.length == 0 || community.code.length == 0 || deployer == address(0)) revert InvalidMarket();

        address previousCommunity = market.community;
        address previousDeployer = market.deployer;
        if (community != previousCommunity) {
            uint256 pending = pendingNutboxInjection[token];
            if (pending != 0) revert PendingNutboxInjectionExists(token, pending);
            lastNutboxInjectionAt[token] = block.timestamp;
        }

        market.community = community;
        market.deployer = deployer;
        emit ImportedMarketUpdated(token, previousCommunity, community, previousDeployer, deployer);
    }

    function getImportedMarket(address token)
        external
        view
        returns (bool registered, address community, address deployer)
    {
        ImportedMarket storage market = _importedMarkets[token];
        return (market.registered, market.community, market.deployer);
    }

    // -------------------------------------------------------------------------
    // Source decoding and views
    // -------------------------------------------------------------------------

    /**
     * @notice Resolves the quote asset from caller-supplied DEX data.
     * @dev This only decodes/reads pool endpoints. The actual DEX call is the source of truth.
     */
    function resolveQuoteToken(address token, INutboxRouter.SourceType sourceType, bytes memory sourceData)
        public
        view
        returns (address quoteToken)
    {
        return _resolveQuoteToken(token, sourceType, sourceData);
    }

    function _resolveQuoteToken(address token, INutboxRouter.SourceType sourceType, bytes memory sourceData)
        internal
        view
        returns (address quoteToken)
    {
        if (token == address(0)) revert InvalidMarket();
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            V2Source memory source = abi.decode(sourceData, (V2Source));
            quoteToken =
                _otherToken(token, IImportedV2Pair(source.pair).token0(), IImportedV2Pair(source.pair).token1());
        } else if (sourceType == INutboxRouter.SourceType.V3_POOL) {
            V3Source memory source = abi.decode(sourceData, (V3Source));
            quoteToken =
                _otherToken(token, IImportedV3Pool(source.pool).token0(), IImportedV3Pool(source.pool).token1());
        } else if (sourceType == INutboxRouter.SourceType.PANCAKE_V4_CL) {
            PancakeV4Source memory source = abi.decode(sourceData, (PancakeV4Source));
            quoteToken = _otherToken(token, source.pool.currency0, source.pool.currency1);
        } else {
            revert UnsupportedSwapSource();
        }
    }

    function previewFees(uint256 nativeAmount)
        external
        view
        returns (uint256 amountAfterFees, uint256 tagaiFee, uint256 sellsmanFee)
    {
        return _feeAmounts(nativeAmount);
    }

    function previewTokenFee(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 amountAfterFee, uint256 nutboxFee)
    {
        address community = _importedMarkets[token].community;
        return _tokenFeeAmounts(tokenAmount, community);
    }

    function flushNutboxInjection(address token) external nonReentrant returns (uint256 injectedAmount) {
        ImportedMarket storage market = _importedMarkets[token];
        if (!market.registered) revert MarketNotRegistered();
        if (block.timestamp < lastNutboxInjectionAt[token] + NUTBOX_INJECTION_INTERVAL) {
            revert InjectionIntervalActive();
        }
        injectedAmount = pendingNutboxInjection[token];
        if (injectedAmount != 0 && !_tryInjectPending(token, market.community, injectedAmount)) injectedAmount = 0;
    }

    /**
     * @notice Estimates the final imported-token output for a native-coin buy.
     * @dev Wrapper fees are deducted before quoting the complete route. V2 token transfer taxes are
     *      dynamic token behavior and are not included in this theoretical pool quote.
     */
    function quoteBuy(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 nativeAmountIn
    ) external returns (uint256 tokenAmountOut) {
        if (nativeAmountIn == 0) revert InvalidAmount();
        address community = _importedMarkets[token].community;
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);
        (uint256 swapAmount,,) = _feeAmounts(nativeAmountIn);
        uint256 quoteAmount = _quoteNativeToQuote(quoteToken, swapAmount);
        uint256 grossTokenAmount = _quoteFirstHop(sourceType, sourceData, quoteToken, token, quoteAmount);
        (tokenAmountOut,) = _tokenFeeAmounts(grossTokenAmount, community);
    }

    /**
     * @notice Estimates the final net native-coin output for an imported-token sell.
     * @dev The returned output has wrapper fees deducted. V2 token transfer taxes are dynamic token
     *      behavior and are not included in this theoretical pool quote.
     */
    function quoteSell(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 tokenAmountIn
    ) external returns (uint256 nativeAmountOut) {
        if (tokenAmountIn == 0) revert InvalidAmount();
        address community = _importedMarkets[token].community;
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);
        (uint256 swapTokenAmount,) = _tokenFeeAmounts(tokenAmountIn, community);
        uint256 quoteAmount = _quoteFirstHop(sourceType, sourceData, token, quoteToken, swapTokenAmount);
        uint256 grossNativeAmount = _quoteQuoteToNative(quoteToken, quoteAmount);
        (nativeAmountOut,,) = _feeAmounts(grossNativeAmount);
    }

    // -------------------------------------------------------------------------
    // Trading
    // -------------------------------------------------------------------------

    /// @notice Buys an imported token with native coin.
    /// @param minimumTokenOut Minimum final token amount delivered to recipient.
    /// @param sourceData DEX data used for this trade.
    function buyToken(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 minimumTokenOut,
        address recipient,
        uint256 deadline,
        address sellsman
    ) external payable nonReentrant whenNotPaused returns (uint256 tokenOut) {
        _validateTrade(msg.value, recipient, deadline);
        ImportedMarket storage market = _importedMarkets[token];
        address community = market.community;
        address deployer = market.deployer;
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);

        sellsman = _resolvedSellsman(sellsman, deployer);
        uint256 swapAmount;
        uint256 tagaiFee;
        uint256 sellsmanFee;
        (swapAmount, tagaiFee, sellsmanFee, sellsman) = _takeFees(msg.value, sellsman);

        uint256 quoteAmount = _quoteForBuy(quoteToken, swapAmount, deadline);
        uint256 grossTokenOut = _executeFirstHop(sourceType, sourceData, quoteToken, token, quoteAmount, 0, deadline);
        uint256 nutboxTokenFee;
        (tokenOut, nutboxTokenFee) = _tokenFeeAmounts(grossTokenOut, community);
        bool allowTaxedOutput =
            sourceType == INutboxRouter.SourceType.V2_PAIR || sourceType == INutboxRouter.SourceType.V3_POOL;
        tokenOut = _deliverToken(token, tokenOut, recipient, allowTaxedOutput);
        if (tokenOut < minimumTokenOut) revert SlippageExceeded();
        _accrueNutboxTokenFee(token, community, nutboxTokenFee);

        emit Trade(msg.sender, sellsman, true, tokenOut, msg.value, tagaiFee, sellsmanFee);
        emit ImportedTokenTrade(
            msg.sender,
            token,
            sellsman,
            true,
            quoteToken,
            sourceType,
            keccak256(sourceData),
            tokenOut,
            msg.value,
            swapAmount,
            tagaiFee,
            sellsmanFee,
            nutboxTokenFee,
            recipient
        );
    }

    /// @notice Sells an exact imported-token amount for native coin.
    /// @param minimumNativeOut Minimum native coin delivered to recipient after wrapper fees.
    /// @param sourceData DEX data used for this trade.
    function sellToken(
        address token,
        INutboxRouter.SourceType sourceType,
        bytes calldata sourceData,
        uint256 amountIn,
        uint256 minimumNativeOut,
        address recipient,
        uint256 deadline,
        address sellsman
    ) external nonReentrant whenNotPaused returns (uint256 nativeOut) {
        _validateTrade(amountIn, recipient, deadline);
        ImportedMarket storage market = _importedMarkets[token];
        address community = market.community;
        address deployer = market.deployer;
        address quoteToken = _resolveQuoteToken(token, sourceType, sourceData);
        sellsman = _resolvedSellsman(sellsman, deployer);

        uint256 receivedAmount = _receiveToken(token, amountIn);
        if (sourceType != INutboxRouter.SourceType.V2_PAIR && receivedAmount != amountIn) {
            revert UnsupportedInputToken();
        }
        uint256 swapTokenAmount;
        uint256 nutboxTokenFee;
        (swapTokenAmount, nutboxTokenFee) = _tokenFeeAmounts(receivedAmount, community);
        uint256 quoteOut = _executeFirstHop(sourceType, sourceData, token, quoteToken, swapTokenAmount, 0, deadline);
        uint256 grossNativeOut = _nativeForSell(quoteToken, quoteOut, deadline);

        uint256 tagaiFee;
        uint256 sellsmanFee;
        (nativeOut, tagaiFee, sellsmanFee, sellsman) = _takeFees(grossNativeOut, sellsman);
        if (nativeOut < minimumNativeOut) revert SlippageExceeded();
        payable(recipient).sendValue(nativeOut);
        _accrueNutboxTokenFee(token, community, nutboxTokenFee);

        emit Trade(msg.sender, sellsman, false, receivedAmount, grossNativeOut, tagaiFee, sellsmanFee);
        emit ImportedTokenTrade(
            msg.sender,
            token,
            sellsman,
            false,
            quoteToken,
            sourceType,
            keccak256(sourceData),
            receivedAmount,
            grossNativeOut,
            nativeOut,
            tagaiFee,
            sellsmanFee,
            nutboxTokenFee,
            recipient
        );
    }

    // -------------------------------------------------------------------------
    // V4 callbacks
    // -------------------------------------------------------------------------

    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != _activeCallback || keccak256(data) != _activeCallbackHash) revert InvalidCallback();
        (INutboxRouter.PancakeV4CLSource memory source, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (INutboxRouter.PancakeV4CLSource, bool, uint256));

        IPancakeV4CLPoolManager manager = IPancakeV4CLPoolManager(source.poolManager);
        IPancakeV4Vault vault = manager.vault();
        if (address(vault) != msg.sender) revert InvalidCallback();
        _activeCallbackHash = bytes32(0);
        return abi.encode(_executePancakeV4Swap(source, zeroForOne, amountIn, manager, vault));
    }

    // -------------------------------------------------------------------------
    // Trading internals
    // -------------------------------------------------------------------------

    function _quoteForBuy(address quoteToken, uint256 nativeAmount, uint256 deadline)
        internal
        returns (uint256 quoteAmount)
    {
        if (quoteToken == address(0)) {
            return nativeAmount;
        }
        if (quoteToken == wrappedNative) {
            uint256 wrappedBalanceBefore = IERC20(wrappedNative).balanceOf(address(this));
            IImportedWrappedNative(wrappedNative).deposit{value: nativeAmount}();
            if (IERC20(wrappedNative).balanceOf(address(this)) - wrappedBalanceBefore != nativeAmount) {
                revert InvalidSwapOutput();
            }
            return nativeAmount;
        }

        uint256 quoteBalanceBefore = IERC20(quoteToken).balanceOf(address(this));
        quoteAmount = nutboxRouter.swapExactInput{value: nativeAmount}(
            address(0), quoteToken, nativeAmount, 0, address(this), deadline
        );
        if (IERC20(quoteToken).balanceOf(address(this)) - quoteBalanceBefore != quoteAmount) {
            revert InvalidSwapOutput();
        }
    }

    function _nativeForSell(address quoteToken, uint256 quoteAmount, uint256 deadline)
        internal
        returns (uint256 nativeOut)
    {
        if (quoteToken == address(0)) {
            nativeOut = quoteAmount;
        } else if (quoteToken == wrappedNative) {
            uint256 balanceBefore = address(this).balance;
            IImportedWrappedNative(wrappedNative).withdraw(quoteAmount);
            nativeOut = address(this).balance - balanceBefore;
            if (nativeOut != quoteAmount) revert InvalidSwapOutput();
        } else {
            uint256 balanceBefore = address(this).balance;
            IERC20(quoteToken).forceApprove(address(nutboxRouter), quoteAmount);
            nativeOut = nutboxRouter.swapExactInput(quoteToken, address(0), quoteAmount, 0, address(this), deadline);
            IERC20(quoteToken).forceApprove(address(nutboxRouter), 0);
            if (address(this).balance - balanceBefore != nativeOut) revert InvalidSwapOutput();
        }

        if (nativeOut == 0) revert InvalidSwapOutput();
    }

    function _quoteNativeToQuote(address quoteToken, uint256 nativeAmount) internal view returns (uint256 quoteAmount) {
        if (quoteToken == address(0) || quoteToken == wrappedNative) return nativeAmount;
        quoteAmount = nutboxRouter.quote(wrappedNative, quoteToken, nativeAmount);
        if (quoteAmount == 0) revert InvalidSwapOutput();
    }

    function _quoteQuoteToNative(address quoteToken, uint256 quoteAmount) internal view returns (uint256 nativeAmount) {
        if (quoteToken == address(0) || quoteToken == wrappedNative) return quoteAmount;
        nativeAmount = nutboxRouter.quote(quoteToken, wrappedNative, quoteAmount);
        if (nativeAmount == 0) revert InvalidSwapOutput();
    }

    function _quoteFirstHop(
        INutboxRouter.SourceType sourceType,
        bytes memory sourceData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        if (tokenIn == address(0) && sourceType != INutboxRouter.SourceType.PANCAKE_V4_CL) {
            revert UnsupportedSwapSource();
        }
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            V2Source memory source = abi.decode(sourceData, (V2Source));
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
            uint256[] memory amounts = IImportedV2Router(source.router).getAmountsOut(amountIn, path);
            if (amounts.length != 2 || amounts[0] != amountIn) revert InvalidSwapOutput();
            amountOut = amounts[1];
        } else if (sourceType == INutboxRouter.SourceType.V3_POOL) {
            V3Source memory source = abi.decode(sourceData, (V3Source));
            (amountOut,,,) = IImportedPancakeV3Quoter(source.quoter)
                .quoteExactInputSingle(
                    IImportedPancakeV3Quoter.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountIn,
                    fee: IImportedV3Pool(source.pool).fee(),
                    sqrtPriceLimitX96: 0
                })
                );
        } else if (sourceType == INutboxRouter.SourceType.PANCAKE_V4_CL) {
            if (amountIn > type(uint128).max) revert InvalidAmount();
            PancakeV4Source memory source = abi.decode(sourceData, (PancakeV4Source));
            bool zeroForOne = _validateV4Direction(tokenIn, tokenOut, source.pool.currency0, source.pool.currency1);
            (amountOut,) = IImportedPancakeV4Quoter(source.quoter)
                .quoteExactInputSingle(
                    IImportedPancakeV4Quoter.QuoteExactInputSingleParams({
                    poolKey: _pancakeV4PoolKey(source.pool),
                    zeroForOne: zeroForOne,
                    exactAmount: uint128(amountIn),
                    hookData: ""
                })
                );
        } else {
            revert UnsupportedSwapSource();
        }
        if (amountOut == 0) revert InvalidSwapOutput();
    }

    function _executeFirstHop(
        INutboxRouter.SourceType sourceType,
        bytes memory sourceData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            amountOut = _swapV2(tokenIn, tokenOut, amountIn, deadline, sourceData);
        } else if (sourceType == INutboxRouter.SourceType.V3_POOL) {
            amountOut = _swapV3(tokenIn, tokenOut, amountIn, sourceData);
        } else if (sourceType == INutboxRouter.SourceType.PANCAKE_V4_CL) {
            amountOut = _swapPancakeV4(tokenIn, tokenOut, amountIn, sourceData);
        } else {
            revert UnsupportedSwapSource();
        }

        if (amountOut == 0 || amountOut < amountOutMinimum) revert SlippageExceeded();
    }

    function _swapV2(address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert UnsupportedSwapSource();
        V2Source memory source = abi.decode(sourceData, (V2Source));

        IERC20 outputToken = IERC20(tokenOut);
        uint256 balanceBefore = outputToken.balanceOf(address(this));
        IERC20(tokenIn).forceApprove(source.router, amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IImportedV2Router(source.router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), deadline);
        IERC20(tokenIn).forceApprove(source.router, 0);
        amountOut = outputToken.balanceOf(address(this)) - balanceBefore;
        if (amountOut == 0) revert InvalidSwapOutput();
    }

    function _swapV3(address tokenIn, address tokenOut, uint256 amountIn, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert UnsupportedSwapSource();
        V3Source memory source = abi.decode(sourceData, (V3Source));
        IImportedV3Pool pool = IImportedV3Pool(source.pool);
        uint24 fee = pool.fee();

        IERC20 outputToken = IERC20(tokenOut);
        uint256 balanceBefore = outputToken.balanceOf(address(this));
        IERC20(tokenIn).forceApprove(source.router, amountIn);
        IImportedPancakeV3Router.ExactInputSingleParams memory params = IImportedPancakeV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        IImportedPancakeV3Router(source.router).exactInputSingle(params);
        IERC20(tokenIn).forceApprove(source.router, 0);
        amountOut = outputToken.balanceOf(address(this)) - balanceBefore;
        if (amountOut == 0) revert InvalidSwapOutput();
    }

    function _swapPancakeV4(address tokenIn, address tokenOut, uint256 amountIn, bytes memory sourceData)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        PancakeV4Source memory configuredSource = abi.decode(sourceData, (PancakeV4Source));
        INutboxRouter.PancakeV4CLSource memory source = configuredSource.pool;
        bool zeroForOne = _validateV4Direction(tokenIn, tokenOut, source.currency0, source.currency1);
        IPancakeV4CLPoolManager manager = IPancakeV4CLPoolManager(source.poolManager);
        IPancakeV4Vault vault = manager.vault();

        uint256 balanceBefore = _assetBalance(tokenOut);
        if (vault.getLocker() != address(0)) revert InvalidCallback();
        bytes memory callbackData = abi.encode(source, zeroForOne, amountIn);
        _activeCallback = address(vault);
        _activeCallbackHash = keccak256(callbackData);
        amountOut = abi.decode(vault.lock(callbackData), (uint256));
        _activeCallback = address(0);
        _activeCallbackHash = bytes32(0);
        if (amountOut == 0 || _assetBalance(tokenOut) - balanceBefore != amountOut) revert InvalidSwapOutput();
    }

    function _executePancakeV4Swap(
        INutboxRouter.PancakeV4CLSource memory source,
        bool zeroForOne,
        uint256 amountIn,
        IPancakeV4CLPoolManager manager,
        IPancakeV4Vault vault
    ) internal returns (uint256 amountOut) {
        PancakeV4PoolKey memory key = _pancakeV4PoolKey(source);
        PancakeV4BalanceDelta delta = manager.swap(
            key,
            IPancakeV4CLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? PancakeV4TickMath.MIN_SQRT_RATIO + 1
                    : PancakeV4TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );

        amountOut = _validatePancakeV4Delta(delta, zeroForOne, amountIn);
        PancakeV4Currency input = zeroForOne ? key.currency0 : key.currency1;
        PancakeV4Currency output = zeroForOne ? key.currency1 : key.currency0;
        _settlePancakeV4(vault, input, amountIn);
        vault.take(output, address(this), amountOut);
    }

    function _pancakeV4PoolKey(INutboxRouter.PancakeV4CLSource memory source)
        internal
        pure
        returns (PancakeV4PoolKey memory key)
    {
        key = PancakeV4PoolKey({
            currency0: PancakeV4Currency.wrap(source.currency0),
            currency1: PancakeV4Currency.wrap(source.currency1),
            hooks: IPancakeV4Hooks(source.hooks),
            poolManager: IPancakeV4PoolManager(source.poolManager),
            fee: source.fee,
            parameters: source.parameters
        });
    }

    // -------------------------------------------------------------------------
    // Validation and accounting internals
    // -------------------------------------------------------------------------

    function _validateTrade(uint256 amount, address recipient, uint256 deadline) internal view {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _receiveToken(address token, uint256 amount) internal returns (uint256 receivedAmount) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        receivedAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (receivedAmount == 0) revert UnsupportedInputToken();
    }

    function _deliverToken(address token, uint256 amount, address recipient, bool allowFeeOnTransfer)
        internal
        returns (uint256 deliveredAmount)
    {
        uint256 balanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        deliveredAmount = IERC20(token).balanceOf(recipient) - balanceBefore;
        if (deliveredAmount == 0 || (!allowFeeOnTransfer && deliveredAmount != amount)) revert InvalidSwapOutput();
    }

    function _feeAmounts(uint256 nativeAmount)
        internal
        view
        returns (uint256 amountAfterFees, uint256 tagaiFee, uint256 sellsmanFee)
    {
        sellsmanFee = (nativeAmount * sellsmanRatio) / BPS_DENOMINATOR;
        tagaiFee = (nativeAmount * tagaiRatio) / BPS_DENOMINATOR;
        amountAfterFees = nativeAmount - sellsmanFee - tagaiFee;
    }

    function _tokenFeeAmounts(uint256 tokenAmount, address community)
        internal
        view
        returns (uint256 amountAfterFee, uint256 nutboxFee)
    {
        if (community == address(0)) return (tokenAmount, 0);
        nutboxFee = (tokenAmount * nutboxTokenRatio) / BPS_DENOMINATOR;
        amountAfterFee = tokenAmount - nutboxFee;
    }

    function _takeFees(uint256 nativeAmount, address sellsman)
        internal
        returns (uint256 amountAfterFees, uint256 tagaiFee, uint256 sellsmanFee, address feeRecipient)
    {
        (amountAfterFees, tagaiFee, sellsmanFee) = _feeAmounts(nativeAmount);
        feeRecipient = sellsman;
        if (sellsmanFee != 0) {
            if (sellsman != feeAddress && ipshare.ipshareCreated(sellsman)) {
                ipshare.valueCapture{value: sellsmanFee}(sellsman);
            } else if (!_trySendNative(sellsman, sellsmanFee)) {
                feeRecipient = feeAddress;
                _sendNative(feeAddress, sellsmanFee);
            }
        }
        if (tagaiFee != 0) _sendNative(feeAddress, tagaiFee);
    }

    /// @dev A caller-supplied subject with an IPShare receives commission through valueCapture.
    ///      A subject without an IPShare receives native coin directly. Zero/self falls back to
    ///      the platform fee address.
    function _resolvedSellsman(address sellsman, address deployer) internal view returns (address) {
        if (sellsman != address(0) && sellsman != address(this)) return sellsman;
        return deployer == address(0) ? feeAddress : deployer;
    }

    function _storeImportedMarket(address token, address community, address deployer) internal {
        if (token.code.length == 0 || community.code.length == 0 || deployer == address(0)) revert InvalidMarket();
        ImportedMarket storage market = _importedMarkets[token];
        market.registered = true;
        market.community = community;
        market.deployer = deployer;
        lastNutboxInjectionAt[token] = block.timestamp;
    }

    function _accrueNutboxTokenFee(address token, address community, uint256 amount) internal {
        if (community == address(0) || amount == 0) return;

        uint256 pending = pendingNutboxInjection[token];
        uint256 lastInjection = lastNutboxInjectionAt[token];
        if (pending == 0) {
            if (lastInjection == 0 || block.timestamp >= lastInjection + NUTBOX_INJECTION_INTERVAL) {
                lastNutboxInjectionAt[token] = block.timestamp;
            }
        } else if (block.timestamp >= lastInjection + NUTBOX_INJECTION_INTERVAL) {
            _tryInjectPending(token, community, pending);
        }

        pendingNutboxInjection[token] += amount;
        emit NutboxTokenFeeAccrued(token, community, amount, pendingNutboxInjection[token]);
    }

    function _tryInjectPending(address token, address community, uint256 amount) internal returns (bool success) {
        address calculator = ICommunity(community).rewardCalculator();
        IERC20(token).forceApprove(calculator, amount);
        try IHourlyTickCalculator(calculator).inject(community, amount) {
            IERC20(token).forceApprove(calculator, 0);
            pendingNutboxInjection[token] = 0;
            lastNutboxInjectionAt[token] = block.timestamp;
            emit NutboxTokenFeeInjected(token, community, amount);
            return true;
        } catch (bytes memory reason) {
            IERC20(token).forceApprove(calculator, 0);
            emit NutboxTokenFeeInjectionFailed(token, community, amount, reason);
            return false;
        }
    }

    function _trySendNative(address recipient, uint256 amount) internal returns (bool success) {
        (success,) = payable(recipient).call{value: amount}("");
    }

    function _sendNative(address recipient, uint256 amount) internal {
        if (!_trySendNative(recipient, amount)) revert NativeTransferFailed();
    }

    function _validateV4Direction(address tokenIn, address tokenOut, address currency0, address currency1)
        internal
        pure
        returns (bool zeroForOne)
    {
        if (tokenIn == currency0 && tokenOut == currency1) return true;
        if (tokenIn == currency1 && tokenOut == currency0) return false;
        revert InvalidMarket();
    }

    function _otherToken(address token, address token0, address token1) internal pure returns (address quoteToken) {
        if (token == token0) return token1;
        if (token == token1) return token0;
        revert InvalidMarket();
    }

    function _validatePancakeV4Delta(PancakeV4BalanceDelta delta, bool zeroForOne, uint256 amountIn)
        internal
        pure
        returns (uint256 amountOut)
    {
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0 || uint256(-int256(inputDelta)) != amountIn) {
            revert InvalidSwapOutput();
        }
        amountOut = uint256(uint128(outputDelta));
    }

    function _settlePancakeV4(IPancakeV4Vault vault, PancakeV4Currency currency, uint256 amount) internal {
        address token = PancakeV4Currency.unwrap(currency);
        if (token == address(0)) {
            vault.settle{value: amount}();
        } else {
            vault.sync(currency);
            IERC20(token).safeTransfer(address(vault), amount);
            vault.settle();
        }
    }

    function _assetBalance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _normalized(address token) internal view returns (address) {
        return token == address(0) ? wrappedNative : token;
    }
}
