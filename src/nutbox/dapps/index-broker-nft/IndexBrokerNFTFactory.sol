// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "../../CommunityFactory.sol";
import "../../interfaces/IPoolFactory.sol";
import "../../../router/INutboxRouter.sol";
import "./IIndexBrokerNFT.sol";
import "./IndexBrokerNFTAMM.sol";

interface IOwnableCommunity {
    function owner() external view returns (address);
}

interface IIndexBrokerFactoryBasketRegistry {
    function isBasket(address candidate) external view returns (bool);
    function basketVersion(address basket) external view returns (uint32);
}

interface IIndexBrokerFactoryPump {
    function createdTokens(address token) external view returns (bool);
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
        address nftTemplate;
        uint256[] levelThresholds;
        uint256[] levelWeights;
        uint256 communityTokenPrice;
        uint256 indexMiningActivationTokenAmount;
        uint256 recommitPrice;
        uint256 nativePrice;
        uint256 maxSupply;
        uint16 referralBps;
        bytes ammConfig;
        bytes nftTemplateConfig;
        bool lockWhitelistSlots;
        bool rerollEnabled;
        address[] whitelistAccounts;
        uint256[] whitelistAllowances;
    }

    struct AMMConfig {
        uint16 normalFeeBps;
        uint16 specificFeeBps;
        INutboxRouter.SourceType priceSourceType;
        bytes priceSourceData;
        address indexToken;
        /// @dev Zero selects the constructor-supplied Pump when it created the
        ///      community token, otherwise the token is treated as external.
        address pump;
    }

    address public immutable communityFactory;
    address public immutable pump;
    address public immutable defaultRenderer;
    address public immutable ammTemplate;
    address public immutable nutboxRouter;
    address public immutable basketRegistry;
    address public immutable indexV3Router;
    uint24 public immutable indexV3Fee;
    address public defaultIndexToken;
    uint16 public platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;
    mapping(uint32 => address) public basketSwapRouterForVersion;
    mapping(address => bool) public supportedPump;
    mapping(address => bool) public supportedNFTTemplate;
    address[] private _nftTemplates;
    mapping(address => uint256) private _nftTemplateIndexPlusOne;
    bytes[] private _reservedCollectionNames;
    mapping(bytes32 => bool) public reservedCollectionNameHash;
    mapping(bytes32 => uint256) private _reservedCollectionNameIndexPlusOne;

    event PlatformFeeBpsChanged(uint16 previousBps, uint16 newBps);
    event DefaultIndexTokenChanged(address indexed previousToken, address indexed newToken);
    event BasketSwapRouterChanged(uint32 indexed version, address indexed previousRouter, address indexed newRouter);
    event PumpAdded(address indexed pump);
    event PumpRemoved(address indexed pump);
    event NFTTemplateAdded(address indexed template);
    event NFTTemplateRemoved(address indexed template);
    event ReservedCollectionNameAdded(string name);
    event ReservedCollectionNameRemoved(string name);
    event IndexBasketRouterSelected(
        address indexed pool, address indexed indexToken, uint32 indexed version, address basketSwapRouter
    );
    event IndexBrokerNFTAMMCreated(
        address indexed pool,
        address indexed ammVault,
        address indexed pump,
        address nutboxRouter,
        INutboxRouter.SourceType priceSourceType,
        address priceQuoteToken,
        bool active,
        uint16 normalFeeBps,
        uint16 specificFeeBps,
        address indexToken
    );
    event IndexBrokerNFTCreated(
        address indexed pool,
        address indexed community,
        address indexed admin,
        address nftTemplate,
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
    error InvalidPump();
    error PumpAlreadyAdded();
    error PumpNotFound();
    error TokenNotCreatedByPump();
    error InvalidNFTTemplate();
    error NFTTemplateAlreadyAdded();
    error NFTTemplateNotFound();
    error InvalidBasketRouterConfiguration();
    error DuplicateBasketVersion();
    error UnsupportedBasketVersion();
    error DefaultBasketVersion();

    constructor(
        address communityFactory_,
        address pump_,
        address defaultRenderer_,
        address ammTemplate_,
        address nutboxRouter_,
        address basketRegistry_,
        uint32[] memory basketVersions_,
        address[] memory basketSwapRouters_,
        address indexV3Router_,
        uint24 indexV3Fee_,
        address defaultIndexToken_
    ) {
        require(
            communityFactory_ != address(0) && pump_.code.length > 0 && defaultRenderer_.code.length > 0
                && ammTemplate_.code.length > 0 && nutboxRouter_.code.length > 0 && basketRegistry_.code.length > 0,
            "Invalid address"
        );
        // RH 适配：indexV3Router_ == address(0) 时禁用「用 native 买指数」；
        // RH 主网传入 Uniswap SwapRouter02，fee=100（USDG/WETH 0.01%）。
        if (indexV3Router_ != address(0)) {
            require(indexV3Router_.code.length > 0, "Invalid address");
        }
        if (basketVersions_.length == 0 || basketVersions_.length != basketSwapRouters_.length) {
            revert InvalidBasketRouterConfiguration();
        }
        communityFactory = communityFactory_;
        pump = pump_;
        defaultRenderer = defaultRenderer_;
        ammTemplate = ammTemplate_;
        nutboxRouter = nutboxRouter_;
        basketRegistry = basketRegistry_;
        indexV3Router = indexV3Router_;
        indexV3Fee = indexV3Fee_;
        for (uint256 i; i < basketVersions_.length; ++i) {
            if (basketSwapRouterForVersion[basketVersions_[i]] != address(0)) revert DuplicateBasketVersion();
            _setBasketSwapRouter(basketVersions_[i], basketSwapRouters_[i]);
        }
        _resolveIndexToken(defaultIndexToken_);
        defaultIndexToken = defaultIndexToken_;
        supportedPump[pump_] = true;
        emit PumpAdded(pump_);
        _addReservedCollectionName("stonkbroker");
    }

    /// @notice Enables one NFT implementation for future pool creation.
    function addNFTTemplate(address template) external onlyOwner {
        if (template.code.length == 0) revert InvalidNFTTemplate();
        if (supportedNFTTemplate[template]) revert NFTTemplateAlreadyAdded();
        try IIndexBrokerNFT(template).nftTemplateInterfaceId() returns (bytes4 interfaceId) {
            if (interfaceId != IIndexBrokerNFT.initialize.selector) revert InvalidNFTTemplate();
        } catch {
            revert InvalidNFTTemplate();
        }
        supportedNFTTemplate[template] = true;
        _nftTemplates.push(template);
        _nftTemplateIndexPlusOne[template] = _nftTemplates.length;
        emit NFTTemplateAdded(template);
    }

    /// @notice Removes one implementation from future pool creation only.
    function removeNFTTemplate(address template) external onlyOwner {
        uint256 indexPlusOne = _nftTemplateIndexPlusOne[template];
        if (indexPlusOne == 0) revert NFTTemplateNotFound();
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _nftTemplates.length - 1;
        if (index != lastIndex) {
            address movedTemplate = _nftTemplates[lastIndex];
            _nftTemplates[index] = movedTemplate;
            _nftTemplateIndexPlusOne[movedTemplate] = index + 1;
        }
        _nftTemplates.pop();
        delete _nftTemplateIndexPlusOne[template];
        delete supportedNFTTemplate[template];
        emit NFTTemplateRemoved(template);
    }

    function nftTemplateCount() external view returns (uint256) {
        return _nftTemplates.length;
    }

    /// @dev Removal uses swap-and-pop, so enumeration order is not stable.
    function nftTemplateAt(uint256 index) external view returns (address) {
        return _nftTemplates[index];
    }

    /// @notice Enables a Pump version for future NFT pools.
    /// @dev Existing AMMs snapshot their Pump and are not affected by later registry changes.
    function addPump(address newPump) external onlyOwner {
        if (newPump.code.length == 0) revert InvalidPump();
        if (supportedPump[newPump]) revert PumpAlreadyAdded();
        supportedPump[newPump] = true;
        emit PumpAdded(newPump);
    }

    /// @notice Prevents a Pump version from being selected by future NFT pools.
    function removePump(address oldPump) external onlyOwner {
        if (!supportedPump[oldPump]) revert PumpNotFound();
        delete supportedPump[oldPump];
        emit PumpRemoved(oldPump);
    }

    function setPlatformFeeBps(uint16 newBps) external onlyOwner {
        require(newBps <= BPS_DENOMINATOR, "Invalid platform fee");
        uint16 previousBps = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeBpsChanged(previousBps, newBps);
    }

    function setDefaultIndexToken(address newToken) external onlyOwner {
        _resolveIndexToken(newToken);
        address previousToken = defaultIndexToken;
        defaultIndexToken = newToken;
        emit DefaultIndexTokenChanged(previousToken, newToken);
    }

    /// @notice Adds or replaces the Basket Router used by future NFT pools for one Basket version.
    /// @dev Existing AMMs keep the Router selected when they were initialized.
    function setBasketSwapRouter(uint32 version, address newRouter) external onlyOwner {
        _setBasketSwapRouter(version, newRouter);
    }

    /// @notice Disables one Basket version for future NFT pools.
    function removeBasketSwapRouter(uint32 version) external onlyOwner {
        address previousRouter = basketSwapRouterForVersion[version];
        if (previousRouter == address(0)) revert UnsupportedBasketVersion();
        if (IIndexBrokerFactoryBasketRegistry(basketRegistry).basketVersion(defaultIndexToken) == version) {
            revert DefaultBasketVersion();
        }
        delete basketSwapRouterForVersion[version];
        emit BasketSwapRouterChanged(version, previousRouter, address(0));
    }

    /// @notice Returns the Router currently selected for the Factory default index token.
    /// @dev Retains the historical single-Router getter while routing new pools by Basket version.
    function basketSwapRouter() external view returns (address) {
        uint32 version = IIndexBrokerFactoryBasketRegistry(basketRegistry).basketVersion(defaultIndexToken);
        return basketSwapRouterForVersion[version];
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
        if (!supportedNFTTemplate[config.nftTemplate]) revert NFTTemplateNotFound();
        AMMConfig memory ammConfig = abi.decode(config.ammConfig, (AMMConfig));
        address selectedIndexToken = ammConfig.indexToken == address(0) ? defaultIndexToken : ammConfig.indexToken;
        (uint32 indexBasketVersion, address selectedBasketSwapRouter) = _resolveIndexToken(selectedIndexToken);
        address admin = IOwnableCommunity(community).owner();
        address selectedRenderer = config.renderer == address(0) ? defaultRenderer : config.renderer;

        address clone = Clones.clone(config.nftTemplate);
        address ammClone = Clones.clone(ammTemplate);
        if (config.fundsReceiver == address(0)) config.fundsReceiver = ammClone;
        IIndexBrokerNFT pool = IIndexBrokerNFT(clone);
        _initializeNFT(pool, community, admin, selectedRenderer, ammClone, selectedIndexToken, name, config);
        address selectedPump = _selectPump(pool.communityToken(), ammConfig.pump);
        _initializeAMM(
            pool,
            clone,
            ammClone,
            config.communityTokenPrice,
            selectedIndexToken,
            selectedBasketSwapRouter,
            selectedPump,
            ammConfig
        );
        _emitNFTCreated(pool, clone, community, admin, selectedRenderer, name, config);
        IndexBrokerNFTAMM initializedAMM = IndexBrokerNFTAMM(payable(ammClone));
        emit IndexBrokerNFTAMMCreated(
            clone,
            ammClone,
            selectedPump,
            nutboxRouter,
            initializedAMM.priceSourceType(),
            initializedAMM.priceQuoteToken(),
            initializedAMM.active(),
            ammConfig.normalFeeBps,
            ammConfig.specificFeeBps,
            selectedIndexToken
        );
        emit IndexBasketRouterSelected(clone, selectedIndexToken, indexBasketVersion, selectedBasketSwapRouter);
        return clone;
    }

    function _setBasketSwapRouter(uint32 version, address newRouter) internal {
        if (version == 0 || newRouter.code.length == 0) revert InvalidBasketRouterConfiguration();
        IIndexBrokerBasketSwapRouter router = IIndexBrokerBasketSwapRouter(newRouter);
        address hook = router.basketHook();
        address settlementToken = router.settlementToken();
        if (
            hook.code.length == 0 || settlementToken.code.length == 0
                || IIndexBrokerBasketHook(hook).tokenVersion() != version
                || IIndexBrokerBasketHook(hook).basketRegistry() != basketRegistry
                || IIndexBrokerBasketHook(hook).settlementToken() != settlementToken
        ) revert InvalidBasketRouterConfiguration();

        if (defaultIndexToken != address(0)) {
            uint32 defaultVersion = IIndexBrokerFactoryBasketRegistry(basketRegistry).basketVersion(defaultIndexToken);
            if (defaultVersion == version) _validateIndexToken(defaultIndexToken, version, newRouter);
        }

        address previousRouter = basketSwapRouterForVersion[version];
        basketSwapRouterForVersion[version] = newRouter;
        emit BasketSwapRouterChanged(version, previousRouter, newRouter);
    }

    function _resolveIndexToken(address token) internal view returns (uint32 version, address selectedRouter) {
        IIndexBrokerFactoryBasketRegistry registry = IIndexBrokerFactoryBasketRegistry(basketRegistry);
        if (!registry.isBasket(token)) revert UnsupportedBasketVersion();
        version = registry.basketVersion(token);
        selectedRouter = basketSwapRouterForVersion[version];
        if (version == 0 || selectedRouter == address(0)) revert UnsupportedBasketVersion();
        _validateIndexToken(token, version, selectedRouter);
    }

    function _validateIndexToken(address token, uint32 version, address selectedRouter) internal view {
        IIndexBrokerBasketToken basket = IIndexBrokerBasketToken(token);
        IIndexBrokerBasketSwapRouter router = IIndexBrokerBasketSwapRouter(selectedRouter);
        address hook = router.basketHook();
        if (
            token.code.length == 0 || basket.protocolVersion() != version || basket.registry() != basketRegistry
                || basket.engine() != hook || basket.settlementToken() != router.settlementToken()
        ) revert InvalidBasketRouterConfiguration();
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
        IIndexBrokerNFT pool,
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
            config.whitelistAllowances,
            config.nftTemplateConfig
        );
    }

    function _initializeAMM(
        IIndexBrokerNFT pool,
        address clone,
        address ammClone,
        uint256 communityTokenPrice,
        address selectedIndexToken,
        address selectedBasketSwapRouter,
        address selectedPump,
        AMMConfig memory config
    ) internal {
        IndexBrokerNFTAMM(payable(ammClone))
            .initialize(
                clone,
                pool.communityToken(),
                communityTokenPrice,
                config.normalFeeBps,
                config.specificFeeBps,
                selectedPump,
                nutboxRouter,
                config.priceSourceType,
                config.priceSourceData,
                basketRegistry,
                selectedBasketSwapRouter,
                indexV3Router,
                indexV3Fee,
                selectedIndexToken
            );
    }

    function _selectPump(address communityToken, address configuredPump) internal view returns (address selectedPump) {
        selectedPump = configuredPump;
        if (selectedPump == address(0)) {
            // Preserve the original single-Pump creation flow without scanning an
            // ever-growing Pump list. Newer Pump versions are selected explicitly.
            if (supportedPump[pump] && IIndexBrokerFactoryPump(pump).createdTokens(communityToken)) return pump;
            return address(0);
        }
        if (!supportedPump[selectedPump]) revert PumpNotFound();
        if (!IIndexBrokerFactoryPump(selectedPump).createdTokens(communityToken)) revert TokenNotCreatedByPump();
    }

    function _emitNFTCreated(
        IIndexBrokerNFT pool,
        address clone,
        address community,
        address admin,
        address selectedRenderer,
        string memory name,
        PoolConfig memory config
    ) internal {
        uint256 effectiveRecommitPrice = config.rerollEnabled
            ? (config.recommitPrice == 0 ? config.communityTokenPrice : config.recommitPrice)
            : 0;
        emit IndexBrokerNFTCreated(
            clone,
            community,
            admin,
            config.nftTemplate,
            pool.communityToken(),
            selectedRenderer,
            name,
            config.symbol,
            config.fundsReceiver,
            config.communityTokenPrice,
            config.indexMiningActivationTokenAmount,
            effectiveRecommitPrice,
            config.nativePrice,
            config.maxSupply,
            config.referralBps,
            pool.lockWhitelistSlots(),
            pool.rerollEnabled(),
            pool.totalWhitelistAllocation()
        );
    }
}
