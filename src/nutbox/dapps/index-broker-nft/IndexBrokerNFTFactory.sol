// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "./IndexBrokerNFTAMM.sol";
import "./IndexBrokerNFT.sol";

interface IOwnableCommunity {
    function owner() external view returns (address);
}

/**
 * @title IndexBrokerNFTFactory
 * @notice Creates fixed-supply, community-token-funded NFT mining pools.
 * @dev `meta` is `abi.encode(PoolConfig)`.
 */
contract IndexBrokerNFTFactory is IPoolFactory, Ownable2Step {
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 30;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct PoolConfig {
        string symbol;
        address fundsReceiver;
        address renderer;
        uint256[] levelThresholds;
        uint256[] levelWeights;
        uint256 communityTokenPrice;
        uint256 nativePrice;
        uint256 maxSupply;
        uint16 referralBps;
        uint16 ammNormalFeeBps;
        uint16 ammSpecificFeeBps;
        bool lockWhitelistSlots;
        address[] whitelistAccounts;
        uint256[] whitelistAllowances;
    }

    address public immutable communityFactory;
    address public immutable defaultRenderer;
    address public immutable poolTemplate;
    address public immutable ammTemplate;
    uint16 public platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;

    event PlatformFeeBpsChanged(uint16 previousBps, uint16 newBps);
    event IndexBrokerNFTAMMCreated(
        address indexed pool, address indexed ammVault, uint16 normalFeeBps, uint16 specificFeeBps
    );
    event IndexBrokerNFTCreated(
        address indexed pool,
        address indexed community,
        address indexed admin,
        address communityToken,
        address renderer,
        string name,
        string symbol,
        address fundsReceiver,
        uint256 communityTokenPrice,
        uint256 nativePrice,
        uint256 maxSupply,
        uint16 referralBps,
        bool lockWhitelistSlots,
        uint256 totalWhitelistAllocation
    );

    constructor(address communityFactory_, address defaultRenderer_, address ammTemplate_) {
        require(
            communityFactory_ != address(0) && defaultRenderer_.code.length > 0 && ammTemplate_.code.length > 0,
            "Invalid address"
        );
        communityFactory = communityFactory_;
        defaultRenderer = defaultRenderer_;
        poolTemplate = address(new IndexBrokerNFT());
        ammTemplate = ammTemplate_;
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
        address ammClone = Clones.clone(ammTemplate);
        IndexBrokerNFT pool = IndexBrokerNFT(payable(clone));
        pool.initialize(
            community,
            admin,
            selectedRenderer,
            ammClone,
            name,
            config.symbol,
            config.fundsReceiver,
            config.levelThresholds,
            config.levelWeights,
            config.communityTokenPrice,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            config.lockWhitelistSlots,
            config.whitelistAccounts,
            config.whitelistAllowances
        );
        IndexBrokerNFTAMM(payable(ammClone))
            .initialize(
                clone,
                pool.communityToken(),
                config.communityTokenPrice,
                config.ammNormalFeeBps,
                config.ammSpecificFeeBps
            );

        emit IndexBrokerNFTCreated(
            clone,
            community,
            admin,
            pool.communityToken(),
            selectedRenderer,
            name,
            config.symbol,
            config.fundsReceiver,
            config.communityTokenPrice,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            pool.lockWhitelistSlots(),
            pool.totalWhitelistAllocation()
        );
        emit IndexBrokerNFTAMMCreated(clone, ammClone, config.ammNormalFeeBps, config.ammSpecificFeeBps);
        return clone;
    }
}
