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

import "./IIndexBrokerNFTPriceOracle.sol";

interface IIndexBrokerNFTPlatformFee {
    function platformFeeReceiver() external view returns (address);
    function injectIndexRewards(uint256 amount) external;
}

interface IIndexBrokerPump {
    function createdTokens(address token) external view returns (bool);
}

interface IIndexBrokerTagAIToken {
    function listed() external view returns (bool);
    function clPoolManager() external view returns (address);
    function v4PoolId() external view returns (bytes32);
    function listingHook() external view returns (address);
    function listingPoolParameters() external view returns (bytes32);
    function LISTING_LP_FEE() external view returns (uint24);
}

interface IIndexBrokerBasketRegistry {
    function isBasket(address candidate) external view returns (bool);
}

interface IIndexBrokerBasketSwapRouter {
    function settlementToken() external view returns (address);
    function buyExactSettlement(
        address basket,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);
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

/**
 * @title IndexBrokerNFTAMM
 * @notice Fixed-price inventory vault paired one-to-one with an NFT mining pool.
 *
 * Community tokens paid during mint are deposited here as the reserve used to buy
 * NFTs back at `tokensPerNFT`. Configured native-coin trading fees stay in this
 * contract and intentionally have no withdrawal path yet. An additional fixed
 * 0.5% of the NFT's native-coin value is sent to the platform on every trade.
 *
 * Native fee ratios and the DEX spot-price source are immutable once trading is active.
 * AMMs for unlisted official Pump tokens start inactive so mints can seed their reserve
 * before listing. Already-listed official tokens and externally imported tokens activate
 * atomically during initialization.
 */
contract IndexBrokerNFTAMM is Initializable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant PLATFORM_FEE_BPS = 50;
    uint16 public constant INDEX_PURCHASE_CALLER_BPS = 30;

