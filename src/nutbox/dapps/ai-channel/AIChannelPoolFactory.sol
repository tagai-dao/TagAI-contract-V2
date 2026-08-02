// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "./AIChannelPool.sol";

/// @notice Creates policy-bound reward pools for one TagAI AI Channel.
/// @dev `meta` is `abi.encode(bytes32 channelKey, bytes32 rewardPolicyHash)`.
///      The committed policy is evaluated off chain; this factory only creates
///      a pool whose signed claims are unambiguously bound to that commitment.
contract AIChannelPoolFactory is IPoolFactory, Ownable2Step {
    address public immutable communityFactory;
    address public immutable poolTemplate;
    address public claimSigner;

    mapping(address community => mapping(bytes32 channelKey => bool created)) public createdPoolOfChannel;

    event AIChannelPoolCreated(
        address indexed pool,
        address indexed community,
        bytes32 indexed channelKey,
        bytes32 rewardPolicyHash,
        string name
    );
    event ClaimSignerChanged(address indexed oldSigner, address indexed newSigner);

    constructor(address _communityFactory, address _claimSigner) {
        require(_communityFactory != address(0), "Invalid community factory");
        require(_claimSigner != address(0), "Invalid claim signer");
        communityFactory = _communityFactory;
        claimSigner = _claimSigner;
        poolTemplate = address(new AIChannelPool());
    }

    function adminSetClaimSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "Invalid claim signer");
        emit ClaimSignerChanged(claimSigner, newSigner);
        claimSigner = newSigner;
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        require(meta.length == 64, "Invalid meta length");

        (bytes32 channelKey, bytes32 rewardPolicyHash) = abi.decode(meta, (bytes32, bytes32));
        require(channelKey != bytes32(0), "Invalid channel key");
        require(rewardPolicyHash != bytes32(0), "Invalid reward policy");
        require(!createdPoolOfChannel[community][channelKey], "Channel pool already exists");

        address clone = Clones.clone(poolTemplate);
        AIChannelPool(payable(clone)).initialize(community, channelKey, rewardPolicyHash);
        createdPoolOfChannel[community][channelKey] = true;

        emit AIChannelPoolCreated(clone, community, channelKey, rewardPolicyHash, name);
        return clone;
    }
}
