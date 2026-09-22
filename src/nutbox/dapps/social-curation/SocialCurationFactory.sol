// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../interfaces/IPoolFactory.sol";
import "./SocialCuration.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../CommunityFactory.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @dev Factory for Nutbox social-curation pools.
 *      Deploys one SocialCuration EIP-1167 clone per community.
 *      Clones share the factory owner's `claimSigner`; users claim with EIP-712 signatures.
 *      This is not a staking or locking pool. `createPool` does not decode `meta`.
 */
contract SocialCurationFactory is IPoolFactory, Ownable2Step {
    address public immutable communityFactory;
    address public immutable poolTemplate;
    address public claimSigner;
    mapping(address => bool) public createdPoolOfCommunity;

    constructor(address _communityFactory, address _claimSigner) {
        require(_communityFactory != address(0), "Invalid address");
        communityFactory = _communityFactory;
        poolTemplate = address(new SocialCuration());
        claimSigner = _claimSigner;
    }

    event SocialCurationCreated(address indexed pool, address indexed community, string name);

    function adminSetClaimSigner(address _claimSigner) external onlyOwner {
        require(_claimSigner != address(0), "Invalid address");
        claimSigner = _claimSigner;
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        require(!createdPoolOfCommunity[community], "Community already has this pool");

        address clone = Clones.clone(poolTemplate);
        SocialCuration pool = SocialCuration(payable(clone));
        pool.initialize(community);
        emit SocialCurationCreated(address(pool), community, name);
        createdPoolOfCommunity[community] = true;
        return address(pool);
    }
}
