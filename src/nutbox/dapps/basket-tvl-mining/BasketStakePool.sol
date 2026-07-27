// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../../interfaces/IBasketStakePool.sol";
import "../../../interfaces/IBasketToken.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/ICommunity.sol";

/**
 * @title BasketStakePool
 * @notice Child pool for locking one Basket ERC20 and sharing that Basket's parent-pool rewards.
 */
contract BasketStakePool is IBasketStakePool, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e24;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingReward;
        uint256 holderFeeDebt;
        uint256 pendingHolderFee;
    }

    struct RequestQueue {
        uint256 index;
        RedeemRequest[] queue;
    }

    address public parentMiningPool;
    address public community;
    address public stakeToken;
    address public rewardToken;
    address public holderFeeToken;
    address public nftMiningPool;
    uint256 public nftTokenId;
    uint16 public nftRewardBps;
    uint256 public lockDuration;

    uint256 public totalStakedAmount;
    uint256 public accRewardPerShare;
    uint256 public accHolderFeePerShare;
    uint256 public undistributedRewards;
    uint256 public accruedNftRewards;
    uint256 public undistributedHolderFees;
    uint256 public accountedHolderFeeBalance;
    bool public closedParentRewardsHarvested;

    mapping(address user => UserInfo info) private _users;
    mapping(address user => RequestQueue requests) private _requests;

    event Deposited(address indexed user, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 amount, uint256 startTime, uint256 endTime);
    event Redeemed(address indexed user, uint256 amount);
    event RewardsHarvested(uint256 amount);
    event NftRewardsAccrued(uint256 amount);
    event NftRewardsClaimed(uint256 indexed nftTokenId, address indexed recipient, uint256 amount);
    event ClosedParentRewardsHarvested(uint256 amount);
    event HolderFeesHarvested(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 communityAmount, uint256 holderFeeAmount);

    error InvalidAddress();
    error InvalidAmount();
    error PoolIsInactive();
    error NothingToRedeem();
    error NothingToClaim();
    error NativeTransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address parentMiningPool_,
        address community_,
        address stakeToken_,
        address nftMiningPool_,
        uint256 nftTokenId_,
        uint16 nftRewardBps_,
        uint256 lockDuration_
    ) external initializer {
        if (
            parentMiningPool_ == address(0) || community_ == address(0) || stakeToken_.code.length == 0
                || nftMiningPool_.code.length == 0 || nftRewardBps_ > BPS_DENOMINATOR || lockDuration_ == 0
        ) {
            revert InvalidAddress();
        }

        parentMiningPool = parentMiningPool_;
        community = community_;
        stakeToken = stakeToken_;
        nftMiningPool = nftMiningPool_;
        nftTokenId = nftTokenId_;
        nftRewardBps = nftRewardBps_;
        rewardToken = ICommunity(community_).getCommunityToken();
        holderFeeToken = IBasketToken(stakeToken_).weth();
        if (rewardToken == address(0) || holderFeeToken == address(0) || rewardToken == holderFeeToken) {
            revert InvalidAddress();
        }
        lockDuration = lockDuration_;
    }

    function deposit(uint256 amount) external payable override nonReentrant {
        if (!ICommunity(community).poolActived(parentMiningPool)) revert PoolIsInactive();
        if (amount == 0) revert InvalidAmount();

        _updateUser(msg.sender, msg.value);

        UserInfo storage user = _users[msg.sender];
        user.amount += amount;
        totalStakedAmount += amount;
        user.rewardDebt = Math.mulDiv(user.amount, accRewardPerShare, ACC_PRECISION);
        user.holderFeeDebt = Math.mulDiv(user.amount, accHolderFeePerShare, ACC_PRECISION);

        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external payable override nonReentrant {
        UserInfo storage user = _users[msg.sender];
        if (amount == 0 || amount > user.amount) revert InvalidAmount();

        _updateUser(msg.sender, msg.value);

        user.amount -= amount;
        totalStakedAmount -= amount;
        user.rewardDebt = Math.mulDiv(user.amount, accRewardPerShare, ACC_PRECISION);
        user.holderFeeDebt = Math.mulDiv(user.amount, accHolderFeePerShare, ACC_PRECISION);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + lockDuration;
        _requests[msg.sender].queue
            .push(RedeemRequest({tokenAmount: amount, claimed: 0, startTime: startTime, endTime: endTime}));

        emit WithdrawRequested(msg.sender, amount, startTime, endTime);
    }

    function redeem() external override nonReentrant {
        RequestQueue storage requests = _requests[msg.sender];
        uint256 available;
        uint256 length = requests.queue.length;

        for (uint256 i = requests.index; i < length; ++i) {
            RedeemRequest storage request = requests.queue[i];
            uint256 claimable = _claimableAmount(request);
            request.claimed += claimable;
            available += claimable;
            if (request.claimed == request.tokenAmount) requests.index = i + 1;
        }

        if (available == 0) revert NothingToRedeem();
        IERC20(stakeToken).safeTransfer(msg.sender, available);
        emit Redeemed(msg.sender, available);
    }

    function claimRewards()
        external
        payable
        override
        nonReentrant
        returns (uint256 communityAmount, uint256 holderFeeAmount)
    {
        _updateUser(msg.sender, msg.value);
        UserInfo storage user = _users[msg.sender];
        communityAmount = user.pendingReward;
        holderFeeAmount = user.pendingHolderFee;
        if (communityAmount == 0 && holderFeeAmount == 0) {
            revert NothingToClaim();
        }

        user.pendingReward = 0;
        user.pendingHolderFee = 0;
        if (communityAmount != 0) {
            IERC20(rewardToken).safeTransfer(msg.sender, communityAmount);
        }
        if (holderFeeAmount != 0) {
            accountedHolderFeeBalance -= holderFeeAmount;
            IERC20(holderFeeToken).safeTransfer(msg.sender, holderFeeAmount);
        }
        emit RewardsClaimed(msg.sender, communityAmount, holderFeeAmount);
    }

    /**
     * @notice Claims all Community-token rewards accrued to the NFT.
     * @dev Rewards are stored against the token id, not an address. Anyone may trigger
     * the claim, but payment always goes to the NFT's owner at execution time.
     */
    function claimNftRewards() external payable override nonReentrant returns (uint256 amount) {
        _harvestParentRewards(msg.value);
        amount = accruedNftRewards;
        if (amount == 0) revert NothingToClaim();

        address recipient = IERC721(nftMiningPool).ownerOf(nftTokenId);
        accruedNftRewards = 0;
        IERC20(rewardToken).safeTransfer(recipient, amount);
        emit NftRewardsClaimed(nftTokenId, recipient, amount);
    }

    function pendingRewards(address account) external view override returns (uint256) {
        UserInfo storage user = _users[account];
        uint256 projectedAcc = accRewardPerShare;
        uint256 pendingFromParent;
        if (!closedParentRewardsHarvested) {
            pendingFromParent = ICommunity(community).getPoolPendingRewards(parentMiningPool, address(this));
        }
        uint256 stakerShare = pendingFromParent - Math.mulDiv(pendingFromParent, nftRewardBps, BPS_DENOMINATOR);
        uint256 distributable = stakerShare + undistributedRewards;

        if (totalStakedAmount != 0 && distributable != 0) {
            projectedAcc += Math.mulDiv(distributable, ACC_PRECISION, totalStakedAmount);
        }

        uint256 accumulated = Math.mulDiv(user.amount, projectedAcc, ACC_PRECISION);
        uint256 newlyAccrued = accumulated > user.rewardDebt ? accumulated - user.rewardDebt : 0;
        return user.pendingReward + newlyAccrued;
    }

    function pendingNftRewards() external view override returns (uint256) {
        uint256 pendingFromParent;
        if (!closedParentRewardsHarvested) {
            pendingFromParent = ICommunity(community).getPoolPendingRewards(parentMiningPool, address(this));
        }
        return accruedNftRewards + Math.mulDiv(pendingFromParent, nftRewardBps, BPS_DENOMINATOR);
    }

    function pendingHolderFees(address account) external view override returns (uint256) {
        UserInfo storage user = _users[account];
        uint256 projectedAcc = accHolderFeePerShare;
        uint256 unaccountedBalance = IERC20(holderFeeToken).balanceOf(address(this)) - accountedHolderFeeBalance;
        uint256 claimableFromBasket = IBasketToken(stakeToken).claimableHolderFees(address(this));
        uint256 distributable = claimableFromBasket + unaccountedBalance + undistributedHolderFees;

        if (totalStakedAmount != 0 && distributable != 0) {
            projectedAcc += Math.mulDiv(distributable, ACC_PRECISION, totalStakedAmount);
        }

        uint256 accumulated = Math.mulDiv(user.amount, projectedAcc, ACC_PRECISION);
        uint256 newlyAccrued = accumulated > user.holderFeeDebt ? accumulated - user.holderFeeDebt : 0;
        return user.pendingHolderFee + newlyAccrued;
    }

    function getUserStakedAmount(address user) external view override returns (uint256) {
        return _users[user].amount;
    }

    function getTotalStakedAmount() external view override returns (uint256) {
        return totalStakedAmount;
    }

    function getUserInfo(address user) external view returns (UserInfo memory) {
        return _users[user];
    }

    function redeemRequestCount(address user) external view returns (uint256) {
        RequestQueue storage requests = _requests[user];
        return requests.queue.length - requests.index;
    }

    function redeemRequests(address user) external view returns (RedeemRequest[] memory result) {
        RequestQueue storage requests = _requests[user];
        uint256 count = requests.queue.length - requests.index;
        result = new RedeemRequest[](count);
        for (uint256 i; i < count; ++i) {
            result[i] = requests.queue[requests.index + i];
        }
    }

    function claimableAmount(address user) external view returns (uint256 amount) {
        RequestQueue storage requests = _requests[user];
        uint256 length = requests.queue.length;
        for (uint256 i = requests.index; i < length; ++i) {
            amount += _claimableAmount(requests.queue[i]);
        }
    }

    function _updateUser(address account, uint256 suppliedFee) internal {
        _harvestParentRewards(suppliedFee);
        _harvestHolderFees();

        UserInfo storage user = _users[account];
        uint256 accumulated = Math.mulDiv(user.amount, accRewardPerShare, ACC_PRECISION);
        if (accumulated > user.rewardDebt) user.pendingReward += accumulated - user.rewardDebt;
        user.rewardDebt = accumulated;

        uint256 accumulatedHolderFee = Math.mulDiv(user.amount, accHolderFeePerShare, ACC_PRECISION);
        if (accumulatedHolderFee > user.holderFeeDebt) {
            user.pendingHolderFee += accumulatedHolderFee - user.holderFeeDebt;
        }
        user.holderFeeDebt = accumulatedHolderFee;
    }

    function _harvestParentRewards(uint256 suppliedFee) internal {
        bool parentActive = ICommunity(community).poolActived(parentMiningPool);
        uint256 pendingFromParent;
        if (parentActive || !closedParentRewardsHarvested) {
            pendingFromParent = ICommunity(community).getPoolPendingRewards(parentMiningPool, address(this));
        }
        uint256 requiredFee = pendingFromParent == 0 ? 0 : _requiredOperationFee();
        if (suppliedFee < requiredFee) revert InvalidAmount();

        uint256 received;
        if (pendingFromParent != 0) {
            uint256 beforeBalance = IERC20(rewardToken).balanceOf(address(this));
            address[] memory pools = new address[](1);
            pools[0] = parentMiningPool;
            ICommunity(community).withdrawPoolsRewards{value: requiredFee}(pools);
            received = IERC20(rewardToken).balanceOf(address(this)) - beforeBalance;
        }
        if (!parentActive && !closedParentRewardsHarvested) {
            closedParentRewardsHarvested = true;
            emit ClosedParentRewardsHarvested(received);
        }

        uint256 nftAmount = Math.mulDiv(received, nftRewardBps, BPS_DENOMINATOR);
        if (nftAmount != 0) {
            accruedNftRewards += nftAmount;
            emit NftRewardsAccrued(nftAmount);
        }

        uint256 distributable = received - nftAmount + undistributedRewards;
        if (totalStakedAmount == 0) {
            undistributedRewards = distributable;
        } else if (distributable != 0) {
            uint256 accumulatorDelta = Math.mulDiv(distributable, ACC_PRECISION, totalStakedAmount);
            // Do not recycle per-update integer dust into the accumulator. User entitlement is
            // calculated from the cumulative accumulator, whose later fractional carry can
            // consume that dust. Recycling it here can therefore promise more than the token
            // balance by a few wei and make the final claimant revert.
            undistributedRewards = 0;
            accRewardPerShare += accumulatorDelta;
        }

        if (suppliedFee > requiredFee) {
            (bool success,) = msg.sender.call{value: suppliedFee - requiredFee}("");
            if (!success) revert NativeTransferFailed();
        }

        emit RewardsHarvested(received);
    }

    function _harvestHolderFees() internal {
        IBasketToken(stakeToken).claimHolderFeesFor(address(this));

        uint256 currentBalance = IERC20(holderFeeToken).balanceOf(address(this));
        uint256 received = currentBalance - accountedHolderFeeBalance;
        accountedHolderFeeBalance = currentBalance;

        uint256 distributable = received + undistributedHolderFees;
        if (totalStakedAmount == 0) {
            undistributedHolderFees = distributable;
        } else if (distributable != 0) {
            uint256 accumulatorDelta = Math.mulDiv(distributable, ACC_PRECISION, totalStakedAmount);
            // Keep accumulator rounding dust in the accounted WETH balance as a solvency
            // buffer instead of distributing the same residual again on the next interaction.
            undistributedHolderFees = 0;
            accHolderFeePerShare += accumulatorDelta;
        }

        emit HolderFeesHarvested(received);
    }

    function _requiredOperationFee() internal view returns (uint256) {
        address committee = ICommunity(community).getCommittee();
        if (ICommittee(committee).getFeeFree(address(this))) return 0;
        return ICommittee(committee).getPoolOperationFee();
    }

    function _claimableAmount(RedeemRequest storage request) internal view returns (uint256) {
        if (block.timestamp >= request.endTime) return request.tokenAmount - request.claimed;
        return Math.mulDiv(
            request.tokenAmount, block.timestamp - request.startTime, request.endTime - request.startTime
        ) - request.claimed;
    }
}
