// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
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
 * native price and may use an NFT referrer. Newly minted NFTs start with index mining active.
 * Any later ERC721 transfer clears that activation, and the new owner must permanently burn
 * the configured community-token amount to reactivate it. Existing community mining is unchanged.
 */
contract IndexBrokerNFT is ERC721Enumerable, IPool, Initializable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant INDEX_REWARD_PRECISION = 1e24;
    uint256 public constant MAX_LEVELS = 16;
    uint256 public constant MAX_PALETTES = 6;
    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;
    address public constant INDEX_MINING_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    bytes4 private constant _INTERFACE_ID_ERC4906 = 0x49064906;

    struct NFTRecord {
        uint32 level;
        bool indexMiningActive;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 seed;
        uint256 indexMiningWeight;
        uint256 indexRewardDebt;
        uint256 pendingIndexRewards;
    }

    struct NFTInfo {
        address owner;
        uint32 level;
        uint256 referrerTokenId;
        uint256 referralCount;
        uint256 miningWeight;
        bool miningActive;
        bool indexMiningActive;
        uint256 indexMiningWeight;
        uint256 pendingIndexRewards;
        uint256 seed;
    }

    address public factory;
    address public community;
    address public communityToken;
    address public fundsReceiver;
    address public renderer;
    address public ammVault;
    address public indexToken;

    string private _collectionName;
    string private _collectionSymbol;

    uint256 public communityTokenPrice;
    uint256 public indexMiningActivationTokenAmount;
    uint256 public nativePrice;
    uint256 public maxSupply;
    uint16 public referralBps;
    bool public lockWhitelistSlots;

    uint256 public nextTokenId;
    uint256 public totalWhitelistAllocation;
    uint256 public whitelistMinted;
    uint256 public paidMinted;

    uint256 public minimumIndexMiningWeight;
    uint256 public totalActiveIndexMiningWeight;
    uint256 public indexRewardPerWeight;
    uint256 public queuedIndexRewards;
    uint256 public totalIndexRewardsInjected;
    uint256 public totalIndexRewardsClaimed;

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
    event IndexMiningActivated(address indexed owner, uint256 indexed tokenId, uint256 tokenAmount);
    event IndexMiningDeactivated(address indexed owner, uint256 indexed tokenId);
    event IndexMiningWeightUpgraded(
        address indexed owner, uint256 indexed tokenId, uint256 tokenAmount, uint256 previousWeight, uint256 newWeight
    );
    event IndexMiningWeightReduced(uint256 indexed tokenId, uint256 previousWeight, uint256 newWeight);
    event IndexRewardsInjected(address indexed caller, uint256 amount, uint256 distributed, uint256 queued);
    event IndexRewardsClaimed(address indexed owner, uint256 indexed tokenId, uint256 amount);
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
    error NotTokenOwner();
    error IndexMiningAlreadyActive();
    error IndexMiningNotActive();
    error InvalidIndexMiningWeight();
    error InvalidIndexRewardAmount();
    error NoIndexRewards();

    constructor() ERC721("", "") {
        _disableInitializers();
    }

    function initialize(
        address community_,
        address admin_,
        address renderer_,
        address ammVault_,
        address indexToken_,
        string calldata name_,
        string calldata symbol_,
        address fundsReceiver_,
        uint256[] calldata thresholds_,
        uint256[] calldata weights_,
        uint256 communityTokenPrice_,
        uint256 indexMiningActivationTokenAmount_,
        uint256 nativePrice_,
        uint256 maxSupply_,
        uint16 referralBps_,
        bool lockWhitelistSlots_,
        address[] calldata whitelistAccounts_,
        uint256[] calldata whitelistAllowances_
    ) external initializer {
        if (
            community_ == address(0) || admin_ == address(0) || renderer_.code.length == 0 || ammVault_.code.length == 0
                || indexToken_.code.length == 0 || fundsReceiver_ == address(0) || fundsReceiver_ == address(this)
        ) revert InvalidAddress();

        _validateText(name_, MAX_NAME_LENGTH);
        _validateText(symbol_, MAX_SYMBOL_LENGTH);
        _validateLevelConfig(thresholds_, weights_);
        if (
            communityTokenPrice_ == 0 || indexMiningActivationTokenAmount_ == 0 || maxSupply_ == 0
                || referralBps_ > BPS_DENOMINATOR || (nativePrice_ == 0 && referralBps_ != 0)
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
        indexToken = indexToken_;
        _collectionName = name_;
        _collectionSymbol = symbol_;
        communityTokenPrice = communityTokenPrice_;
        indexMiningActivationTokenAmount = indexMiningActivationTokenAmount_;
        minimumIndexMiningWeight = 10 ** IERC20Metadata(communityToken_).decimals();
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
        return IIndexBrokerNFTRenderer(renderer).renderTokenURI(_renderParams(tokenId));
    }

    function tokenSVG(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return IIndexBrokerNFTRenderer(renderer).renderSVG(_renderParams(tokenId));
    }

    function contractURI() external view returns (string memory) {
        return IIndexBrokerNFTRenderer(renderer).renderContractURI(_collectionName);
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

        _nftRecords[tokenId] = NFTRecord({
            level: 1,
            indexMiningActive: true,
            referrerTokenId: effectiveReferrerTokenId,
            referralCount: 0,
            seed: seed,
            indexMiningWeight: 0,
            indexRewardDebt: 0,
            pendingIndexRewards: 0
        });

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

    // ────────────────────────── Index mining activation ───────────────────────

    function activateIndexMining(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        NFTRecord storage record = _nftRecords[tokenId];
        if (record.indexMiningActive) revert IndexMiningAlreadyActive();

        IERC20(communityToken).safeTransferFrom(msg.sender, INDEX_MINING_BURN_ADDRESS, indexMiningActivationTokenAmount);

        record.indexMiningActive = true;
        uint256 weight = record.indexMiningWeight;
        if (weight != 0) {
            totalActiveIndexMiningWeight += weight;
            record.indexRewardDebt = Math.mulDiv(weight, indexRewardPerWeight, INDEX_REWARD_PRECISION);
            _distributeQueuedIndexRewards();
        }
        emit IndexMiningActivated(msg.sender, tokenId, indexMiningActivationTokenAmount);
        emit MetadataUpdate(tokenId);
    }

    function upgradeIndexMining(uint256 tokenId, uint256 tokenAmount) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        NFTRecord storage record = _nftRecords[tokenId];
        if (!record.indexMiningActive) revert IndexMiningNotActive();
        if (tokenAmount < minimumIndexMiningWeight) revert InvalidIndexMiningWeight();

        _settleIndexRewards(record);
        IERC20(communityToken).safeTransferFrom(msg.sender, INDEX_MINING_BURN_ADDRESS, tokenAmount);

        uint256 previousWeight = record.indexMiningWeight;
        uint256 newWeight = previousWeight + tokenAmount;
        record.indexMiningWeight = newWeight;
        totalActiveIndexMiningWeight += tokenAmount;
        record.indexRewardDebt = Math.mulDiv(newWeight, indexRewardPerWeight, INDEX_REWARD_PRECISION);
        _distributeQueuedIndexRewards();

        emit IndexMiningWeightUpgraded(msg.sender, tokenId, tokenAmount, previousWeight, newWeight);
        emit MetadataUpdate(tokenId);
    }

    function injectIndexRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidIndexRewardAmount();
        IERC20(indexToken).safeTransferFrom(msg.sender, address(this), amount);

        totalIndexRewardsInjected += amount;
        queuedIndexRewards += amount;
        uint256 distributed = _distributeQueuedIndexRewards();
        emit IndexRewardsInjected(msg.sender, amount, distributed, queuedIndexRewards);
    }

    function claimIndexRewards(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        NFTRecord storage record = _nftRecords[tokenId];
        _settleIndexRewards(record);
        amount = record.pendingIndexRewards;
        if (amount == 0) revert NoIndexRewards();

        record.pendingIndexRewards = 0;
        totalIndexRewardsClaimed += amount;
        IERC20(indexToken).safeTransfer(msg.sender, amount);
        emit IndexRewardsClaimed(msg.sender, tokenId, amount);
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
            indexMiningActive: record.indexMiningActive,
            indexMiningWeight: record.indexMiningWeight,
            pendingIndexRewards: pendingIndexRewardsOf(tokenId),
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

    function indexMiningActiveOf(uint256 tokenId) public view returns (bool) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _nftRecords[tokenId].indexMiningActive;
    }

    function indexMiningWeightOf(uint256 tokenId) public view returns (uint256) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _nftRecords[tokenId].indexMiningWeight;
    }

    function activeIndexMiningWeightOf(uint256 tokenId) external view returns (uint256) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        NFTRecord storage record = _nftRecords[tokenId];
        return record.indexMiningActive ? record.indexMiningWeight : 0;
    }

    function pendingIndexRewardsOf(uint256 tokenId) public view returns (uint256 pending) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        NFTRecord storage record = _nftRecords[tokenId];
        pending = record.pendingIndexRewards;
        if (record.indexMiningActive && record.indexMiningWeight != 0) {
            uint256 accumulated = Math.mulDiv(record.indexMiningWeight, indexRewardPerWeight, INDEX_REWARD_PRECISION);
            if (accumulated > record.indexRewardDebt) pending += accumulated - record.indexRewardDebt;
        }
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

        NFTRecord storage indexRecord = _nftRecords[firstTokenId];
        if (from == address(0)) {
            indexRecord.indexMiningActive = true;
            emit IndexMiningActivated(to, firstTokenId, 0);
        } else {
            _settleIndexRewards(indexRecord);
            uint256 previousIndexWeight = indexRecord.indexMiningWeight;
            if (indexRecord.indexMiningActive && previousIndexWeight != 0) {
                totalActiveIndexMiningWeight -= previousIndexWeight;
            }
            uint256 newIndexWeight = previousIndexWeight / 2;
            if (newIndexWeight < minimumIndexMiningWeight) newIndexWeight = 0;
            indexRecord.indexMiningActive = false;
            indexRecord.indexMiningWeight = newIndexWeight;
            indexRecord.indexRewardDebt = 0;

            emit IndexMiningDeactivated(from, firstTokenId);
            emit IndexMiningWeightReduced(firstTokenId, previousIndexWeight, newIndexWeight);
            emit MetadataUpdate(firstTokenId);
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

    function _settleIndexRewards(NFTRecord storage record) internal {
        if (!record.indexMiningActive || record.indexMiningWeight == 0) return;
        uint256 accumulated = Math.mulDiv(record.indexMiningWeight, indexRewardPerWeight, INDEX_REWARD_PRECISION);
        if (accumulated > record.indexRewardDebt) {
            record.pendingIndexRewards += accumulated - record.indexRewardDebt;
        }
        record.indexRewardDebt = accumulated;
    }

    function _distributeQueuedIndexRewards() internal returns (uint256 distributed) {
        uint256 activeWeight = totalActiveIndexMiningWeight;
        uint256 queued = queuedIndexRewards;
        if (activeWeight == 0 || queued == 0) return 0;

        uint256 increment = Math.mulDiv(queued, INDEX_REWARD_PRECISION, activeWeight);
        if (increment == 0) return 0;
        distributed = Math.mulDiv(increment, activeWeight, INDEX_REWARD_PRECISION);
        indexRewardPerWeight += increment;
        queuedIndexRewards = queued - distributed;
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

    function _renderParams(uint256 tokenId) internal view returns (IIndexBrokerNFTRenderer.RenderParams memory params) {
        NFTRecord storage record = _nftRecords[tokenId];
        params = IIndexBrokerNFTRenderer.RenderParams({
            collectionName: _collectionName,
            tokenId: tokenId,
            seed: record.seed,
            referralCount: record.referralCount,
            referrerTokenId: record.referrerTokenId,
            miningWeight: _weightForLevel(record.level),
            indexMiningWeight: record.indexMiningWeight,
            level: record.level,
            paletteId: uint8(((tokenId - 1) % MAX_PALETTES) + 1),
            miningActive: ownerOf(tokenId) != ammVault,
            indexMiningActive: record.indexMiningActive
        });
    }
}