    address public factory;
    address public collection;
    address public communityToken;
    uint256 public tokensPerNFT;
    uint16 public normalFeeBps;
    uint16 public specificFeeBps;
    address public pump;
    address public priceOracle;
    IIndexBrokerNFTPriceOracle.SourceType public priceSourceType;
    bytes public priceSourceData;
    bool public active;
    address public basketRegistry;
    IIndexBrokerBasketSwapRouter public basketSwapRouter;
    IIndexBrokerPancakeV3Router public indexV3Router;
    address public indexWrappedNative;
    address public indexSettlementToken;
    uint24 public indexV3Fee;
    address public indexToken;

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
    event AMMActivated(
        address indexed activator,
        IIndexBrokerNFTPriceOracle.SourceType indexed priceSourceType,
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
        address priceOracle_,
        IIndexBrokerNFTPriceOracle.SourceType priceSourceType_,
        bytes calldata priceSourceData_,
        address basketRegistry_,
        address basketSwapRouter_,
        address indexV3Router_,
        uint24 indexV3Fee_,
        address indexToken_
    ) external initializer {
        if (
            collection_.code.length == 0 || communityToken_.code.length == 0 || pump_.code.length == 0
                || priceOracle_.code.length == 0 || basketRegistry_.code.length == 0
                || basketSwapRouter_.code.length == 0 || indexV3Router_.code.length == 0 || indexToken_.code.length == 0
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
        priceOracle = priceOracle_;
        basketRegistry = basketRegistry_;
        indexToken = indexToken_;

        if (!IIndexBrokerBasketRegistry(basketRegistry_).isBasket(indexToken_)) revert InvalidConfig();

        IIndexBrokerBasketSwapRouter router = IIndexBrokerBasketSwapRouter(basketSwapRouter_);
        address settlement = router.settlementToken();
        IIndexBrokerPancakeV3Router v3Router = IIndexBrokerPancakeV3Router(indexV3Router_);
        address wrappedNative = v3Router.WETH9();
        address v3Factory = v3Router.factory();
        if (
            settlement.code.length == 0 || wrappedNative.code.length == 0 || v3Factory.code.length == 0
                || IIndexBrokerPancakeV3Factory(v3Factory).getPool(wrappedNative, settlement, indexV3Fee_).code.length
                    == 0
        ) revert InvalidConfig();

        basketSwapRouter = router;
        indexV3Router = v3Router;
        indexWrappedNative = wrappedNative;
        indexSettlementToken = settlement;
        indexV3Fee = indexV3Fee_;

        bool officialTagAIToken = IIndexBrokerPump(pump_).createdTokens(communityToken_);
        if (officialTagAIToken) {
            if (priceSourceData_.length != 0) revert OfficialPriceSourceMustBeAutomatic();
            if (IIndexBrokerTagAIToken(communityToken_).listed()) _activateOfficialToken();
        } else {
            if (priceSourceData_.length == 0) revert ExternalPriceSourceRequired();
            _activate(priceSourceType_, priceSourceData_, false);
        }
    }

    receive() external payable {
        if (!active) revert AMMInactive();
        emit NativeFeeReceived(msg.sender, msg.value);
    }

    modifier whenActive() {
        if (!active) revert AMMInactive();
        _;
    }

    /**
     * @notice Permissionlessly activates an AMM paired with a listed official TagAI token.
     * @dev The source cannot be supplied by the caller. It is reconstructed from the
     *      token's snapshotted Pancake V4 listing PoolKey and checked against v4PoolId.
     */
    function activate() external nonReentrant {
        if (!IIndexBrokerPump(pump).createdTokens(communityToken)) revert NotOfficialToken();
        if (active) revert AMMAlreadyActive();

        _activateOfficialToken();
    }

    function _activateOfficialToken() internal {
        IIndexBrokerTagAIToken token = IIndexBrokerTagAIToken(communityToken);
        if (!token.listed()) revert OfficialTokenNotListed();

        IIndexBrokerNFTPriceOracle.PancakeV4CLSource memory source = IIndexBrokerNFTPriceOracle.PancakeV4CLSource({
            currency0: address(0),
            currency1: communityToken,
            hooks: token.listingHook(),
            poolManager: token.clPoolManager(),
            fee: token.LISTING_LP_FEE(),
            parameters: token.listingPoolParameters()
        });
        bytes32 reconstructedPoolId = keccak256(
            abi.encode(
                source.currency0, source.currency1, source.hooks, source.poolManager, source.fee, source.parameters
            )
        );
        if (source.hooks == address(0) || source.poolManager == address(0) || token.v4PoolId() != reconstructedPoolId) {
            revert InvalidOfficialPool();
        }

        _activate(IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL, abi.encode(source), true);
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
        return IIndexBrokerNFTPlatformFee(collection).platformFeeReceiver();
    }

    /**
     * @notice Permissionlessly invests all accumulated native trading fees into the fixed index token.
     * @dev The caller receives 0.3% of the native reserve as execution compensation. Purchased
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
        IIndexBrokerNFTPlatformFee(collection).injectIndexRewards(indexOut);
        IERC20(indexToken).forceApprove(collection, 0);
        if (callerReward != 0) Address.sendValue(payable(msg.sender), callerReward);

        emit IndexTokenPurchased(msg.sender, indexToken, nativeToInvest, callerReward, settlementOut, indexOut);
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
        return IIndexBrokerNFTPriceOracle(priceOracle)
            .quoteNative(communityToken, tokensPerNFT, priceSourceType, priceSourceData);
    }

    function _activate(
        IIndexBrokerNFTPriceOracle.SourceType priceSourceType_,
        bytes memory priceSourceData_,
        bool officialTagAIToken
    ) internal {
        if (active) revert AMMAlreadyActive();

        IIndexBrokerNFTPriceOracle oracle = IIndexBrokerNFTPriceOracle(priceOracle);
        oracle.validateSource(communityToken, priceSourceType_, priceSourceData_);
        oracle.quoteNative(communityToken, tokensPerNFT, priceSourceType_, priceSourceData_);

        priceSourceType = priceSourceType_;
        priceSourceData = priceSourceData_;
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
