// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../../interfaces/ICommunity.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/IPool.sol";
import "../../../interfaces/INFTMiningRenderer.sol";

interface ICommunityCommittee {
    function committee() external view returns (address);
}

interface INFTMiningPlatformFee {
    function platformFeeBps() external view returns (uint16);
}

/**
 * @title NFTMiningPool
 * @notice An ERC721 collection whose ownership is the Nutbox staking ledger.
 *
 * Each NFT contributes a configurable mining weight to its current owner. Minting starts
 * mining, ERC721 transfers settle the sender and move the weight to the recipient, and
 * referral level-ups increase the current owner's weight after first settling old rewards.
 *
 * The implementation is clone-friendly: ERC721's constructor storage is intentionally empty,
 * while name/symbol and ownership are initialized in clone storage by `initialize`.
 */
contract NFTMiningPool is ERC721Enumerable, IPool, Initializable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant MAX_LEVELS = 16;
    uint256 public constant MAX_PALETTES = 6;
    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;

    /// @dev ERC-4906 interface identifier.
    bytes4 private constant _INTERFACE_ID_ERC4906 = 0x49064906;

    struct Batch {
        address paymentAsset;
        uint16 referralBps;
        uint8 paletteId;
        bool active;
        bool paused;
        uint256 mintPrice;
        uint256 maxSupply;
        uint256 minted;
    }

    struct NFTRecord {
        uint32 level;
        uint32 batchId;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 seed;
    }

    struct NFTInfo {
        address owner;
        uint32 level;
        uint32 batchId;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 miningWeight;
        uint256 seed;
    }

    address public factory;
    address public community;
    address public fundsReceiver;
    address public renderer;

    string private _collectionName;
    string private _collectionSymbol;

    uint256 public batchCount;
    uint256 public currentBatchId;
    uint256 public nextTokenId;

    uint256[] public levelThresholds;
    uint256[] public levelWeights;

    mapping(uint256 => Batch) public batches;
    mapping(uint256 => NFTRecord) private _nftRecords;
    mapping(address => uint256) private _userMiningWeight;
    uint256 private _totalMiningWeight;

    event BatchCreated(
        uint256 indexed batchId,
        uint256 maxSupply,
        address indexed paymentAsset,
        uint256 mintPrice,
        uint16 referralBps,
        uint8 paletteId
    );
    /// @dev Batches only ever close by selling out.
    event BatchClosed(uint256 indexed batchId);
    event BatchPausedSet(uint256 indexed batchId, bool paused);
    event FundsReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event PlatformFeePaid(
        uint256 indexed tokenId, address indexed paymentAsset, address indexed receiver, uint256 amount
    );
    event NFTMinted(
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 indexed batchId,
        uint256 referrerTokenId,
        address paymentAsset,
        uint256 mintPrice
    );
    event NFTReferralRecorded(
        uint256 indexed referrerTokenId,
        uint256 indexed childTokenId,
        address indexed commissionReceiver,
        uint256 commissionAmount
    );
    event NFTLevelUp(
        uint256 indexed tokenId,
        address indexed owner,
        uint32 previousLevel,
        uint32 newLevel,
        uint256 previousWeight,
        uint256 newWeight
    );
    event MiningWeightMoved(uint256 indexed tokenId, address indexed from, address indexed to, uint256 weight);

    /// @dev ERC-4906 metadata refresh event.
    event MetadataUpdate(uint256 _tokenId);

    /// @dev ERC-7572 contract-level metadata refresh event.
    event ContractURIUpdated();

    error InvalidAddress();
    error InvalidText();
    error InvalidLevelConfig();
    error InvalidBatchConfig();
    error ActiveBatchExists();
    error NoActiveBatch();
    error MintIsPaused();
    error PoolIsInactive();
    error BatchSoldOut();
    error InvalidPayment();

    constructor() ERC721("", "") {
        _disableInitializers();
    }

    function initialize(
        address community_,
        address admin_,
        address renderer_,
        string calldata name_,
        string calldata symbol_,
        address fundsReceiver_,
        uint256[] calldata thresholds_,
        uint256[] calldata weights_,
        address firstPaymentAsset_,
        uint256 firstMintPrice_,
        uint256 firstBatchSupply_,
        uint16 firstReferralBps_
    ) external initializer {
        if (
            community_ == address(0) || admin_ == address(0) || renderer_.code.length == 0
                || fundsReceiver_ == address(0) || fundsReceiver_ == address(this)
        ) {
            revert InvalidAddress();
        }

        _validateText(name_, MAX_NAME_LENGTH);
        _validateText(symbol_, MAX_SYMBOL_LENGTH);
        _validateLevelConfig(thresholds_, weights_);

        factory = msg.sender;
        community = community_;
        fundsReceiver = fundsReceiver_;
        renderer = renderer_;
        _collectionName = name_;
        _collectionSymbol = symbol_;

        for (uint256 i = 0; i < thresholds_.length; ++i) {
            levelThresholds.push(thresholds_[i]);
            levelWeights.push(weights_[i]);
        }

        _transferOwnership(admin_);
        _createBatch(firstBatchSupply_, firstPaymentAsset_, firstMintPrice_, firstReferralBps_);
    }

    // ───────────────────────────── ERC721 metadata ─────────────────────────────

    function name() public view override returns (string memory) {
        return _collectionName;
    }

    function symbol() public view override returns (string memory) {
        return _collectionSymbol;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == _INTERFACE_ID_ERC4906 || super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");

        NFTRecord storage record = _nftRecords[tokenId];
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_renderSVG(tokenId, record))));

        string memory json = string.concat(
            '{"name":"',
            _collectionName,
            " #",
            tokenId.toString(),
            '","description":"A dynamic Nutbox mining NFT. Ownership carries its mining weight and referral rights.",',
            '"image":"',
            image,
            '","attributes":[',
            '{"trait_type":"Batch","value":',
            uint256(record.batchId).toString(),
            "},",
            '{"trait_type":"Batch Palette","value":',
            uint256(batches[record.batchId].paletteId).toString(),
            "},",
            '{"trait_type":"Level","value":',
            uint256(record.level).toString(),
            "},",
            '{"trait_type":"Generation","value":',
            _generationForLevel(record.level).toString(),
            "},",
            '{"trait_type":"Phase","value":',
            _phaseForLevel(record.level).toString(),
            "},",
            '{"trait_type":"Referral Count","value":',
            record.referralCount.toString(),
            "},",
            '{"trait_type":"Referrer NFT","value":',
            record.referrerTokenId.toString(),
            "},",
            '{"trait_type":"Mining Weight","value":',
            _weightForLevel(record.level).toString(),
            "}",
            "]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Returns the raw, deterministic SVG used by tokenURI.
    function tokenSVG(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _renderSVG(tokenId, _nftRecords[tokenId]);
    }

    function contractURI() external view returns (string memory) {
        string memory collectionSvg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#14162d"/><stop offset="1" stop-color="#432a68"/></linearGradient></defs>',
            '<rect width="512" height="512" rx="40" fill="url(#g)"/>',
            '<circle cx="256" cy="220" r="112" fill="none" stroke="#73fbd3" stroke-width="8"/>',
            '<text x="256" y="225" text-anchor="middle" fill="white" font-family="sans-serif" font-size="34">NUTBOX</text>',
            '<text x="256" y="370" text-anchor="middle" fill="#73fbd3" font-family="sans-serif" font-size="28">',
            _collectionName,
            "</text></svg>"
        );
        string memory json = string.concat(
            '{"name":"',
            _collectionName,
            '","description":"A Nutbox NFT mining pool with transferable mining weight and referral levels.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(collectionSvg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ───────────────────────────── Pool administration ─────────────────────────

    function createBatch(uint256 maxSupply, address paymentAsset, uint256 mintPrice, uint16 referralBps)
        external
        onlyOwner
        returns (uint256 batchId)
    {
        if (currentBatchId != 0 && batches[currentBatchId].active) revert ActiveBatchExists();
        batchId = _createBatch(maxSupply, paymentAsset, mintPrice, referralBps);
    }

    function setCurrentBatchPaused(bool paused) external onlyOwner {
        Batch storage batch = batches[currentBatchId];
        if (!batch.active) revert NoActiveBatch();
        batch.paused = paused;
        emit BatchPausedSet(currentBatchId, paused);
    }

    function setFundsReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0) || newReceiver == address(this)) revert InvalidAddress();
        address previous = fundsReceiver;
        fundsReceiver = newReceiver;
        emit FundsReceiverChanged(previous, newReceiver);
    }

    // ─────────────────────────────────── Mint ──────────────────────────────────

    function mint(uint256 referrerTokenId) external payable nonReentrant returns (uint256 tokenId) {
        if (!ICommunity(community).poolActived(address(this))) {
            revert PoolIsInactive();
        }

        Batch storage batch = batches[currentBatchId];
        if (batch.minted >= batch.maxSupply) revert BatchSoldOut();
        if (!batch.active) revert NoActiveBatch();
        if (batch.paused) revert MintIsPaused();

        address commissionReceiver;
        if (referrerTokenId != 0) {
            commissionReceiver = ownerOf(referrerTokenId);
        }

        tokenId = ++nextTokenId;
        ++batch.minted;

        bytes32 previousBlockHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    block.chainid,
                    tokenId,
                    currentBatchId,
                    msg.sender,
                    block.prevrandao,
                    previousBlockHash
                )
            )
        );

        _nftRecords[tokenId] = NFTRecord({
            level: 1,
            batchId: SafeCast.toUint32(currentBatchId),
            referrerTokenId: referrerTokenId,
            referralCount: 0,
            seed: seed
        });

        uint256 platformFeeAmount = Math.mulDiv(batch.mintPrice, platformFeeBps(), BPS_DENOMINATOR);
        uint256 distributableAmount = batch.mintPrice - platformFeeAmount;
        uint256 commissionAmount;
        if (referrerTokenId != 0) {
            NFTRecord storage referrerRecord = _nftRecords[referrerTokenId];
            ++referrerRecord.referralCount;
            commissionAmount = Math.mulDiv(distributableAmount, batch.referralBps, BPS_DENOMINATOR);

            uint32 newLevel = _levelForReferralCount(referrerRecord.referralCount);
            if (newLevel != referrerRecord.level) {
                _applyLevelUpgrade(referrerTokenId, commissionReceiver, newLevel);
            }

            emit MetadataUpdate(referrerTokenId);
            emit NFTReferralRecorded(referrerTokenId, tokenId, commissionReceiver, commissionAmount);
        }

        address feeReceiver = platformFeeReceiver();
        _collectPayment(batch, feeReceiver, platformFeeAmount, commissionReceiver, commissionAmount);
        _safeMint(msg.sender, tokenId);

        if (batch.minted == batch.maxSupply) {
            batch.active = false;
            emit BatchClosed(currentBatchId);
        }

        emit NFTMinted(msg.sender, tokenId, currentBatchId, referrerTokenId, batch.paymentAsset, batch.mintPrice);
        emit PlatformFeePaid(tokenId, batch.paymentAsset, feeReceiver, platformFeeAmount);
    }

    // ─────────────────────────────── Nutbox IPool ──────────────────────────────

    function getFactory() external view override returns (address) {
        return factory;
    }

    function getCommunity() external view override returns (address) {
        return community;
    }

    function getUserStakedAmount(address user) external view override returns (uint256) {
        return _userMiningWeight[user];
    }

    function getTotalStakedAmount() external view override returns (uint256) {
        return _totalMiningWeight;
    }

    function getNFTInfo(uint256 tokenId) external view returns (NFTInfo memory info) {
        address tokenOwner = ownerOf(tokenId);
        NFTRecord storage record = _nftRecords[tokenId];
        info = NFTInfo({
            owner: tokenOwner,
            level: record.level,
            batchId: record.batchId,
            referrerTokenId: record.referrerTokenId,
            referralCount: record.referralCount,
            miningWeight: _weightForLevel(record.level),
            seed: record.seed
        });
    }

    /// @notice Returns a page of token IDs currently owned by `account`.
    /// @dev Read `balanceOf(account)` for the total and request pages to avoid oversized RPC responses.
    function tokensOfOwner(address account, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds)
    {
        uint256 balance = balanceOf(account);
        if (offset >= balance || limit == 0) return new uint256[](0);

        uint256 length = Math.min(limit, balance - offset);
        tokenIds = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            tokenIds[i] = tokenOfOwnerByIndex(account, offset + i);
        }
    }

    /// @notice Current Nutbox platform fee recipient used for the next mint.
    function platformFeeReceiver() public view returns (address) {
        address committee = ICommunityCommittee(community).committee();
        return ICommittee(committee).getFeeRecipient();
    }

    /// @notice Current platform fee rate used for the next mint.
    function platformFeeBps() public view returns (uint16) {
        return INFTMiningPlatformFee(factory).platformFeeBps();
    }

    function levelCount() external view returns (uint256) {
        return levelThresholds.length;
    }

    function miningWeightOf(uint256 tokenId) public view returns (uint256) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _weightForLevel(_nftRecords[tokenId].level);
    }

    // ───────────────────────────────── Internals ───────────────────────────────

    function _createBatch(uint256 maxSupply, address paymentAsset, uint256 mintPrice, uint16 referralBps)
        internal
        returns (uint256 batchId)
    {
        _validateBatchConfig(maxSupply, paymentAsset, mintPrice, referralBps);

        batchId = ++batchCount;
        if (batchId > type(uint32).max) revert InvalidBatchConfig();
        uint8 paletteId = uint8(((batchId - 1) % MAX_PALETTES) + 1);
        currentBatchId = batchId;
        batches[batchId] = Batch({
            paymentAsset: paymentAsset,
            referralBps: referralBps,
            paletteId: paletteId,
            active: true,
            paused: false,
            mintPrice: mintPrice,
            maxSupply: maxSupply,
            minted: 0
        });

        emit BatchCreated(batchId, maxSupply, paymentAsset, mintPrice, referralBps, paletteId);
        emit ContractURIUpdated();
    }

    function _collectPayment(
        Batch storage batch,
        address feeReceiver,
        uint256 platformFeeAmount,
        address commissionReceiver,
        uint256 commissionAmount
    ) internal {
        uint256 receiverAmount = batch.mintPrice - platformFeeAmount - commissionAmount;

        if (batch.paymentAsset == address(0)) {
            if (msg.value != batch.mintPrice) revert InvalidPayment();
            if (platformFeeAmount > 0) {
                Address.sendValue(payable(feeReceiver), platformFeeAmount);
            }
            if (commissionAmount > 0) {
                Address.sendValue(payable(commissionReceiver), commissionAmount);
            }
            if (receiverAmount > 0) {
                Address.sendValue(payable(fundsReceiver), receiverAmount);
            }
        } else {
            if (msg.value != 0) revert InvalidPayment();
            IERC20 paymentToken = IERC20(batch.paymentAsset);
            if (platformFeeAmount > 0) {
                paymentToken.safeTransferFrom(msg.sender, feeReceiver, platformFeeAmount);
            }
            if (commissionAmount > 0) {
                paymentToken.safeTransferFrom(msg.sender, commissionReceiver, commissionAmount);
            }
            if (receiverAmount > 0) {
                paymentToken.safeTransferFrom(msg.sender, fundsReceiver, receiverAmount);
            }
        }
    }

    function _applyLevelUpgrade(uint256 tokenId, address tokenOwner, uint32 newLevel) internal {
        NFTRecord storage record = _nftRecords[tokenId];
        uint32 previousLevel = record.level;
        uint256 previousWeight = _weightForLevel(previousLevel);
        uint256 newWeight = _weightForLevel(newLevel);

        ICommunity communityContract = ICommunity(community);
        communityContract.updatePools();
        uint256 shareAcc = communityContract.getShareAcc(address(this));
        _settleUser(communityContract, tokenOwner, shareAcc);

        record.level = newLevel;
        _userMiningWeight[tokenOwner] = _userMiningWeight[tokenOwner] - previousWeight + newWeight;
        _totalMiningWeight = _totalMiningWeight - previousWeight + newWeight;

        communityContract.setUserDebt(tokenOwner, Math.mulDiv(_userMiningWeight[tokenOwner], shareAcc, ACC_PRECISION));

        emit NFTLevelUp(tokenId, tokenOwner, previousLevel, newLevel, previousWeight, newWeight);
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal override {
        if (to == address(this)) revert InvalidAddress();
        if (from != to) {
            uint256 weight = _weightForLevel(_nftRecords[firstTokenId].level);
            ICommunity communityContract = ICommunity(community);
            communityContract.updatePools();
            uint256 shareAcc = communityContract.getShareAcc(address(this));

            if (from != address(0)) {
                _settleUser(communityContract, from, shareAcc);
            }
            if (to != address(0)) {
                _settleUser(communityContract, to, shareAcc);
            }

            if (from == address(0)) {
                _totalMiningWeight += weight;
            } else {
                _userMiningWeight[from] -= weight;
            }

            if (to == address(0)) {
                _totalMiningWeight -= weight;
            } else {
                _userMiningWeight[to] += weight;
            }

            if (from != address(0)) {
                communityContract.setUserDebt(from, Math.mulDiv(_userMiningWeight[from], shareAcc, ACC_PRECISION));
            }
            if (to != address(0)) {
                communityContract.setUserDebt(to, Math.mulDiv(_userMiningWeight[to], shareAcc, ACC_PRECISION));
            }

            emit MiningWeightMoved(firstTokenId, from, to, weight);
        }

        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function _settleUser(ICommunity communityContract, address user, uint256 shareAcc) internal {
        uint256 accumulated = Math.mulDiv(_userMiningWeight[user], shareAcc, ACC_PRECISION);
        uint256 debt = communityContract.getUserDebt(address(this), user);
        if (accumulated > debt) {
            communityContract.appendUserReward(user, accumulated - debt);
        }
    }

    function _levelForReferralCount(uint256 referralCount) internal view returns (uint32 level) {
        level = 1;
        uint256 count = levelThresholds.length;
        while (uint256(level) < count && referralCount >= levelThresholds[uint256(level)]) {
            ++level;
        }
    }

    function _weightForLevel(uint32 level) internal view returns (uint256) {
        return levelWeights[uint256(level) - 1];
    }

    function _validateLevelConfig(uint256[] calldata thresholds, uint256[] calldata weights) internal pure {
        uint256 count = thresholds.length;
        if (count == 0 || count > MAX_LEVELS || count != weights.length || thresholds[0] != 0 || weights[0] == 0) {
            revert InvalidLevelConfig();
        }

        for (uint256 i = 1; i < count; ++i) {
            if (thresholds[i] <= thresholds[i - 1] || weights[i] <= weights[i - 1]) revert InvalidLevelConfig();
        }
    }

    function _validateBatchConfig(uint256 maxSupply, address paymentAsset, uint256 mintPrice, uint16 referralBps)
        internal
        view
    {
        if (
            maxSupply == 0 || mintPrice == 0 || referralBps > BPS_DENOMINATOR
                || (paymentAsset != address(0) && paymentAsset.code.length == 0)
        ) revert InvalidBatchConfig();
    }

    function _validateText(string calldata value, uint256 maxLength) internal pure {
        bytes calldata raw = bytes(value);
        if (raw.length == 0 || raw.length > maxLength) revert InvalidText();

        for (uint256 i = 0; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (uint8(c) < 0x20 || c == 0x22 || c == 0x26 || c == 0x3c || c == 0x3e || c == 0x5c) revert InvalidText();
        }
    }

    function _renderSVG(uint256 tokenId, NFTRecord storage record) internal view returns (string memory) {
        INFTMiningRenderer.RenderParams memory params = INFTMiningRenderer.RenderParams({
            collectionName: _collectionName,
            tokenId: tokenId,
            seed: record.seed,
            referralCount: record.referralCount,
            miningWeight: _weightForLevel(record.level),
            batchId: record.batchId,
            level: record.level,
            paletteId: batches[record.batchId].paletteId
        });
        return INFTMiningRenderer(renderer).renderSVG(params);
    }

    function _generationForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? (uint256(level) - 1) / 6 : 0;
    }

    function _phaseForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? ((uint256(level) - 1) % 6) + 1 : uint256(level);
    }
}
