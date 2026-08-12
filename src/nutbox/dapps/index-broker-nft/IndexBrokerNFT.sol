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

import "../../interfaces/ICommunity.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/IPool.sol";
import "./IIndexBrokerNFTRenderer.sol";

interface ICommunityCommittee {
    function committee() external view returns (address);
}

interface INFTMiningPlatformFee {
    function platformFeeBps() external view returns (uint16);
}

interface IIndexBrokerNFTAMM {
    function isAcceptingNFT(address from, uint256 tokenId) external view returns (bool);
}

/**
 * @title IndexBrokerNFT
 * @notice Fixed-supply NFT mining pool paid in its community token.
 *
 * Every mint deposits a fixed amount of the community token into its paired AMM vault.
 * Whitelisted accounts waive the native-coin price. Other accounts pay the immutable
 * native price and may use an NFT referrer. NFT ownership remains the Nutbox staking ledger.
 */
contract IndexBrokerNFT is ERC721Enumerable, IPool, Initializable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant MAX_LEVELS = 16;
    uint256 public constant MAX_PALETTES = 6;
    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;

    bytes4 private constant _INTERFACE_ID_ERC4906 = 0x49064906;

    struct NFTRecord {
        uint32 level;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 seed;
    }

    struct NFTInfo {
        address owner;
        uint32 level;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 miningWeight;
        bool miningActive;
        uint256 seed;
    }

    address public factory;
    address public community;
    address public communityToken;
    address public fundsReceiver;
    address public renderer;
    address public ammVault;

    string private _collectionName;
    string private _collectionSymbol;

    uint256 public communityTokenPrice;
    uint256 public nativePrice;
    uint256 public maxSupply;
    uint16 public referralBps;
    bool public lockWhitelistSlots;

    uint256 public nextTokenId;
    uint256 public totalWhitelistAllocation;
    uint256 public whitelistMinted;
    uint256 public paidMinted;

    uint256[] public levelThresholds;
    uint256[] public levelWeights;

    mapping(address => uint256) public whitelistAllowance;
    mapping(address => uint256) public whitelistMintedBy;
    mapping(uint256 => NFTRecord) private _nftRecords;
    mapping(address => uint256) private _userMiningWeight;
    uint256 private _totalMiningWeight;

    event FundsReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event NFTMinted(
        address indexed buyer,
        uint256 indexed tokenId,
        bool indexed whitelistMint,
        uint256 referrerTokenId,
        uint256 communityTokenAmount,
        uint256 nativeAmount
    );
    event WhitelistAllowanceConsumed(
        address indexed account, uint256 indexed tokenId, uint256 minted, uint256 allowance
    );
    event NativePaymentRefunded(address indexed account, uint256 indexed tokenId, uint256 amount);
    event PlatformFeePaid(uint256 indexed tokenId, address indexed receiver, uint256 amount);
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
    event MetadataUpdate(uint256 _tokenId);
    event ContractURIUpdated();

    error InvalidAddress();
    error InvalidText();
    error InvalidLevelConfig();
    error InvalidMintConfig();
    error InvalidWhitelistConfig();
    error PoolIsInactive();
    error MaxSupplyReached();
    error PaidSupplyReached();
    error WhitelistOnly();
    error InvalidPayment();
    error InvalidCommunityTokenPayment();
    error InvalidAMMTransfer();
    error ReferrerInAMM();

    constructor() ERC721("", "") {
        _disableInitializers();
    }

    function initialize(
        address community_,
        address admin_,
        address renderer_,
        address ammVault_,
        string calldata name_,
        string calldata symbol_,
        address fundsReceiver_,
        uint256[] calldata thresholds_,
        uint256[] calldata weights_,
        uint256 communityTokenPrice_,
        uint256 nativePrice_,
        uint256 maxSupply_,
        uint16 referralBps_,
        bool lockWhitelistSlots_,
        address[] calldata whitelistAccounts_,
        uint256[] calldata whitelistAllowances_
    ) external initializer {
        if (
            community_ == address(0) || admin_ == address(0) || renderer_.code.length == 0 || ammVault_.code.length == 0
                || fundsReceiver_ == address(0) || fundsReceiver_ == address(this)
        ) revert InvalidAddress();

        _validateText(name_, MAX_NAME_LENGTH);
        _validateText(symbol_, MAX_SYMBOL_LENGTH);
        _validateLevelConfig(thresholds_, weights_);
        if (
            communityTokenPrice_ == 0 || maxSupply_ == 0 || referralBps_ > BPS_DENOMINATOR
                || (nativePrice_ == 0 && referralBps_ != 0)
        ) revert InvalidMintConfig();
        if (whitelistAccounts_.length == 0 || whitelistAccounts_.length != whitelistAllowances_.length) {
            revert InvalidWhitelistConfig();
        }

        address communityToken_ = ICommunity(community_).getCommunityToken();
        if (communityToken_.code.length == 0) revert InvalidAddress();

        factory = msg.sender;
        community = community_;
        communityToken = communityToken_;
        fundsReceiver = fundsReceiver_;
        renderer = renderer_;
        ammVault = ammVault_;
        _collectionName = name_;
        _collectionSymbol = symbol_;
        communityTokenPrice = communityTokenPrice_;
        nativePrice = nativePrice_;
        maxSupply = maxSupply_;
        referralBps = referralBps_;
        lockWhitelistSlots = nativePrice_ == 0 || lockWhitelistSlots_;

        for (uint256 i; i < thresholds_.length; ++i) {
            levelThresholds.push(thresholds_[i]);
            levelWeights.push(weights_[i]);
        }

        uint256 whitelistTotal;
        for (uint256 i; i < whitelistAccounts_.length; ++i) {
            address account = whitelistAccounts_[i];
            uint256 allowance = whitelistAllowances_[i];
            if (account == address(0) || allowance == 0 || whitelistAllowance[account] != 0) {
                revert InvalidWhitelistConfig();
            }
            whitelistAllowance[account] = allowance;
            whitelistTotal += allowance;
        }
        if (whitelistTotal > maxSupply_ || (nativePrice_ == 0 && whitelistTotal != maxSupply_)) {
            revert InvalidWhitelistConfig();
        }
        totalWhitelistAllocation = whitelistTotal;

        _transferOwnership(admin_);
        emit ContractURIUpdated();
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
            '","description":"A fixed-supply community-token mining NFT with transferable mining weight.",',
            '"image":"',
            image,
            '","attributes":[',
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
            _miningAttributes(tokenId),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function tokenSVG(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _renderSVG(tokenId, _nftRecords[tokenId]);
    }

    function contractURI() external view returns (string memory) {
        string memory collectionSvg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
            '<rect width="512" height="512" rx="40" fill="#0B0E11"/>',
            '<circle cx="256" cy="220" r="112" fill="none" stroke="#F0B90B" stroke-width="8"/>',
            '<text x="256" y="225" text-anchor="middle" fill="white" font-family="sans-serif" font-size="34">INDEX</text>',
            '<text x="256" y="370" text-anchor="middle" fill="#F0B90B" font-family="sans-serif" font-size="28">',
            _collectionName,
            "</text></svg>"
        );
        string memory json = string.concat(
            '{"name":"',
            _collectionName,
            '","description":"A fixed-supply community-token NFT mining pool.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(collectionSvg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ───────────────────────────── Pool administration ─────────────────────────

    function setFundsReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0) || newReceiver == address(this)) revert InvalidAddress();
        address previous = fundsReceiver;
        fundsReceiver = newReceiver;
        emit FundsReceiverChanged(previous, newReceiver);
    }

    // ─────────────────────────────────── Mint ──────────────────────────────────

    function mint(uint256 referrerTokenId) external payable nonReentrant returns (uint256 tokenId) {
        if (!ICommunity(community).poolActived(address(this))) revert PoolIsInactive();
        if (nextTokenId >= maxSupply) revert MaxSupplyReached();

        bool isWhitelistMint = whitelistMintedBy[msg.sender] < whitelistAllowance[msg.sender];
        address commissionReceiver;
        uint256 effectiveReferrerTokenId;

        if (isWhitelistMint) {
            ++whitelistMintedBy[msg.sender];
            ++whitelistMinted;
        } else {
            if (nativePrice == 0) revert WhitelistOnly();
            if (lockWhitelistSlots && paidMinted >= maxSupply - totalWhitelistAllocation) {
                revert PaidSupplyReached();
            }
            if (msg.value != nativePrice) revert InvalidPayment();
            ++paidMinted;
            effectiveReferrerTokenId = referrerTokenId;
            if (effectiveReferrerTokenId != 0) {
                commissionReceiver = ownerOf(effectiveReferrerTokenId);
                if (commissionReceiver == ammVault) revert ReferrerInAMM();
            }
        }

        tokenId = ++nextTokenId;
        bytes32 previousBlockHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    block.chainid,
                    tokenId,
                    msg.sender,
                    isWhitelistMint,
                    block.prevrandao,
                    previousBlockHash
                )
            )
        );

        _nftRecords[tokenId] =
            NFTRecord({level: 1, referrerTokenId: effectiveReferrerTokenId, referralCount: 0, seed: seed});

        _collectCommunityToken();

        if (isWhitelistMint) {
            if (msg.value != 0) {
                Address.sendValue(payable(msg.sender), msg.value);
                emit NativePaymentRefunded(msg.sender, tokenId, msg.value);
            }
            emit WhitelistAllowanceConsumed(
                msg.sender, tokenId, whitelistMintedBy[msg.sender], whitelistAllowance[msg.sender]
            );
        } else {
            _collectNativePayment(tokenId, effectiveReferrerTokenId, commissionReceiver);
        }

        _safeMint(msg.sender, tokenId);
        emit NFTMinted(
            msg.sender,
            tokenId,
            isWhitelistMint,
            effectiveReferrerTokenId,
            communityTokenPrice,
            isWhitelistMint ? 0 : nativePrice
        );
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
        NFTRecord storage record = _nftRecords[tokenId];
        address tokenOwner = ownerOf(tokenId);
        info = NFTInfo({
            owner: tokenOwner,
            level: record.level,
            referrerTokenId: record.referrerTokenId,
            referralCount: record.referralCount,
            miningWeight: _weightForLevel(record.level),
            miningActive: tokenOwner != ammVault,
            seed: record.seed
        });
    }

    function tokensOfOwner(address account, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds)
    {
        uint256 balance = balanceOf(account);
        if (offset >= balance || limit == 0) return new uint256[](0);

        uint256 length = Math.min(limit, balance - offset);
        tokenIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            tokenIds[i] = tokenOfOwnerByIndex(account, offset + i);
        }
    }

    function platformFeeReceiver() public view returns (address) {
        address committee = ICommunityCommittee(community).committee();
        return ICommittee(committee).getFeeRecipient();
    }

    function platformFeeBps() public view returns (uint16) {
        return INFTMiningPlatformFee(factory).platformFeeBps();
    }

    function levelCount() external view returns (uint256) {
        return levelThresholds.length;
    }

    function remainingWhitelistMints(address account) external view returns (uint256) {
        return whitelistAllowance[account] - whitelistMintedBy[account];
    }

    function remainingPaidMints() external view returns (uint256) {
        if (!lockWhitelistSlots) return maxSupply - nextTokenId;
        return maxSupply - totalWhitelistAllocation - paidMinted;
    }

    function miningWeightOf(uint256 tokenId) public view returns (uint256) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _weightForLevel(_nftRecords[tokenId].level);
    }

    function activeMiningWeightOf(uint256 tokenId) public view returns (uint256) {
        return miningActiveOf(tokenId) ? miningWeightOf(tokenId) : 0;
    }

    function miningActiveOf(uint256 tokenId) public view returns (bool) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return ownerOf(tokenId) != ammVault;
    }

    // ───────────────────────────────── Internals ───────────────────────────────

    function _collectCommunityToken() internal {
        IERC20 paymentToken = IERC20(communityToken);
        uint256 balanceBefore = paymentToken.balanceOf(ammVault);
        paymentToken.safeTransferFrom(msg.sender, ammVault, communityTokenPrice);
        if (paymentToken.balanceOf(ammVault) - balanceBefore != communityTokenPrice) {
            revert InvalidCommunityTokenPayment();
        }
    }

    function _collectNativePayment(uint256 tokenId, uint256 referrerTokenId, address commissionReceiver) internal {
        uint256 platformFeeAmount = Math.mulDiv(nativePrice, platformFeeBps(), BPS_DENOMINATOR);
        uint256 distributableAmount = nativePrice - platformFeeAmount;
        uint256 commissionAmount;

        if (referrerTokenId != 0) {
            NFTRecord storage referrerRecord = _nftRecords[referrerTokenId];
            ++referrerRecord.referralCount;
            commissionAmount = Math.mulDiv(distributableAmount, referralBps, BPS_DENOMINATOR);

            uint32 newLevel = _levelForReferralCount(referrerRecord.referralCount);
            if (newLevel != referrerRecord.level) {
                _applyLevelUpgrade(referrerTokenId, commissionReceiver, newLevel);
            }
            emit MetadataUpdate(referrerTokenId);
            emit NFTReferralRecorded(referrerTokenId, tokenId, commissionReceiver, commissionAmount);
        }

        address feeReceiver = platformFeeReceiver();
        if (platformFeeAmount != 0) Address.sendValue(payable(feeReceiver), platformFeeAmount);
        if (commissionAmount != 0) Address.sendValue(payable(commissionReceiver), commissionAmount);

        uint256 receiverAmount = nativePrice - platformFeeAmount - commissionAmount;
        if (receiverAmount != 0) Address.sendValue(payable(fundsReceiver), receiverAmount);
        emit PlatformFeePaid(tokenId, feeReceiver, platformFeeAmount);
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
        if (to == ammVault && !IIndexBrokerNFTAMM(ammVault).isAcceptingNFT(from, firstTokenId)) {
            revert InvalidAMMTransfer();
        }

        address miningFrom = from == ammVault ? address(0) : from;
        address miningTo = to == ammVault ? address(0) : to;
        if (miningFrom != miningTo) {
            uint256 weight = _weightForLevel(_nftRecords[firstTokenId].level);
            ICommunity communityContract = ICommunity(community);
            communityContract.updatePools();
            uint256 shareAcc = communityContract.getShareAcc(address(this));

            if (miningFrom != address(0)) _settleUser(communityContract, miningFrom, shareAcc);
            if (miningTo != address(0)) _settleUser(communityContract, miningTo, shareAcc);

            if (miningFrom == address(0)) _totalMiningWeight += weight;
            else _userMiningWeight[miningFrom] -= weight;

            if (miningTo == address(0)) _totalMiningWeight -= weight;
            else _userMiningWeight[miningTo] += weight;

            if (miningFrom != address(0)) {
                communityContract.setUserDebt(
                    miningFrom, Math.mulDiv(_userMiningWeight[miningFrom], shareAcc, ACC_PRECISION)
                );
            }
            if (miningTo != address(0)) {
                communityContract.setUserDebt(
                    miningTo, Math.mulDiv(_userMiningWeight[miningTo], shareAcc, ACC_PRECISION)
                );
            }
            emit MiningWeightMoved(firstTokenId, from, to, weight);
            if (from == ammVault || to == ammVault) emit MetadataUpdate(firstTokenId);
        }
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function _settleUser(ICommunity communityContract, address user, uint256 shareAcc) internal {
        uint256 accumulated = Math.mulDiv(_userMiningWeight[user], shareAcc, ACC_PRECISION);
        uint256 debt = communityContract.getUserDebt(address(this), user);
        if (accumulated > debt) communityContract.appendUserReward(user, accumulated - debt);
    }

    function _levelForReferralCount(uint256 referralCount) internal view returns (uint32 level) {
        level = 1;
        uint256 count = levelThresholds.length;
        while (uint256(level) < count && referralCount >= levelThresholds[uint256(level)]) ++level;
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

    function _validateText(string calldata value, uint256 maxLength) internal pure {
        bytes calldata raw = bytes(value);
        if (raw.length == 0 || raw.length > maxLength) revert InvalidText();
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (uint8(c) < 0x20 || c == 0x22 || c == 0x26 || c == 0x3c || c == 0x3e || c == 0x5c) {
                revert InvalidText();
            }
        }
    }

    function _renderSVG(uint256 tokenId, NFTRecord storage record) internal view returns (string memory) {
        uint8 paletteId = uint8(((tokenId - 1) % MAX_PALETTES) + 1);
        IIndexBrokerNFTRenderer.RenderParams memory params = IIndexBrokerNFTRenderer.RenderParams({
            collectionName: _collectionName,
            tokenId: tokenId,
            seed: record.seed,
            referralCount: record.referralCount,
            miningWeight: _weightForLevel(record.level),
            level: record.level,
            paletteId: paletteId
        });
        return IIndexBrokerNFTRenderer(renderer).renderSVG(params);
    }

    function _miningAttributes(uint256 tokenId) internal view returns (string memory) {
        return string.concat(
            '{"trait_type":"Mining Weight","value":',
            miningWeightOf(tokenId).toString(),
            '},{"trait_type":"Mining Active","value":',
            miningActiveOf(tokenId) ? "true" : "false",
            "}"
        );
    }

    function _generationForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? (uint256(level) - 1) / 6 : 0;
    }

    function _phaseForLevel(uint32 level) internal pure returns (uint256) {
        return level > 6 ? ((uint256(level) - 1) % 6) + 1 : uint256(level);
    }
}
