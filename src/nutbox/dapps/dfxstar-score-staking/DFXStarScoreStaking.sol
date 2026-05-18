// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../ERC20Helper.sol";
import "../../interfaces/IPool.sol";
import "../../interfaces/ICommunity.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/IDFXStarScoreStaking.sol";
import "./DFXStarScoreStakingFactory.sol";

/**
 * @title DFXStarScoreStaking
 * @dev Score staking pool contract
 *
 * Features:
 * 1. Only admin can increase user's staked score (depositFromGame)
 * 2. Anyone can inject community tokens as rewards, distributed proportionally to all stakers
 * 3. Community rewards: users claim from Community contract (same as SPStaking logic)
 * 4. External rewards: users claim injected rewards from this contract
 */
contract DFXStarScoreStaking is IPool, IDFXStarScoreStaking, ERC20Helper, ReentrancyGuard, Initializable {
    
    uint256 private constant PRECISION = 1e12;
    
    address public factory;
    address public community;
    
    /// @dev User's staked score amount
    mapping(address => uint256) private userStakes;
    
    /// @dev Total staked amount
    uint256 private totalStaked;
    
    /// @dev Accumulated external rewards per share
    uint256 private externalAccPerShare;
    
    /// @dev User's external reward debt
    mapping(address => uint256) private userExternalDebt;
    
    /// @dev User's pending external rewards
    mapping(address => uint256) private userExternalRewards;
    
    string public constant name = "DFXStar Score Staking";
    
    // Events
    event Deposited(address indexed user, uint256 amount, address indexed admin);
    event InjectedRewards(address indexed injector, uint256 amount, uint256 totalStaked);
    event ClaimedExternalRewards(address indexed user, uint256 amount);
    
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _community) external initializer {
        require(_community != address(0), "Invalid community");
        factory = msg.sender;
        community = _community;
    }
    
    /**
     * @notice Admin increases user's staked score
     * @dev Only admin configured in factory can call, no fee charged
     * @param user User address
     * @param amount Score amount
     */
    function depositFromGame(address user, uint256 amount) external payable override nonReentrant {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Amount=0");
        require(DFXStarScoreStakingFactory(factory).isAdmin(msg.sender), "Not admin");
        
        // No fee charged - platform will add admin to fee-free list
        
        // Update external rewards state
        _updateExternalRewards(user);
        
        // Increase stake
        userStakes[user] += amount;
        totalStaked += amount;
        
        // Update user's external reward debt
        userExternalDebt[user] = (userStakes[user] * externalAccPerShare) / PRECISION;
        
        // Sync Community rewards state
        ICommunity(community).updatePools();
        
        // Update user's debt in Community
        uint256 communityShareAcc = ICommunity(community).getShareAcc(address(this));
        ICommunity(community).setUserDebt(user, (userStakes[user] * communityShareAcc) / PRECISION);
        
        _refundEthToUser();
        
        emit Deposited(user, amount, msg.sender);
    }
    
    /**
     * @notice Inject community tokens as rewards
     * @dev Anyone can call, rewards are distributed proportionally to all stakers
     * @param amount Token amount to inject
     */
    function injectRewards(uint256 amount) external payable override nonReentrant {
        require(amount > 0, "Amount=0");
        require(totalStaked > 0, "No stakers");
        
        address token = ICommunity(community).getCommunityToken();
        
        // Charge Tier3 fee
        _chargeTier3Fee();
        
        // Transfer tokens from caller
        lockERC20(token, msg.sender, address(this), amount);
        
        // Update accumulated rewards per share
        externalAccPerShare += (amount * PRECISION) / totalStaked;
        
        _refundEthToUser();
        
        emit InjectedRewards(msg.sender, amount, totalStaked);
    }
    
    /**
     * @notice User claims external rewards (injected community tokens)
     * @dev For Community rewards, user should claim from Community contract
     */
    function claimExternalRewards() external payable override nonReentrant {
        _chargeTier3Fee();
        
        _updateExternalRewards(msg.sender);
        
        uint256 pending = userExternalRewards[msg.sender];
        require(pending > 0, "No rewards");
        
        userExternalRewards[msg.sender] = 0;
        
        address token = ICommunity(community).getCommunityToken();
        releaseERC20(token, msg.sender, pending);
        
        _refundEthToUser();
        
        emit ClaimedExternalRewards(msg.sender, pending);
    }
    
    /**
     * @notice Get user's pending external rewards
     */
    function getPendingExternalRewards(address user) public view override returns (uint256) {
        uint256 stake = userStakes[user];
        if (stake == 0) return userExternalRewards[user];
        
        uint256 pending = (stake * externalAccPerShare) / PRECISION - userExternalDebt[user];
        return userExternalRewards[user] + pending;
    }
    
    /**
     * @notice Get user's pending Community rewards
     * @dev User should claim from Community contract
     */
    function getPendingCommunityRewards(address user) public view override returns (uint256) {
        return ICommunity(community).getPoolPendingRewards(address(this), user);
    }
    
    /**
     * @notice Get all user's pending rewards
     */
    function getPendingAllRewards(address user) external view override returns (uint256 communityPending, uint256 externalPending) {
        communityPending = getPendingCommunityRewards(user);
        externalPending = getPendingExternalRewards(user);
    }
    
    /**
     * @notice Get user's staked amount
     */
    function getUserStakedAmount(address user) external view override returns (uint256) {
        return userStakes[user];
    }
    
    /**
     * @notice Get total staked amount
     */
    function getTotalStakedAmount() external view override returns (uint256) {
        return totalStaked;
    }
    
    function getFactory() external view override returns (address) {
        return factory;
    }
    
    function getCommunity() external view override returns (address) {
        return community;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Update user's external rewards state
     */
    function _updateExternalRewards(address user) internal {
        uint256 stake = userStakes[user];
        if (stake > 0) {
            uint256 pending = (stake * externalAccPerShare) / PRECISION - userExternalDebt[user];
            if (pending > 0) {
                userExternalRewards[user] += pending;
            }
        }
        userExternalDebt[user] = (stake * externalAccPerShare) / PRECISION;
    }
    
    /**
     * @dev Charge Tier3 fee
     */
    function _chargeTier3Fee() internal {
        address committeeAddr = ICommunity(community).getCommittee();
        uint256 fee = ICommittee(committeeAddr).getPoolOperationFee();
        if (fee == 0) return;
        if (ICommittee(committeeAddr).getFeeFree(msg.sender)) return;
        require(msg.value >= fee, "Insufficient fee");
        address payable recipient = ICommittee(committeeAddr).getFeeRecipient();
        (bool ok, ) = recipient.call{value: fee}("");
        require(ok, "Fee transfer failed");
    }
    
    /**
     * @dev Refund excess ETH to caller
     */
    function _refundEthToUser() internal {
        uint256 ethBal = address(this).balance;
        if (ethBal == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: ethBal}("");
        require(ok, "ETH refund failed");
    }
    
    receive() external payable {}
}
