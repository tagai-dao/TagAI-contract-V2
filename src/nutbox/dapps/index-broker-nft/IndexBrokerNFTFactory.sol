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
    uint256 public constant MAX_RESERVED_NAME_LENGTH = 64;

    struct PoolConfig {
        string symbol;
        address fundsReceiver;
        address renderer;
        uint256[] levelThresholds;
        uint256[] levelWeights;
        uint256 communityTokenPrice;
        uint256 indexMiningActivationTokenAmount;
        uint256 recommitPrice;
        uint256 nativePrice;
        uint256 maxSupply;
        uint16 referralBps;
        bytes ammConfig;
        bool lockWhitelistSlots;
        bool rerollEnabled;
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
    address public immutable pump;
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
    bytes[] private _reservedCollectionNames;
    mapping(bytes32 => bool) public reservedCollectionNameHash;
    mapping(bytes32 => uint256) private _reservedCollectionNameIndexPlusOne;

    event PlatformFeeBpsChanged(uint16 previousBps, uint16 newBps);
    event DefaultIndexTokenChanged(address indexed previousToken, address indexed newToken);
    event ReservedCollectionNameAdded(string name);
    event ReservedCollectionNameRemoved(string name);
    event IndexBrokerNFTAMMCreated(
        address indexed pool,
        address indexed ammVault,
        address priceOracle,
        IIndexBrokerNFTPriceOracle.SourceType priceSourceType,
        bool active,
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
        uint256 recommitPrice,
        uint256 nativePrice,
        uint256 maxSupply,
        uint16 referralBps,
        bool lockWhitelistSlots,
        bool rerollEnabled,
        uint256 totalWhitelistAllocation
    );

    error InvalidReservedCollectionName();
    error ReservedCollectionNameAlreadyAdded();
    error ReservedCollectionNameNotFound();
    error ReservedCollectionNameUsed();

    constructor(
        address communityFactory_,
        address pump_,
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
            communityFactory_ != address(0) && pump_.code.length > 0 && defaultRenderer_.code.length > 0
                && ammTemplate_.code.length > 0 && priceOracle_.code.length > 0 && basketRegistry_.code.length > 0
                && basketSwapRouter_.code.length > 0 && indexV3Router_.code.length > 0,
            "Invalid address"
        );
        require(IIndexBrokerFactoryBasketRegistry(basketRegistry_).isBasket(defaultIndexToken_), "Invalid index token");
        communityFactory = communityFactory_;
        pump = pump_;
        defaultRenderer = defaultRenderer_;
        poolTemplate = address(new IndexBrokerNFT());
        ammTemplate = ammTemplate_;
        priceOracle = priceOracle_;
        basketRegistry = basketRegistry_;
        basketSwapRouter = basketSwapRouter_;
        indexV3Router = indexV3Router_;
        indexV3Fee = indexV3Fee_;
        defaultIndexToken = defaultIndexToken_;
        _addReservedCollectionName("stonkbroker");
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

    /// @notice Adds exact, case-sensitive collection names that future NFT collections cannot use.
    function addReservedCollectionNames(string[] calldata names) external onlyOwner {
        for (uint256 i; i < names.length; ++i) {
            _addReservedCollectionName(names[i]);
        }
    }

    /// @notice Removes one exact, case-sensitive collection name from the reserved list.
    function removeReservedCollectionName(string calldata name) external onlyOwner {
        bytes32 nameHash = keccak256(bytes(name));
        uint256 indexPlusOne = _reservedCollectionNameIndexPlusOne[nameHash];
        if (indexPlusOne == 0) revert ReservedCollectionNameNotFound();

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _reservedCollectionNames.length - 1;
        if (index != lastIndex) {
            bytes memory movedName = _reservedCollectionNames[lastIndex];
            _reservedCollectionNames[index] = movedName;
            _reservedCollectionNameIndexPlusOne[keccak256(movedName)] = index + 1;
        }

        _reservedCollectionNames.pop();
        delete _reservedCollectionNameIndexPlusOne[nameHash];
        delete reservedCollectionNameHash[nameHash];
        emit ReservedCollectionNameRemoved(name);
    }

    function reservedCollectionNameCount() external view returns (uint256) {
        return _reservedCollectionNames.length;
    }

    /// @dev Removal uses swap-and-pop, so enumeration order is not stable.
    function reservedCollectionNameAt(uint256 index) external view returns (string memory) {
        return string(_reservedCollectionNames[index]);
    }

    function createPool(address community, string memory name, bytes calldata meta)
        external
        override
        returns (address)
    {
        require(community == msg.sender, "Permission denied: caller is not community");
        require(CommunityFactory(payable(communityFactory)).createdCommunity(community), "Invalid community");
        _validateCollectionName(name);

        PoolConfig memory config = abi.decode(meta, (PoolConfig));
        AMMConfig memory ammConfig = abi.decode(config.ammConfig, (AMMConfig));
        address selectedIndexToken = ammConfig.indexToken == address(0) ? defaultIndexToken : ammConfig.indexToken;
        require(IIndexBrokerFactoryBasketRegistry(basketRegistry).isBasket(selectedIndexToken), "Invalid index token");
        address admin = IOwnableCommunity(community).owner();
        address selectedRenderer = config.renderer == address(0) ? defaultRenderer : config.renderer;

        address clone = Clones.clone(poolTemplate);
        address ammClone = Clones.clone(ammTemplate);
        IndexBrokerNFT pool = IndexBrokerNFT(payable(clone));
        _initializeNFT(pool, community, admin, selectedRenderer, ammClone, selectedIndexToken, name, config);
        _initializeAMM(pool, clone, ammClone, config.communityTokenPrice, selectedIndexToken, ammConfig);
        _emitNFTCreated(pool, clone, community, admin, selectedRenderer, name, config);
        IndexBrokerNFTAMM initializedAMM = IndexBrokerNFTAMM(payable(ammClone));
        emit IndexBrokerNFTAMMCreated(
            clone,
            ammClone,
            priceOracle,
            initializedAMM.priceSourceType(),
            initializedAMM.active(),
            ammConfig.normalFeeBps,
            ammConfig.specificFeeBps,
            selectedIndexToken
        );
        return clone;
    }

    function _addReservedCollectionName(string memory name) internal {
        bytes memory rawName = bytes(name);
        if (rawName.length == 0 || rawName.length > MAX_RESERVED_NAME_LENGTH) {
            revert InvalidReservedCollectionName();
        }
        bytes32 nameHash = keccak256(rawName);
        if (reservedCollectionNameHash[nameHash]) revert ReservedCollectionNameAlreadyAdded();
        reservedCollectionNameHash[nameHash] = true;
        _reservedCollectionNames.push(rawName);
        _reservedCollectionNameIndexPlusOne[nameHash] = _reservedCollectionNames.length;
        emit ReservedCollectionNameAdded(name);
    }

    function _validateCollectionName(string memory name) internal view {
        if (reservedCollectionNameHash[keccak256(bytes(name))]) revert ReservedCollectionNameUsed();
    }

    function _initializeNFT(
        IndexBrokerNFT pool,
        address community,
        address admin,
        address selectedRenderer,
        address ammClone,
        address selectedIndexToken,
        string memory name,
        PoolConfig memory config
    ) internal {
        pool.initialize(
            community,
            admin,
            selectedRenderer,
            ammClone,
            selectedIndexToken,
            name,
            config.symbol,
            config.fundsReceiver,
            config.levelThresholds,
            config.levelWeights,
            config.communityTokenPrice,
            config.indexMiningActivationTokenAmount,
            config.recommitPrice,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            config.lockWhitelistSlots,
            config.rerollEnabled,
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
                pump,
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
            pool.recommitPrice(),
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            pool.lockWhitelistSlots(),
            pool.rerollEnabled(),
            pool.totalWhitelistAllocation()
        );
    }
}
