// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../interfaces/IPoolFactory.sol";
import "./DFXStarScoreStaking.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../CommunityFactory.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title DFXStarScoreStakingFactory
 * @dev Score staking pool factory contract
 *
 * Admin permissions:
 * - owner: Factory owner, can add/remove admins
 * - admins: Addresses that can call depositFromGame to increase user's staked score
 *
 * Admins are configured by community admin through owner
 *
 * Note: A community can create multiple pools
 */
contract DFXStarScoreStakingFactory is IPoolFactory, Ownable2Step {
    address public immutable communityFactory;
    address public immutable poolTemplate;
    
    /// @dev Admin list (can call depositFromGame)
    mapping(address => bool) public isAdmin;
    
    // Events
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event DFXStarScoreStakingCreated(
        address indexed pool,
        address indexed community,
        string name
    );
    
    constructor(address _communityFactory) {
        require(_communityFactory != address(0), "Invalid address");
        communityFactory = _communityFactory;
        poolTemplate = address(new DFXStarScoreStaking());
    }
    
    /**
     * @notice Add admin
     * @dev Only owner can call
     * @param _admin Admin address
     */
    function addAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Invalid address");
        require(!isAdmin[_admin], "Already admin");
        isAdmin[_admin] = true;
        emit AdminAdded(_admin);
    }
    
    /**
     * @notice Remove admin
     * @dev Only owner can call
     * @param _admin Admin address
     */
    function removeAdmin(address _admin) external onlyOwner {
        require(isAdmin[_admin], "Not admin");
        isAdmin[_admin] = false;
        emit AdminRemoved(_admin);
    }
    
    /**
     * @notice Create pool
     * @dev Only callable by Community contract, a community can create multiple pools
     * @param community Community address
     * @param name Pool name
     */
    function createPool(
        address community,
        string memory name,
        bytes calldata /* meta */
    ) external override returns (address) {
        require(community == msg.sender, 'Permission denied: caller is not community');
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        
        address clone = Clones.clone(poolTemplate);
        DFXStarScoreStaking pool = DFXStarScoreStaking(payable(clone));
        pool.initialize(community);
        
        emit DFXStarScoreStakingCreated(address(pool), community, name);
        
        return address(pool);
    }
}
