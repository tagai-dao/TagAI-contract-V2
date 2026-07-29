// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../../interfaces/ICommunity.sol";
import "../../../interfaces/IPool.sol";
import "../../interfaces/IPoolFactory.sol";
import "./BasketStakePool.sol";
import "./BasketTVLMiningPool.sol";

/**
 * @title BasketTVLMiningPoolFactory
 * @notice Creates one shared Basket TVL mining pool for each verified Nutbox community.
 * @dev `meta` is `abi.encode(nftMiningPool, nftRewardBps, lockDuration)`. The NFT pool must
 * be active in the Community and originate from the configured NFT pool factory.
 */
contract BasketTVLMiningPoolFactory is IPoolFactory {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public immutable communityFactory;
    address public immutable basketRegistry;
    address public immutable nftMiningPoolFactory;
    address public immutable poolTemplate;
    address public immutable childPoolTemplate;

    mapping(address community => address pool) public poolOfCommunity;

    event BasketTVLMiningPoolCreated(
        address indexed pool,
        address indexed community,
        address indexed basketRegistry,
        address nftMiningPool,
        uint16 nftRewardBps,
        uint256 lockDuration,
        string name
    );

    error InvalidAddress();
    error NftMiningPoolIsNotActive();
    error InvalidNftMiningPoolFactory();
    error InvalidNftRewardBps();
    error InvalidLockDuration();
    error PoolAlreadyExists();

    constructor(address communityFactory_, address basketRegistry_, address nftMiningPoolFactory_) {
        if (
            communityFactory_ == address(0) || basketRegistry_.code.length == 0
                || nftMiningPoolFactory_.code.length == 0
        ) {
            revert InvalidAddress();
        }

        communityFactory = communityFactory_;
        basketRegistry = basketRegistry_;
        nftMiningPoolFactory = nftMiningPoolFactory_;
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

        (address nftMiningPool, uint16 nftRewardBps, uint256 lockDuration) =
            abi.decode(meta, (address, uint16, uint256));
        if (!ICommunity(community).poolActived(nftMiningPool)) revert NftMiningPoolIsNotActive();
        try IPool(nftMiningPool).getFactory() returns (address nftFactory) {
            if (nftFactory != nftMiningPoolFactory) revert InvalidNftMiningPoolFactory();
        } catch {
            revert InvalidNftMiningPoolFactory();
        }
        if (nftRewardBps > BPS_DENOMINATOR) revert InvalidNftRewardBps();
        if (lockDuration == 0) revert InvalidLockDuration();

        address clone = Clones.clone(poolTemplate);
        BasketTVLMiningPool(clone)
            .initialize(community, name, basketRegistry, nftMiningPool, childPoolTemplate, lockDuration, nftRewardBps);
        poolOfCommunity[community] = clone;

        emit BasketTVLMiningPoolCreated(
            clone, community, basketRegistry, nftMiningPool, nftRewardBps, lockDuration, name
        );
        return clone;
    }
}
