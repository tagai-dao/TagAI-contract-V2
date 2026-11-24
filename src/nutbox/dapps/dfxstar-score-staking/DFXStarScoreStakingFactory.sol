// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../interfaces/IPoolFactory.sol";
import "./DFXStarScoreStaking.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../CommunityFactory.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title DFXStarScoreStakingFactory
 * @dev Score staking pool factory. Each pool is bound to one game World at create time.
 *
 * createPool meta must be abi.encode(world). That World alone may call depositFromGame.
 * One World can only bind one pool (poolOfWorld).
 *
 * isAdmin on this factory is kept for owner bookkeeping; it no longer gates deposits.
 */
contract DFXStarScoreStakingFactory is IPoolFactory, Ownable2Step {
    address public immutable communityFactory;
    address public immutable poolTemplate;

    /// @dev Kept for compatibility; depositFromGame no longer checks this list.
    mapping(address => bool) public isAdmin;

    /// @dev One World can only have one score pool.
    mapping(address => address) public poolOfWorld;

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event DFXStarScoreStakingCreated(address indexed pool, address indexed community, string name);
    event WorldBound(address indexed world, address indexed pool);

    constructor(address _communityFactory) {
        require(_communityFactory != address(0), "Invalid address");
        communityFactory = _communityFactory;
        poolTemplate = address(new DFXStarScoreStaking());
    }

    function addAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Invalid address");
        require(!isAdmin[_admin], "Already admin");
        isAdmin[_admin] = true;
        emit AdminAdded(_admin);
    }

    function removeAdmin(address _admin) external onlyOwner {
        require(isAdmin[_admin], "Not admin");
        isAdmin[_admin] = false;
        emit AdminRemoved(_admin);
    }

    /**
     * @notice Create a pool bound to one World.
     * @param community Community address (must be msg.sender)
     * @param name Pool name
     * @param meta abi.encode(world); length must be 32
     */
    function createPool(address community, string memory name, bytes calldata meta) external override returns (address) {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        require(meta.length == 32, "World meta");
        address world = abi.decode(meta, (address));
        require(world != address(0), "Invalid world");
        require(poolOfWorld[world] == address(0), "World already bound");

        address clone = Clones.clone(poolTemplate);
        DFXStarScoreStaking pool = DFXStarScoreStaking(payable(clone));
        pool.initialize(community, world);
        poolOfWorld[world] = address(pool);

        emit DFXStarScoreStakingCreated(address(pool), community, name);
        emit WorldBound(world, address(pool));
        return address(pool);
    }
}
