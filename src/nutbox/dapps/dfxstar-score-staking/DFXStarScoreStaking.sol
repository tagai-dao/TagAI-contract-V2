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
 * @dev Score staking pool bound to one game World at initialize time.
 *
 * Features:
 * 1. Only the bound World can increase a user's staked score (depositFromGame)
 * 2. Anyone can inject community tokens as rewards, distributed proportionally
 * 3. Community rewards: users claim from Community contract
 * 4. External rewards: users claim injected rewards from this contract
 */
contract DFXStarScoreStaking is IPool, IDFXStarScoreStaking, ERC20Helper, ReentrancyGuard, Initializable {
    uint256 private constant PRECISION = 1e12;

    address public factory;
    address public community;
    // Set once at create time; initialize cannot run again.
    address public override world;

    mapping(address => uint256) private userStakes;
    uint256 private totalStaked;
    uint256 private externalAccPerShare;
    mapping(address => uint256) private userExternalDebt;
    mapping(address => uint256) private userExternalRewards;

    string public constant name = "DFXStar Score Staking";

    event Deposited(address indexed user, uint256 amount, address indexed admin);
    event InjectedRewards(address indexed injector, uint256 amount, uint256 totalStaked);
    event ClaimedExternalRewards(address indexed user, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address _community, address _world) external initializer {
        require(_community != address(0), "Invalid community");
        require(_world != address(0), "Invalid world");
        factory = msg.sender;
        community = _community;
        world = _world;
    }

    /**
     * @notice World increases user's staked score
     * @dev Only the World bound at create time may call; no fee charged
     */
    function depositFromGame(address user, uint256 amount) external payable override nonReentrant {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Amount=0");
        // Factory admin list no longer gates deposits.
        require(msg.sender == world, "Not world");

        _updateExternalRewards(user);

        userStakes[user] += amount;
        totalStaked += amount;

        userExternalDebt[user] = (userStakes[user] * externalAccPerShare) / PRECISION;

        ICommunity(community).updatePools();

        uint256 communityShareAcc = ICommunity(community).getShareAcc(address(this));
        ICommunity(community).setUserDebt(user, (userStakes[user] * communityShareAcc) / PRECISION);

        _refundEthToUser();

        emit Deposited(user, amount, msg.sender);
    }

    function injectRewards(uint256 amount) external payable override nonReentrant {
        require(amount > 0, "Amount=0");
        require(totalStaked > 0, "No stakers");

        address token = ICommunity(community).getCommunityToken();

        _chargeTier3Fee();

        lockERC20(token, msg.sender, address(this), amount);

        externalAccPerShare += (amount * PRECISION) / totalStaked;

        _refundEthToUser();

        emit InjectedRewards(msg.sender, amount, totalStaked);
    }

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

    function getPendingExternalRewards(address user) public view override returns (uint256) {
        uint256 stake = userStakes[user];
        if (stake == 0) return userExternalRewards[user];

        uint256 pending = (stake * externalAccPerShare) / PRECISION - userExternalDebt[user];
        return userExternalRewards[user] + pending;
    }

    function getPendingCommunityRewards(address user) public view override returns (uint256) {
        return ICommunity(community).getPoolPendingRewards(address(this), user);
    }

    function getPendingAllRewards(address user)
        external
        view
        override
        returns (uint256 communityPending, uint256 externalPending)
    {
        communityPending = getPendingCommunityRewards(user);
        externalPending = getPendingExternalRewards(user);
    }

    function getUserStakedAmount(address user) external view override returns (uint256) {
        return userStakes[user];
    }

    function getTotalStakedAmount() external view override returns (uint256) {
        return totalStaked;
    }

    function getFactory() external view override returns (address) {
        return factory;
    }

    function getCommunity() external view override returns (address) {
        return community;
    }

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

    function _chargeTier3Fee() internal {
        address committeeAddr = ICommunity(community).getCommittee();
        uint256 fee = ICommittee(committeeAddr).getPoolOperationFee();
        if (fee == 0) return;
        if (ICommittee(committeeAddr).getFeeFree(msg.sender)) return;
        require(msg.value >= fee, "Insufficient fee");
        address payable recipient = ICommittee(committeeAddr).getFeeRecipient();
        (bool ok,) = recipient.call{value: fee}("");
        require(ok, "Fee transfer failed");
    }

    function _refundEthToUser() internal {
        uint256 ethBal = address(this).balance;
        if (ethBal == 0) return;
        (bool ok,) = payable(msg.sender).call{value: ethBal}("");
        require(ok, "ETH refund failed");
    }

    receive() external payable {}
}
