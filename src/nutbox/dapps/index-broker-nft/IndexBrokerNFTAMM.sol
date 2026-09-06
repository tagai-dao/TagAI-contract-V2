// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../../router/INutboxRouter.sol";
import "../../../router/NutboxSpotPrice.sol";
import "./IIndexBrokerNFT.sol";
import {PoolKey as IndexBrokerUniswapV4PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId as IndexBrokerUniswapV4PoolId, PoolIdLibrary as IndexBrokerPoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency as IndexBrokerUniswapV4Currency} from "v4-core/src/types/Currency.sol";
import {IHooks as IndexBrokerUniswapV4Hooks} from "v4-core/src/interfaces/IHooks.sol";

interface IIndexBrokerPump {
    function createdTokens(address token) external view returns (bool);
}

interface IIndexBrokerTagAIToken {
    function listed() external view returns (bool);
    /// @dev RH Token 的 Uniswap V4 PoolManager（IPoolManager public poolManager）。
    function poolManager() external view returns (address);
    function v4PoolId() external view returns (bytes32);
    function listingHook() external view returns (address);
    function LISTING_LP_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
}

interface IIndexBrokerBasketRegistry {
    function isBasket(address candidate) external view returns (bool);
    function basketVersion(address basket) external view returns (uint32);
}

interface IIndexBrokerBasketToken {
    function wbnb() external view returns (address);
    function engine() external view returns (address);
    function registry() external view returns (address);
    function settlementToken() external view returns (address);
    function protocolVersion() external view returns (uint32);
}

interface IIndexBrokerBasketSwapRouter {
    function basketHook() external view returns (address);
    function settlementToken() external view returns (address);
    function buyExactSettlement(
        address basket,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);
}

interface IIndexBrokerBasketHook {
    function basketRegistry() external view returns (address);
    function settlementToken() external view returns (address);
    function tokenVersion() external view returns (uint32);
}

interface IIndexBrokerPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IIndexBrokerPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IIndexBrokerWrappedNative {
    function withdraw(uint256 amount) external;
}

/**
 * @title IndexBrokerNFTAMM
 * @notice Fixed-price inventory vault paired one-to-one with an NFT mining pool.
 *
 * Community tokens paid during mint are deposited here as the reserve used to buy
 * NFTs back at `tokensPerNFT`. Configured native-coin trading fees stay in this
 * contract and intentionally have no withdrawal path yet. An additional fixed
 * 0.5% of the NFT's native-coin value is sent to the platform on every trade.
 *
 * Native fee ratios and the AMM's first-hop DEX pool are immutable once trading is active.
 * Platform-managed quote-asset routes in the shared router remain dynamic.
 * AMMs for unlisted official Pump tokens start inactive so mints can seed their reserve
 * before listing. Already-listed official tokens and externally imported tokens activate
 * atomically during initialization. An official listing pool may use native coin or another
 * ERC20 as its quote asset; non-native quotes continue through the shared router route.
 */
