// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title IndexBrokerNFTAMM
 * @notice Fixed-price inventory vault paired one-to-one with an NFT mining pool.
 *
 * Community tokens paid during mint are deposited here as the reserve used to buy
 * NFTs back at `tokensPerNFT`. Native-coin trading fees stay in this contract and
 * intentionally have no withdrawal path yet.
 *
 * Native fee ratios are immutable after initialization. Trading remains disabled
 * until the native-coin notional/oracle used by those ratios is defined.
 */
contract IndexBrokerNFTAMM is Initializable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public factory;
    address public collection;
    address public communityToken;
    uint256 public tokensPerNFT;
    uint16 public normalFeeBps;
    uint16 public specificFeeBps;
    bool public nativeFeeConfigured;

    uint256 public inventoryCount;
    uint256 public oldestTokenId;
    uint256 public newestTokenId;

    mapping(uint256 => uint256) private _nextTokenId;
    mapping(uint256 => uint256) private _previousTokenId;
    mapping(uint256 => bool) public inInventory;

    address private _expectedSeller;
    uint256 private _expectedTokenId;

    event NFTSold(address indexed seller, uint256 indexed tokenId, uint256 tokenAmount, uint256 nativeFee);
    event NFTBought(
        address indexed buyer, uint256 indexed tokenId, uint256 tokenAmount, uint256 nativeFee, bool specific
    );
    event NativeFeeReceived(address indexed payer, uint256 amount);

    error InvalidAddress();
    error InvalidConfig();
    error InvalidPayment();
    error InvalidTokenAmount();
    error InvalidNFTTransfer();
    error NFTNotInInventory();
    error EmptyInventory();
    error InsufficientReserve();
    error NativeFeeNotConfigured();
    error InvalidCommunityTokenPayment();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address collection_,
        address communityToken_,
        uint256 tokensPerNFT_,
        uint16 normalFeeBps_,
        uint16 specificFeeBps_
    ) external initializer {
        if (collection_.code.length == 0 || communityToken_.code.length == 0) {
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
    }

    receive() external payable {
        emit NativeFeeReceived(msg.sender, msg.value);
    }

    function quoteNormalNativeFee() external view returns (uint256) {
        return _quoteNativeFee(normalFeeBps);
    }

    function quoteSpecificNativeFee() external view returns (uint256) {
        return _quoteNativeFee(specificFeeBps);
    }

    function sellNFT(uint256 tokenId, uint256 minTokenPayout) external payable nonReentrant {
        uint256 nativeFee = _quoteNativeFee(normalFeeBps);
        if (msg.value != nativeFee) revert InvalidPayment();
        if (tokensPerNFT < minTokenPayout) revert InvalidTokenAmount();

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

        emit NFTSold(msg.sender, tokenId, tokensPerNFT, nativeFee);
    }

    function buyNextNFT(uint256 maxTokenCost) external payable nonReentrant returns (uint256 tokenId) {
        tokenId = oldestTokenId;
        if (tokenId == 0) revert EmptyInventory();
        _buyNFT(tokenId, maxTokenCost, normalFeeBps, false);
    }

    function buySpecificNFT(uint256 tokenId, uint256 maxTokenCost) external payable nonReentrant {
        if (!inInventory[tokenId]) revert NFTNotInInventory();
        _buyNFT(tokenId, maxTokenCost, specificFeeBps, true);
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
        return msg.sender == collection && from == _expectedSeller && tokenId == _expectedTokenId;
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (
            msg.sender != collection || operator != address(this) || from != _expectedSeller
                || tokenId != _expectedTokenId || inInventory[tokenId]
        ) revert InvalidNFTTransfer();

        _addToInventory(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _buyNFT(uint256 tokenId, uint256 maxTokenCost, uint16 feeBps, bool specific) internal {
        uint256 nativeFee = _quoteNativeFee(feeBps);
        if (msg.value != nativeFee) revert InvalidPayment();
        if (tokensPerNFT > maxTokenCost) revert InvalidTokenAmount();

        IERC20 paymentToken = IERC20(communityToken);
        uint256 reserveBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), tokensPerNFT);
        if (paymentToken.balanceOf(address(this)) - reserveBefore != tokensPerNFT) {
            revert InvalidCommunityTokenPayment();
        }

        _removeFromInventory(tokenId);
        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        emit NFTBought(msg.sender, tokenId, tokensPerNFT, nativeFee, specific);
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

    function _quoteNativeFee(uint16) internal view returns (uint256) {
        if (!nativeFeeConfigured) revert NativeFeeNotConfigured();
        return 0;
    }
}
