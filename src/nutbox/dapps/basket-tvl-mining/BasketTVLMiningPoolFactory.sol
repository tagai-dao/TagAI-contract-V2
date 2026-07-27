// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "./BasketStakePool.sol";
import "./BasketTVLMiningPool.sol";

/**
 * @title BasketTVLMiningPoolFactory
 * @notice Creates one shared Basket TVL mining pool for each verified Nutbox community.
 */
contract BasketTVLMiningPoolFactory is IPoolFactory {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public immutable communityFactory;
    address public immutable basketRegistry;
    address public immutable nftMiningPool;
    address public immutable poolTemplate;
    address public immutable childPoolTemplate;
    uint256 public immutable lockDuration;

    mapping(address community => address pool) public poolOfCommunity;

    event BasketTVLMiningPoolCreated(
        address indexed pool,
        address indexed community,
        address indexed basketRegistry,
        address nftMiningPool,
        uint16 nftRewardBps,
        string name
    );

    error InvalidAddress();
    error InvalidNftRewardBps();
    error PoolAlreadyExists();

    constructor(address communityFactory_, address basketRegistry_, address nftMiningPool_, uint256 lockDuration_) {
        if (
            communityFactory_ == address(0) || basketRegistry_.code.length == 0 || nftMiningPool_.code.length == 0
                || lockDuration_ == 0
        ) {
            revert InvalidAddress();
        }

        communityFactory = communityFactory_;
        basketRegistry = basketRegistry_;
        nftMiningPool = nftMiningPool_;
        lockDuration = lockDuration_;
        poolTemplate = address(new BasketTVLMiningPool());
        childPoolTemplate = address(new BasketStakePool());
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        if (poolOfCommunity[community] != address(0)) revert PoolAlreadyExists();

        uint16 nftRewardBps = abi.decode(meta, (uint16));
        if (nftRewardBps > BPS_DENOMINATOR) revert InvalidNftRewardBps();

        address clone = Clones.clone(poolTemplate);
        BasketTVLMiningPool(clone)
            .initialize(community, name, basketRegistry, nftMiningPool, childPoolTemplate, lockDuration, nftRewardBps);
        poolOfCommunity[community] = clone;

        emit BasketTVLMiningPoolCreated(clone, community, basketRegistry, nftMiningPool, nftRewardBps, name);
        return clone;
    }
}