contract IndexBrokerNFTAMM is Initializable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant PLATFORM_FEE_BPS = 50;
    uint16 public constant INDEX_PURCHASE_CALLER_BPS = 100;

    address public factory;
    address public collection;
    address public communityToken;
    uint256 public tokensPerNFT;
    uint16 public normalFeeBps;
    uint16 public specificFeeBps;
    address public pump;
    address public nutboxRouter;
    INutboxRouter.SourceType public priceSourceType;
    bytes public priceSourceData;
    address public priceQuoteToken;
    bool public active;
    address public basketRegistry;
    IIndexBrokerBasketSwapRouter public basketSwapRouter;
    IIndexBrokerPancakeV3Router public indexV3Router;
    address public indexWrappedNative;
    address public indexSettlementToken;
    uint24 public indexV3Fee;
    address public indexToken;
    uint32 public indexBasketVersion;

    uint256 public inventoryCount;
    uint256 public oldestTokenId;
    uint256 public newestTokenId;

    mapping(uint256 => uint256) private _nextTokenId;
    mapping(uint256 => uint256) private _previousTokenId;
    mapping(uint256 => bool) public inInventory;

    address private _expectedSeller;
    uint256 private _expectedTokenId;

    event NFTSold(
        address indexed seller, uint256 indexed tokenId, uint256 tokenAmount, uint256 tradingFee, uint256 platformFee
    );
    event NFTBought(
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 tokenAmount,
        uint256 tradingFee,
        uint256 platformFee,
        bool specific
    );
    event NativeFeeReceived(address indexed payer, uint256 amount);
    event NativeFeeRefunded(address indexed payer, uint256 amount);
    event PlatformFeePaid(address indexed payer, address indexed receiver, uint256 amount);
    event IndexTokenPurchased(
        address indexed caller,
        address indexed indexToken,
        uint256 nativeAmount,
        uint256 callerReward,
        uint256 settlementAmount,
        uint256 indexAmount
    );
    event IndexHolderFeesConverted(uint256 wrappedNativeAmount);
    event AMMActivated(
        address indexed activator,
        INutboxRouter.SourceType indexed priceSourceType,
        bytes priceSourceData,
        bool officialTagAIToken
    );

    error InvalidAddress();
    error InvalidConfig();
    error InsufficientNativeFee();
    error InvalidNFTTransfer();
    error NFTNotInInventory();
    error EmptyInventory();
    error InsufficientReserve();
    error InvalidCommunityTokenPayment();
    error NoNativeReserve();
    error InvalidIndexPurchase();
    error InvalidIndexHolderFees();
    error AMMInactive();
    error AMMAlreadyActive();
    error OfficialTokenNotListed();
    error ExternalPriceSourceRequired();
    error OfficialPriceSourceMustBeAutomatic();
    error NotOfficialToken();
    error InvalidOfficialPool();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address collection_,
        address communityToken_,
        uint256 tokensPerNFT_,
        uint16 normalFeeBps_,
        uint16 specificFeeBps_,
        address pump_,
        address nutboxRouter_,
        INutboxRouter.SourceType priceSourceType_,
        bytes calldata priceSourceData_,
        address basketRegistry_,
        address basketSwapRouter_,
        address indexV3Router_,
        uint24 indexV3Fee_,
        address indexToken_
    ) external initializer {
        if (
            collection_.code.length == 0 || communityToken_.code.length == 0 || nutboxRouter_.code.length == 0
                || basketRegistry_.code.length == 0 || basketSwapRouter_.code.length == 0
                || indexToken_.code.length == 0
                || (indexV3Router_ != address(0) && indexV3Router_.code.length == 0)
                || (pump_ != address(0) && pump_.code.length == 0)
        ) {
            revert InvalidAddress();
        }
        if (tokensPerNFT_ == 0 || normalFeeBps_ > BPS_DENOMINATOR || specificFeeBps_ > BPS_DENOMINATOR) {
            revert InvalidConfig();
        }

        factory = msg.sender;
        collection = collection_;
        communityToken = communityToken_;
        tokensPerNFT = tokensPerNFT_;
        normalFeeBps = normalFeeBps_;
        specificFeeBps = specificFeeBps_;
        pump = pump_;
        nutboxRouter = nutboxRouter_;
        basketRegistry = basketRegistry_;
        indexToken = indexToken_;

        IIndexBrokerBasketRegistry registry = IIndexBrokerBasketRegistry(basketRegistry_);
        if (!registry.isBasket(indexToken_)) revert InvalidConfig();

        IIndexBrokerBasketSwapRouter router = IIndexBrokerBasketSwapRouter(basketSwapRouter_);
        address settlement = router.settlementToken();
        address basketHook = router.basketHook();
        uint32 basketVersion = registry.basketVersion(indexToken_);
        IIndexBrokerBasketToken basket = IIndexBrokerBasketToken(indexToken_);
        // wrappedNative 取 basket.wbnb()（V3 BasketToken 上为 weth 别名）。
        address wrappedNative = basket.wbnb();

        if (
            basketVersion == 0 || settlement.code.length == 0 || basketHook.code.length == 0
                || wrappedNative.code.length == 0
                || basket.protocolVersion() != basketVersion || basket.registry() != basketRegistry_
                || basket.engine() != basketHook || basket.settlementToken() != settlement
                || basket.wbnb() != wrappedNative
        ) revert InvalidConfig();

        // indexV3Router == 0 时禁用 native 买指数；RH 主网绑定 Uniswap SwapRouter02。
        if (indexV3Router_ != address(0)) {
            IIndexBrokerPancakeV3Router v3Router = IIndexBrokerPancakeV3Router(indexV3Router_);
            if (v3Router.WETH9() != wrappedNative) revert InvalidConfig();
            address v3Factory = v3Router.factory();
            if (v3Factory.code.length == 0) revert InvalidConfig();
            if (IIndexBrokerPancakeV3Factory(v3Factory).getPool(wrappedNative, settlement, indexV3Fee_).code.length == 0) {
                revert InvalidConfig();
            }
            indexV3Router = v3Router;
        } else {
            indexV3Router = IIndexBrokerPancakeV3Router(address(0));
        }

        basketSwapRouter = router;
        indexWrappedNative = wrappedNative;
        indexSettlementToken = settlement;
        indexV3Fee = indexV3Fee_;
        indexBasketVersion = basketVersion;

        bool officialTagAIToken = pump_ != address(0);
        if (officialTagAIToken) {
            if (!IIndexBrokerPump(pump_).createdTokens(communityToken_)) revert NotOfficialToken();
            if (priceSourceData_.length != 0) revert OfficialPriceSourceMustBeAutomatic();
            if (IIndexBrokerTagAIToken(communityToken_).listed()) _activateOfficialToken();
        } else {
            if (priceSourceData_.length == 0) revert ExternalPriceSourceRequired();
            _activate(priceSourceType_, priceSourceData_, false);
        }
    }

    receive() external payable {
        emit NativeFeeReceived(msg.sender, msg.value);
    }

    modifier whenActive() {
        if (!active) revert AMMInactive();
        _;
    }

    /**
     * @notice Permissionlessly activates an AMM paired with a listed official TagAI token.
     * @dev The source cannot be supplied by the caller. It is reconstructed from the
     *      token's snapshotted Uniswap V4 listing PoolKey and checked against v4PoolId.
     */
    function activate() external nonReentrant {
        if (pump == address(0) || !IIndexBrokerPump(pump).createdTokens(communityToken)) revert NotOfficialToken();
        if (active) revert AMMAlreadyActive();

        _activateOfficialToken();
    }

    function _activateOfficialToken() internal {
        IIndexBrokerTagAIToken token = IIndexBrokerTagAIToken(communityToken);
        if (!token.listed()) revert OfficialTokenNotListed();

        address manager = token.poolManager();
        bytes32 poolId = token.v4PoolId();
        if (manager.code.length == 0 || poolId == bytes32(0)) revert InvalidOfficialPool();

        // RH 上市池固定 currency0 = native ETH（address(0)）、currency1 = token。
        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: manager,
            currency0: address(0),
            currency1: communityToken,
            fee: token.LISTING_LP_FEE(),
            tickSpacing: token.TICK_SPACING(),
            hooks: token.listingHook()
        });

        // 排序校验：用同样字段本地算 PoolKey.toId()，必须 == token.v4PoolId()。
        IndexBrokerUniswapV4PoolKey memory key = IndexBrokerUniswapV4PoolKey({
            currency0: IndexBrokerUniswapV4Currency.wrap(source.currency0),
            currency1: IndexBrokerUniswapV4Currency.wrap(source.currency1),
            fee: source.fee,
            tickSpacing: source.tickSpacing,
            hooks: IndexBrokerUniswapV4Hooks(source.hooks)
        });
        bytes32 reconstructedPoolId = IndexBrokerUniswapV4PoolId.unwrap(IndexBrokerPoolIdLibrary.toId(key));
        if (
            source.hooks == address(0) || source.poolManager != manager || reconstructedPoolId != poolId
                || (source.currency0 != communityToken && source.currency1 != communityToken)
        ) {
            revert InvalidOfficialPool();
        }

        _activate(INutboxRouter.SourceType.UNISWAP_V4, abi.encode(source), true);
    }

    function quoteNormalNativeFee() external view whenActive returns (uint256) {
        (,, uint256 totalFee) = _quoteNativeFees(normalFeeBps);
        return totalFee;
    }

    function quoteSpecificNativeFee() external view whenActive returns (uint256) {
        (,, uint256 totalFee) = _quoteNativeFees(specificFeeBps);
        return totalFee;
    }

    function quoteNormalTradingNativeFee() external view whenActive returns (uint256) {
        (uint256 tradingFee,,) = _quoteNativeFees(normalFeeBps);
        return tradingFee;
    }

    function quoteSpecificTradingNativeFee() external view whenActive returns (uint256) {
        (uint256 tradingFee,,) = _quoteNativeFees(specificFeeBps);
        return tradingFee;
    }

    function quotePlatformNativeFee() external view whenActive returns (uint256) {
        (, uint256 platformFee,) = _quoteNativeFees(0);
        return platformFee;
    }

    function quoteNativeValue() external view whenActive returns (uint256) {
        return _quoteNativeValue();
    }

    function platformFeeReceiver() public view returns (address) {
        return IIndexBrokerNFT(collection).platformFeeReceiver();
    }

    /**
     * @notice Permissionlessly invests all accumulated native trading fees into the fixed index token.
     * @dev The caller receives 1% of the native reserve as execution compensation. Purchased
     *      index tokens are injected into the paired NFT's index-mining rewards. Slippage and
     *      Basket hook data are supplied by the caller.
     */
    function buyIndexWithNativeReserve(uint256 minSettlementOut, uint256 minIndexOut, bytes calldata hookData)
        external
        nonReentrant
        whenActive
        returns (uint256 callerReward, uint256 settlementOut, uint256 indexOut)
    {
        uint256 nativeReserve = address(this).balance;
        if (nativeReserve == 0) revert NoNativeReserve();
        // USDG 为 6 decimals：minSettlementOut 由调用方按结算代币精度传入，合约不做 18→6 换算。
        if (address(indexV3Router) == address(0)) revert InvalidIndexPurchase();

        callerReward = Math.mulDiv(nativeReserve, INDEX_PURCHASE_CALLER_BPS, BPS_DENOMINATOR);
        uint256 nativeToInvest = nativeReserve - callerReward;
        uint256 indexBalanceBefore = IERC20(indexToken).balanceOf(address(this));

        IERC20 settlementToken = IERC20(indexSettlementToken);
        uint256 settlementBalanceBefore = settlementToken.balanceOf(address(this));
        settlementOut = indexV3Router.exactInputSingle{value: nativeToInvest}(
            IIndexBrokerPancakeV3Router.ExactInputSingleParams({
                tokenIn: indexWrappedNative,
                tokenOut: indexSettlementToken,
                fee: indexV3Fee,
                recipient: address(this),
                amountIn: nativeToInvest,
                amountOutMinimum: minSettlementOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (settlementOut == 0 || settlementToken.balanceOf(address(this)) - settlementBalanceBefore != settlementOut) {
            revert InvalidIndexPurchase();
        }
        settlementToken.forceApprove(address(basketSwapRouter), settlementOut);
        indexOut = basketSwapRouter.buyExactSettlement(indexToken, settlementOut, minIndexOut, hookData, address(this));
        settlementToken.forceApprove(address(basketSwapRouter), 0);
        if (indexOut == 0 || IERC20(indexToken).balanceOf(address(this)) - indexBalanceBefore != indexOut) {
            revert InvalidIndexPurchase();
        }
        IERC20(indexToken).forceApprove(collection, indexOut);
        IIndexBrokerNFT(collection).injectIndexRewards(indexOut);
        IERC20(indexToken).forceApprove(collection, 0);
        if (callerReward != 0) Address.sendValue(payable(msg.sender), callerReward);

        emit IndexTokenPurchased(msg.sender, indexToken, nativeToInvest, callerReward, settlementOut, indexOut);
    }

    /// @notice Converts Index Basket holder-fee WBNB received from the paired NFT pool into buyback BNB.
    function convertIndexHolderFees(uint256 amount) external nonReentrant whenActive {
        if (msg.sender != collection || amount == 0) revert InvalidIndexHolderFees();
        IIndexBrokerWrappedNative(indexWrappedNative).withdraw(amount);
        emit IndexHolderFeesConverted(amount);
    }

    function sellNFT(uint256 tokenId) external payable nonReentrant whenActive {
        (uint256 tradingFee, uint256 platformFee, uint256 totalFee) = _quoteNativeFees(normalFeeBps);
        if (msg.value < totalFee) revert InsufficientNativeFee();

        IERC20 paymentToken = IERC20(communityToken);
        if (paymentToken.balanceOf(address(this)) < tokensPerNFT) revert InsufficientReserve();

        _expectedSeller = msg.sender;
        _expectedTokenId = tokenId;
        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        delete _expectedSeller;
        delete _expectedTokenId;

        uint256 sellerBalanceBefore = paymentToken.balanceOf(msg.sender);
        paymentToken.safeTransfer(msg.sender, tokensPerNFT);
        if (paymentToken.balanceOf(msg.sender) - sellerBalanceBefore != tokensPerNFT) {
            revert InvalidCommunityTokenPayment();
        }

        _settleNativeFees(platformFee, totalFee);
        emit NFTSold(msg.sender, tokenId, tokensPerNFT, tradingFee, platformFee);
    }

    function buyNextNFT() external payable nonReentrant whenActive returns (uint256 tokenId) {
        tokenId = oldestTokenId;
        if (tokenId == 0) revert EmptyInventory();
        _buyNFT(tokenId, normalFeeBps, false);
    }

    function buySpecificNFT(uint256 tokenId) external payable nonReentrant whenActive {
        if (!inInventory[tokenId]) revert NFTNotInInventory();
        _buyNFT(tokenId, specificFeeBps, true);
    }

    function nextInventoryToken(uint256 tokenId) external view returns (uint256) {
        if (!inInventory[tokenId]) revert NFTNotInInventory();
        return _nextTokenId[tokenId];
    }

    function previousInventoryToken(uint256 tokenId) external view returns (uint256) {
        if (!inInventory[tokenId]) revert NFTNotInInventory();
        return _previousTokenId[tokenId];
    }

    function isAcceptingNFT(address from, uint256 tokenId) external view returns (bool) {
        return active && msg.sender == collection && from == _expectedSeller && tokenId == _expectedTokenId;
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        override
        whenActive
        returns (bytes4)
    {
        if (
            msg.sender != collection || operator != address(this) || from != _expectedSeller
                || tokenId != _expectedTokenId || inInventory[tokenId]
        ) revert InvalidNFTTransfer();

        _addToInventory(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _buyNFT(uint256 tokenId, uint16 feeBps, bool specific) internal {
        (uint256 tradingFee, uint256 platformFee, uint256 totalFee) = _quoteNativeFees(feeBps);
        if (msg.value < totalFee) revert InsufficientNativeFee();

        IERC20 paymentToken = IERC20(communityToken);
        uint256 reserveBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), tokensPerNFT);
        if (paymentToken.balanceOf(address(this)) - reserveBefore != tokensPerNFT) {
            revert InvalidCommunityTokenPayment();
        }

        _removeFromInventory(tokenId);
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        _settleNativeFees(platformFee, totalFee);
        emit NFTBought(msg.sender, tokenId, tokensPerNFT, tradingFee, platformFee, specific);
    }

    function _addToInventory(uint256 tokenId) internal {
        uint256 tail = newestTokenId;
        if (tail == 0) {
            oldestTokenId = tokenId;
        } else {
            _nextTokenId[tail] = tokenId;
            _previousTokenId[tokenId] = tail;
        }
        newestTokenId = tokenId;
        inInventory[tokenId] = true;
        ++inventoryCount;
    }

    function _removeFromInventory(uint256 tokenId) internal {
        uint256 previous = _previousTokenId[tokenId];
        uint256 next = _nextTokenId[tokenId];

        if (previous == 0) oldestTokenId = next;
        else _nextTokenId[previous] = next;

        if (next == 0) newestTokenId = previous;
        else _previousTokenId[next] = previous;

        delete _nextTokenId[tokenId];
        delete _previousTokenId[tokenId];
        delete inInventory[tokenId];
        --inventoryCount;
    }

    function _quoteNativeFees(uint16 tradingFeeBps)
        internal
        view
        returns (uint256 tradingFee, uint256 platformFee, uint256 totalFee)
    {
        uint256 nativeValue = _quoteNativeValue();
        tradingFee = Math.mulDiv(nativeValue, tradingFeeBps, BPS_DENOMINATOR, Math.Rounding.Up);
        platformFee = Math.mulDiv(nativeValue, PLATFORM_FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
        totalFee = tradingFee + platformFee;
    }

    function _quoteNativeValue() internal view returns (uint256) {
        INutboxRouter router = INutboxRouter(nutboxRouter);
        uint256 quoteAmount = NutboxSpotPrice.quote(
            router, communityToken, priceQuoteToken, tokensPerNFT, priceSourceType, priceSourceData
        );
        if (priceQuoteToken == address(0) || priceQuoteToken == router.wrappedNative()) return quoteAmount;
        return router.quote(priceQuoteToken, router.wrappedNative(), quoteAmount);
    }

    function _activate(
        INutboxRouter.SourceType priceSourceType_,
        bytes memory priceSourceData_,
        bool officialTagAIToken
    ) internal {
        if (active) revert AMMAlreadyActive();

        INutboxRouter router = INutboxRouter(nutboxRouter);
        address quoteToken = NutboxSpotPrice.otherToken(communityToken, priceSourceType_, priceSourceData_);
        uint256 quoteAmount =
            NutboxSpotPrice.quote(router, communityToken, quoteToken, tokensPerNFT, priceSourceType_, priceSourceData_);
        if (quoteToken != address(0) && quoteToken != router.wrappedNative()) {
            router.validateRoute(quoteToken, router.wrappedNative());
            router.quote(quoteToken, router.wrappedNative(), quoteAmount);
        }

        priceSourceType = priceSourceType_;
        priceSourceData = priceSourceData_;
        priceQuoteToken = quoteToken;
        active = true;
        emit AMMActivated(msg.sender, priceSourceType_, priceSourceData_, officialTagAIToken);
    }

    function _settleNativeFees(uint256 platformFee, uint256 totalFee) internal {
        address feeReceiver = platformFeeReceiver();
        Address.sendValue(payable(feeReceiver), platformFee);
        emit PlatformFeePaid(msg.sender, feeReceiver, platformFee);

        uint256 refund = msg.value - totalFee;
        if (refund != 0) {
            Address.sendValue(payable(msg.sender), refund);
            emit NativeFeeRefunded(msg.sender, refund);
        }
    }
}
