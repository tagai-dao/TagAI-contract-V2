// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "./NFTMiningPool.sol";
import "./NFTMiningRenderer.sol";

interface IOwnableCommunity {
    function owner() external view returns (address);
}

/**
 * @title NFTMiningPoolFactory
 * @notice Creates clone-based NFT mining pools for verified Nutbox communities.
 *
 * `meta` is `abi.encode(PoolConfig)`.
 */
contract NFTMiningPoolFactory is IPoolFactory, Ownable2Step {
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 30;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct PoolConfig {
        string symbol;
        address fundsReceiver;
        address renderer;
        uint256[] levelThresholds;
        uint256[] levelWeights;
        address firstPaymentAsset;
        uint256 firstMintPrice;
        uint256 firstBatchSupply;
        uint16 firstReferralBps;
    }

    address public immutable communityFactory;
    address public immutable defaultRenderer;
    address public immutable poolTemplate;
    uint16 public platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;

    event PlatformFeeBpsChanged(uint16 previousBps, uint16 newBps);
    event NFTMiningPoolCreated(
        address indexed pool,
        address indexed community,
        address indexed admin,
        address renderer,
        string name,
        string symbol,
        address paymentAsset,
        uint256 mintPrice,
        uint256 firstBatchSupply,
        uint16 referralBps,
        uint8 paletteId
    );

    constructor(address communityFactory_) {
        require(communityFactory_ != address(0), "Invalid address");
        communityFactory = communityFactory_;
        defaultRenderer = address(new NFTMiningRenderer());
        poolTemplate = address(new NFTMiningPool());
    }

    function setPlatformFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= BPS_DENOMINATOR, "Invalid platform fee");
        uint16 previousBps = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsChanged(previousBps, newBps);
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");

        PoolConfig memory config = abi.decode(meta, (PoolConfig));
        address admin = IOwnableCommunity(community).owner();
        address selectedRenderer = config.renderer == address(0) ? defaultRenderer : config.renderer;

        address clone = Clones.clone(poolTemplate);
        NFTMiningPool pool = NFTMiningPool(payable(clone));
        pool.initialize(
            community,
            admin,
            selectedRenderer,
            name,
            config.symbol,
            config.fundsReceiver,
            config.levelThresholds,
            config.levelWeights,
            config.firstPaymentAsset,
            config.firstMintPrice,
            config.firstBatchSupply,
            config.firstReferralBps
        );

        emit NFTMiningPoolCreated(
            clone,
            community,
            admin,
            selectedRenderer,
            name,
            config.symbol,
            config.firstPaymentAsset,
            config.firstMintPrice,
            config.firstBatchSupply,
            config.firstReferralBps,
            1
        );
        return clone;
    }
}
