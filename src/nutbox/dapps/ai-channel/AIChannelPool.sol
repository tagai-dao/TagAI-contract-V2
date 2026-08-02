// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../../ERC20Helper.sol";
import "../../interfaces/ICommittee.sol";
import "../../interfaces/ICommunity.sol";
import "../../interfaces/IPool.sol";
import "./AIChannelPoolFactory.sol";

/// @notice A virtual-stake Nutbox pool distributing AI Channel rewards by signed claim.
/// @dev Eligibility and allocation are deliberately off-chain policy concerns. Every
///      authorization commits to this pool's immutable channel and policy hashes.
contract AIChannelPool is IPool, ERC20Helper, ReentrancyGuard, Initializable, EIP712 {
    uint256 private constant VIRTUAL_STAKE = 1e18;
    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 chainId,address pool,bytes32 channelKey,bytes32 rewardPolicyHash,uint256 orderId,uint256 amount,address to,uint256 deadline)"
    );

    address public factory;
    address public community;
    bytes32 public channelKey;
    bytes32 public rewardPolicyHash;
    uint256 public totalClaimed;

    mapping(address user => mapping(uint256 orderId => bool claimed)) public claimedOrders;

    string public constant name = "AI Channel";

    event AIChannelRewardClaimed(
        address indexed user, uint256 indexed orderId, uint256 amount, bytes32 indexed channelKey, bool harvested
    );

    constructor() EIP712("Nutbox AIChannelPool", "1") {
        _disableInitializers();
    }

    function initialize(address _community, bytes32 _channelKey, bytes32 _rewardPolicyHash) external initializer {
        require(_community != address(0), "Invalid community");
        require(_channelKey != bytes32(0), "Invalid channel key");
        require(_rewardPolicyHash != bytes32(0), "Invalid reward policy");
        factory = msg.sender;
        community = _community;
        channelKey = _channelKey;
        rewardPolicyHash = _rewardPolicyHash;
    }

    function claim(uint256 orderId, uint256 amount, uint256 deadline, bytes calldata signature)
        external
        payable
        nonReentrant
    {
        require(block.timestamp <= deadline, "Expired");
        require(amount > 0, "Amount=0");
        require(!claimedOrders[msg.sender][orderId], "Claimed");

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                block.chainid,
                address(this),
                channelKey,
                rewardPolicyHash,
                orderId,
                amount,
                msg.sender,
                deadline
            )
        );
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(recovered == AIChannelPoolFactory(factory).claimSigner(), "Bad signature");

        address token = ICommunity(community).getCommunityToken();
        uint256 balance = IERC20(token).balanceOf(address(this));
        bool harvested;
        if (balance < amount) {
            ICommunity(community).withdrawPoolsRewards{value: msg.value}(_singlePoolArray());
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
            harvested = true;
        } else {
            _chargeTier3Fee();
        }

        claimedOrders[msg.sender][orderId] = true;
        totalClaimed += amount;
        releaseERC20(token, msg.sender, amount);
        _refundEthToCaller();

        emit AIChannelRewardClaimed(msg.sender, orderId, amount, channelKey, harvested);
    }

    function harvestRewards() external payable nonReentrant {
        ICommunity(community).withdrawPoolsRewards{value: msg.value}(_singlePoolArray());
        _refundEthToCaller();
    }

    function getFactory() external view override returns (address) {
        return factory;
    }

    function getCommunity() external view override returns (address) {
        return community;
    }

    function getUserStakedAmount(address user) external view override returns (uint256) {
        return user == address(this) ? VIRTUAL_STAKE : 0;
    }

    function getTotalStakedAmount() external pure override returns (uint256) {
        return VIRTUAL_STAKE;
    }

    function _singlePoolArray() private view returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = address(this);
    }

    function _chargeTier3Fee() private {
        address committee = ICommunity(community).getCommittee();
        uint256 fee = ICommittee(committee).getPoolOperationFee();
        if (fee == 0 || ICommittee(committee).getFeeFree(msg.sender)) return;
        require(msg.value >= fee, "Insufficient fee");
        (bool sent,) = ICommittee(committee).getFeeRecipient().call{value: fee}("");
        require(sent, "Fee transfer failed");
    }

    function _refundEthToCaller() private {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        (bool sent,) = payable(msg.sender).call{value: balance}("");
        require(sent, "Refund failed");
    }

    receive() external payable {}
}
