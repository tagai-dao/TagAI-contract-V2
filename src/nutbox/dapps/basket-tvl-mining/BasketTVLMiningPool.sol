// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../../interfaces/IBasketRegistry.sol";
import "../../../interfaces/IBasketTVLMiningPool.sol";
import "../../../interfaces/IBasketToken.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/ICommunity.sol";
import "./BasketStakePool.sol";

/**
 * @title BasketTVLMiningPool
 * @notice A shared Nutbox pool where registered Basket tokens mine according to the amount of
 * the Community token actually held by each Basket.
 *
 * Basket assets are not transferred into this contract. An eligible Basket must include the Community token
 * as one of its constituent legs. Its mining amount is the Community token's ERC20 balance at the Basket address.
 */
contract BasketTVLMiningPool is IBasketTVLMiningPool, Initializable, ReentrancyGuard {
    uint256 public constant ACC_PRECISION = 1e12;
    uint256 public constant MAX_BASKET_POOLS_PER_NFT = 3;

    address public factory;
    address public community;
    address public basketRegistry;
    address public nftMiningPool;
    address public childPoolTemplate;
    address public communityToken;
    uint256 public lockDuration;
    uint16 public nftRewardBps;
    string public name;

    mapping(address basket => BasketStake stake) private _basketStakes;
    mapping(address beneficiary => uint256 amount) private _beneficiaryMiningAmount;
    mapping(uint256 nftTokenId => uint256 count) public override nftBasketPoolCount;
    uint256 private _totalMiningAmount;

    event BasketStakeCreated(
        address indexed basket,
        address indexed basketCreator,
        uint256 indexed nftTokenId,
        uint256 miningAmount,
        uint256 updatedAt
    );
    event BasketChildPoolCreated(
        address indexed basket,
        address indexed childPool,
        address indexed basketCreator,
        uint256 nftTokenId,
        uint16 nftRewardBps,
        uint256 lockDuration
    );
    event BasketStakeUpdated(
        address indexed basket,
        address indexed basketCreator,
        uint256 previousMiningAmount,
        uint256 newMiningAmount,
        uint256 updatedAt
    );

    error InvalidAddress();
    error InvalidBasket();
    error CommunityTokenNotInBasket();
    error BasketStakeAlreadyExists();
    error BasketStakeNotFound();
    error OnlyBasketCreator();
    error OwnerDoesNotOwnMiningNFT();
    error NftBasketPoolLimitReached();
    error PoolIsInactive();
    error InsufficientOperationFee();
    error NativeTransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address community_,
        string calldata name_,
        address basketRegistry_,
        address nftMiningPool_,
        address childPoolTemplate_,
        uint256 lockDuration_,
        uint16 nftRewardBps_
    ) external initializer {
        if (
            community_ == address(0) || basketRegistry_.code.length == 0 || nftMiningPool_.code.length == 0
                || childPoolTemplate_.code.length == 0 || lockDuration_ == 0 || nftRewardBps_ > 10_000
        ) {
            revert InvalidAddress();
        }

        factory = msg.sender;
        community = community_;
        name = name_;
        basketRegistry = basketRegistry_;
        nftMiningPool = nftMiningPool_;
        childPoolTemplate = childPoolTemplate_;
        communityToken = ICommunity(community_).getCommunityToken();
        if (communityToken.code.length == 0) revert InvalidAddress();
        lockDuration = lockDuration_;
        nftRewardBps = nftRewardBps_;
    }

    /**
     * @notice Registers a Basket and attributes its actual Community-token balance to the child pool.
     * @dev Only the Basket's creator payout address may register it, and that address
     * must own the selected NFT when the child pool is created.
     */
    function createBasketStake(address basket, uint256 nftTokenId)
        external
        override
        nonReentrant
        returns (address childPool)
    {
        if (!ICommunity(community).poolActived(address(this))) revert PoolIsInactive();
        if (!IBasketRegistry(basketRegistry).isBasket(basket)) revert InvalidBasket();
        if (_basketStakes[basket].exists) revert BasketStakeAlreadyExists();

        address basketCreator = IBasketToken(basket).creatorPayout();
        if (basketCreator == address(0)) revert InvalidAddress();
        if (msg.sender != basketCreator) revert OnlyBasketCreator();
        try IERC721(nftMiningPool).ownerOf(nftTokenId) returns (address nftOwner) {
            if (nftOwner != basketCreator) revert OwnerDoesNotOwnMiningNFT();
        } catch {
            revert OwnerDoesNotOwnMiningNFT();
        }
        if (nftBasketPoolCount[nftTokenId] >= MAX_BASKET_POOLS_PER_NFT) {
            revert NftBasketPoolLimitReached();
        }
        uint256 miningAmount = _basketCommunityTokenBalance(basket);

        childPool = Clones.clone(childPoolTemplate);
        BasketStakePool(childPool)
            .initialize(address(this), community, basket, nftMiningPool, nftTokenId, nftRewardBps, lockDuration);

        ICommunity communityContract = ICommunity(community);
        communityContract.updatePools();
        uint256 shareAcc = communityContract.getShareAcc(address(this));
        _settleUser(communityContract, childPool, shareAcc);

        _basketStakes[basket] = BasketStake({
            basketCreator: basketCreator,
            childPool: childPool,
            nftTokenId: nftTokenId,
            miningAmount: miningAmount,
            updatedAt: block.timestamp,
            exists: true
        });
        _beneficiaryMiningAmount[childPool] += miningAmount;
        _totalMiningAmount += miningAmount;
        nftBasketPoolCount[nftTokenId] += 1;

        communityContract.setUserDebt(
            childPool, Math.mulDiv(_beneficiaryMiningAmount[childPool], shareAcc, ACC_PRECISION)
        );

        emit BasketStakeCreated(basket, basketCreator, nftTokenId, miningAmount, block.timestamp);
        emit BasketChildPoolCreated(basket, childPool, basketCreator, nftTokenId, nftRewardBps, lockDuration);
    }

    /**
     * @notice Refreshes a registered Basket's mining amount from its current Community-token balance.
     * @dev Permissionless. The caller cannot supply or influence the recorded amount directly.
     */
    function updateBasketStake(address basket) external payable override nonReentrant {
        BasketStake storage stake = _basketStakes[basket];
        if (!stake.exists) revert BasketStakeNotFound();

        _chargeTier3Fee();

        uint256 newMiningAmount = _basketCommunityTokenBalance(basket);
        uint256 previousMiningAmount = stake.miningAmount;
        address basketCreator = stake.basketCreator;
        address childPool = stake.childPool;

        ICommunity communityContract = ICommunity(community);
        communityContract.updatePools();
        uint256 shareAcc = communityContract.getShareAcc(address(this));
        _settleUser(communityContract, childPool, shareAcc);

        stake.miningAmount = newMiningAmount;
        stake.updatedAt = block.timestamp;
        _beneficiaryMiningAmount[childPool] =
            _beneficiaryMiningAmount[childPool] - previousMiningAmount + newMiningAmount;
        _totalMiningAmount = _totalMiningAmount - previousMiningAmount + newMiningAmount;

        communityContract.setUserDebt(
            childPool, Math.mulDiv(_beneficiaryMiningAmount[childPool], shareAcc, ACC_PRECISION)
        );

        emit BasketStakeUpdated(basket, basketCreator, previousMiningAmount, newMiningAmount, block.timestamp);
    }

    function _chargeTier3Fee() private {
        address committee = ICommunity(community).getCommittee();
        uint256 requiredFee =
            ICommittee(committee).getFeeFree(msg.sender) ? 0 : ICommittee(committee).getPoolOperationFee();
        if (msg.value < requiredFee) revert InsufficientOperationFee();

        if (requiredFee != 0) {
            address payable recipient = ICommittee(committee).getFeeRecipient();
            (bool feeSent,) = recipient.call{value: requiredFee}("");
            if (!feeSent) revert NativeTransferFailed();
        }

        uint256 refund = msg.value - requiredFee;
        if (refund != 0) {
            (bool refunded,) = msg.sender.call{value: refund}("");
            if (!refunded) revert NativeTransferFailed();
        }
    }

    function getFactory() external view override returns (address) {
        return factory;
    }

    function getCommunity() external view override returns (address) {
        return community;
    }

    function getUserStakedAmount(address user) external view override returns (uint256) {
        return _beneficiaryMiningAmount[user];
    }

    function getTotalStakedAmount() external view override returns (uint256) {
        return _totalMiningAmount;
    }

    function getBasketStake(address basket) external view override returns (BasketStake memory) {
        return _basketStakes[basket];
    }

    function basketCommunityTokenBalance(address basket) external view override returns (uint256) {
        if (!IBasketRegistry(basketRegistry).isBasket(basket)) revert InvalidBasket();
        return _basketCommunityTokenBalance(basket);
    }

    function _basketCommunityTokenBalance(address basket) internal view returns (uint256) {
        IBasketToken token = IBasketToken(basket);
        uint256 count = token.assetCount();

        for (uint256 i; i < count; ++i) {
            (address asset,,) = token.assetAt(i);
            if (asset == communityToken) return IERC20(communityToken).balanceOf(basket);
        }

        revert CommunityTokenNotInBasket();
    }

    function _settleUser(ICommunity communityContract, address user, uint256 shareAcc) internal {
        uint256 accumulated = Math.mulDiv(_beneficiaryMiningAmount[user], shareAcc, ACC_PRECISION);
        uint256 debt = communityContract.getUserDebt(address(this), user);
        if (accumulated > debt) {
            communityContract.appendUserReward(user, accumulated - debt);
        }
    }
}
