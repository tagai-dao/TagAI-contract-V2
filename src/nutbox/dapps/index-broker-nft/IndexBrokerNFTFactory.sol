// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "./IIndexBrokerNFTPriceOracle.sol";
import "./IndexBrokerNFTAMM.sol";
import "./IndexBrokerNFT.sol";

interface IOwnableCommunity {
    function owner() external view returns (address);
}

interface IIndexBrokerFactoryBasketRegistry {
    function isBasket(address candidate) external view returns (bool);
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
        uint256 indexMiningActivationTokenAmount;
        uint256 nativePrice;
        uint256 maxSupply;
        uint16 referralBps;
        bytes ammConfig;
        bool lockWhitelistSlots;
        address[] whitelistAccounts;
        uint256[] whitelistAllowances;
    }

    struct AMMConfig {
        uint16 normalFeeBps;
        uint16 specificFeeBps;
        IIndexBrokerNFTPriceOracle.SourceType priceSourceType;
        bytes priceSourceData;
        address indexToken;
    }

    address public immutable communityFactory;
    address public immutable defaultRenderer;
    address public immutable poolTemplate;
    address public immutable ammTemplate;
    address public immutable priceOracle;
    address public immutable basketRegistry;
    address public immutable basketSwapRouter;
    address public immutable indexV3Router;
    uint24 public immutable indexV3Fee;
    address public defaultIndexToken;
    uint16 public platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;

    event PlatformFeeBpsChanged(uint16 previousBps, uint16 newBps);
    event DefaultIndexTokenChanged(address indexed previousToken, address indexed newToken);
    event IndexBrokerNFTAMMCreated(
        address indexed pool,
        address indexed ammVault,
        address priceOracle,
        IIndexBrokerNFTPriceOracle.SourceType priceSourceType,
        uint16 normalFeeBps,
        uint16 specificFeeBps,
        address indexToken
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
        uint256 indexMiningActivationTokenAmount,
        uint256 nativePrice,
        uint256 maxSupply,
        uint16 referralBps,
        bool lockWhitelistSlots,
        uint256 totalWhitelistAllocation
    );

    constructor(
        address communityFactory_,
        address defaultRenderer_,
        address ammTemplate_,
        address priceOracle_,
        address basketRegistry_,
        address basketSwapRouter_,
        address indexV3Router_,
        uint24 indexV3Fee_,
        address defaultIndexToken_
    ) {
        require(
            communityFactory_ != address(0) && defaultRenderer_.code.length > 0 && ammTemplate_.code.length > 0
                && priceOracle_.code.length > 0 && basketRegistry_.code.length > 0 && basketSwapRouter_.code.length > 0
                && indexV3Router_.code.length > 0,
            "Invalid address"
        );
        require(IIndexBrokerFactoryBasketRegistry(basketRegistry_).isBasket(defaultIndexToken_), "Invalid index token");
        communityFactory = communityFactory_;
        defaultRenderer = defaultRenderer_;
        poolTemplate = address(new IndexBrokerNFT());
        ammTemplate = ammTemplate_;
        priceOracle = priceOracle_;
        basketRegistry = basketRegistry_;
        basketSwapRouter = basketSwapRouter_;
        indexV3Router = indexV3Router_;
        indexV3Fee = indexV3Fee_;
        defaultIndexToken = defaultIndexToken_;
    }

    function setPlatformFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= BPS_DENOMINATOR, "Invalid platform fee");
        uint16 previousBps = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsChanged(previousBps, newBps);
    }

    function setDefaultIndexToken(address newToken) external onlyOwner {
        require(IIndexBrokerFactoryBasketRegistry(basketRegistry).isBasket(newToken), "Invalid index token");
        address previousToken = defaultIndexToken;
        defaultIndexToken = newToken;
        emit DefaultIndexTokenChanged(previousToken, newToken);
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");

        PoolConfig memory config = abi.decode(meta, (PoolConfig));
        AMMConfig memory ammConfig = abi.decode(config.ammConfig, (AMMConfig));
        address selectedIndexToken = ammConfig.indexToken == address(0) ? defaultIndexToken : ammConfig.indexToken;
        require(IIndexBrokerFactoryBasketRegistry(basketRegistry).isBasket(selectedIndexToken), "Invalid index token");
        address admin = IOwnableCommunity(community).owner();
        address selectedRenderer = config.renderer == address(0) ? defaultRenderer : config.renderer;

        address clone = Clones.clone(poolTemplate);
        address ammClone = Clones.clone(ammTemplate);
        IndexBrokerNFT pool = IndexBrokerNFT(payable(clone));
        _initializeNFT(pool, community, admin, selectedRenderer, ammClone, name, config);
        _initializeAMM(pool, clone, ammClone, config.communityTokenPrice, selectedIndexToken, ammConfig);
        _emitNFTCreated(pool, clone, community, admin, selectedRenderer, name, config);
        emit IndexBrokerNFTAMMCreated(
            clone,
            ammClone,
            priceOracle,
            ammConfig.priceSourceType,
            ammConfig.normalFeeBps,
            ammConfig.specificFeeBps,
            selectedIndexToken
        );
        return clone;
    }

    function _initializeNFT(
        IndexBrokerNFT pool,
        address community,
        address admin,
        address selectedRenderer,
        address ammClone,
        string memory name,
        PoolConfig memory config
    ) internal {
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
            config.indexMiningActivationTokenAmount,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            config.lockWhitelistSlots,
            config.whitelistAccounts,
            config.whitelistAllowances
        );
    }

    function _initializeAMM(
        IndexBrokerNFT pool,
        address clone,
        address ammClone,
        uint256 communityTokenPrice,
        address selectedIndexToken,
        AMMConfig memory config
    ) internal {
        IndexBrokerNFTAMM(payable(ammClone))
            .initialize(
                clone,
                pool.communityToken(),
                communityTokenPrice,
                config.normalFeeBps,
                config.specificFeeBps,
                priceOracle,
                config.priceSourceType,
                config.priceSourceData,
                basketRegistry,
                basketSwapRouter,
                indexV3Router,
                indexV3Fee,
                selectedIndexToken
            );
    }

    function _emitNFTCreated(
        IndexBrokerNFT pool,
        address clone,
        address community,
        address admin,
        address selectedRenderer,
        string memory name,
        PoolConfig memory config
    ) internal {
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
            config.indexMiningActivationTokenAmount,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            pool.lockWhitelistSlots(),
            pool.totalWhitelistAllocation()
        );
    }
}
