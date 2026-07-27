// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../../interfaces/IBasketRebalanceExecutor.sol";
import "../../../interfaces/IBasketRegistry.sol";
import "../../../interfaces/IBasketTVLMiningPool.sol";
import "../../../interfaces/IBasketToken.sol";
import "../../interfaces/ICommunity.sol";
import "./BasketStakePool.sol";

/**
 * @title BasketTVLMiningPool
 * @notice A shared Nutbox pool where registered Basket tokens mine according to their WETH-denominated NAV.
 *
 * Basket assets are not transferred into this contract. Each Basket's mining amount is derived from its
 * on-chain active reserves and recorded for its child staking pool. Anyone may register an eligible Basket
 * or refresh an existing Basket's mining amount.
 */
contract BasketTVLMiningPool is IBasketTVLMiningPool, Initializable, ReentrancyGuard {
    uint256 public constant ACC_PRECISION = 1e12;

    address public factory;
    address public community;
    address public basketRegistry;
    address public nftMiningPool;
    address public childPoolTemplate;
    uint256 public lockDuration;
    string public name;

    mapping(address basket => BasketStake stake) private _basketStakes;
    mapping(address beneficiary => uint256 amount) private _beneficiaryMiningAmount;
    uint256 private _totalMiningAmount;

    event BasketStakeCreated(address indexed basket, address indexed owner, uint256 miningAmount, uint256 updatedAt);
    event BasketChildPoolCreated(
        address indexed basket, address indexed childPool, address indexed owner, uint256 lockDuration
    );
    event BasketStakeUpdated(
        address indexed basket,
        address indexed owner,
        uint256 previousMiningAmount,
        uint256 newMiningAmount,
        uint256 updatedAt
    );

    error InvalidAddress();
    error InvalidBasket();
    error BasketStakeAlreadyExists();
    error BasketStakeNotFound();
    error OwnerHasNoMiningNFT();
    error PoolIsInactive();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address community_,
        string calldata name_,
        address basketRegistry_,
        address nftMiningPool_,
        address childPoolTemplate_,
        uint256 lockDuration_
    ) external initializer {
        if (
            community_ == address(0) || basketRegistry_.code.length == 0 || nftMiningPool_.code.length == 0
                || childPoolTemplate_.code.length == 0 || lockDuration_ == 0
        ) {
            revert InvalidAddress();
        }

        factory = msg.sender;
        community = community_;
        name = name_;
        basketRegistry = basketRegistry_;
        nftMiningPool = nftMiningPool_;
        childPoolTemplate = childPoolTemplate_;
        lockDuration = lockDuration_;
    }

    /**
     * @notice Registers a Basket, creates its child pool, and attributes WETH NAV to that child pool.
     * @dev Permissionless. The Basket creator must own at least one NFT from the configured NFT mining pool.
     */
    function createBasketStake(address basket) external override nonReentrant returns (address childPool) {
        if (!ICommunity(community).poolActived(address(this))) revert PoolIsInactive();
        if (!IBasketRegistry(basketRegistry).isBasket(basket)) revert InvalidBasket();
        if (_basketStakes[basket].exists) revert BasketStakeAlreadyExists();

        address basketOwner = IBasketToken(basket).creatorPayout();
        if (basketOwner == address(0)) revert InvalidAddress();
        if (IERC721(nftMiningPool).balanceOf(basketOwner) == 0) revert OwnerHasNoMiningNFT();

        childPool = Clones.clone(childPoolTemplate);
        BasketStakePool(childPool).initialize(address(this), community, basket, lockDuration);

        uint256 miningAmount = _basketNavWeth(basket);
        ICommunity communityContract = ICommunity(community);
        communityContract.updatePools();
        uint256 shareAcc = communityContract.getShareAcc(address(this));
        _settleUser(communityContract, childPool, shareAcc);

        _basketStakes[basket] = BasketStake({
            owner: basketOwner,
            childPool: childPool,
            miningAmount: miningAmount,
            updatedAt: block.timestamp,
            exists: true
        });
        _beneficiaryMiningAmount[childPool] += miningAmount;
        _totalMiningAmount += miningAmount;

        communityContract.setUserDebt(
            childPool, Math.mulDiv(_beneficiaryMiningAmount[childPool], shareAcc, ACC_PRECISION)
        );

        emit BasketStakeCreated(basket, basketOwner, miningAmount, block.timestamp);
        emit BasketChildPoolCreated(basket, childPool, basketOwner, lockDuration);
    }

    /**
     * @notice Refreshes a registered Basket's mining amount from its current WETH NAV.
     * @dev Permissionless. The caller cannot supply or influence the recorded amount directly.
     */
    function updateBasketStake(address basket) external override nonReentrant {
        BasketStake storage stake = _basketStakes[basket];
        if (!stake.exists) revert BasketStakeNotFound();

        uint256 newMiningAmount = _basketNavWeth(basket);
        uint256 previousMiningAmount = stake.miningAmount;
        address basketOwner = stake.owner;
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

        emit BasketStakeUpdated(basket, basketOwner, previousMiningAmount, newMiningAmount, block.timestamp);
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

    function basketNavWeth(address basket) external view override returns (uint256) {
        if (!IBasketRegistry(basketRegistry).isBasket(basket)) revert InvalidBasket();
        return _basketNavWeth(basket);
    }

    function _basketNavWeth(address basket) internal view returns (uint256 navWeth) {
        IBasketToken token = IBasketToken(basket);
        IBasketRebalanceExecutor executor = IBasketRebalanceExecutor(token.rebalanceExecutor());
        uint256 count = token.assetCount();

        for (uint256 i; i < count; ++i) {
            (address asset,, uint256 activeReserve) = token.assetAt(i);
            navWeth += executor.quoteAssetToWeth(token.assetRouteAt(i), asset, activeReserve);
        }
    }

    function _settleUser(ICommunity communityContract, address user, uint256 shareAcc) internal {
        uint256 accumulated = Math.mulDiv(_beneficiaryMiningAmount[user], shareAcc, ACC_PRECISION);
        uint256 debt = communityContract.getUserDebt(address(this), user);
        if (accumulated > debt) {
            communityContract.appendUserReward(user, accumulated - debt);
        }
    }
}
