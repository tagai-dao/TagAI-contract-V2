// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../interfaces/IImportHelper.sol";
import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../nutbox/Community.sol";
import "../nutbox/dapps/trade-curation/TradeCurationFactory.sol";

interface IImportWrapperOwner {
    function owner() external view returns (address);
}

/// @notice Owner-approved pool types and caller-selected shares for new imported communities.
/// @dev Initial default is TradeCuration 100%. The legacy selector follows the current default.
contract ImportHelperV2 is Ownable2Step, ReentrancyGuard {
    using Address for address payable;
    uint256 public constant VERSION = 2;
    uint256 public constant MAX_POOLS = 6;
    uint256 public constant MAX_FACTORY_TYPES = 32;
    uint16 public constant BPS = 10_000;

    struct PoolFactoryConfig {
        string name;
        uint16 maxRewardRatio;
        bool enabled;
    }

    struct PoolConfig {
        address factory;
        uint16 rewardRatio;
        bytes meta;
    }
    mapping(address => PoolFactoryConfig) public poolFactories;
    address[] public poolFactoryList;
    mapping(address => bool) private _knownFactory;
    PoolConfig[] private _defaultPools;

    address public immutable communityFactory;
    address public immutable tradeCurationFactory;
    address public immutable committee;
    address public immutable hourlyTickCalculator;
    IImportedTokenMarketRegistrar public immutable swapWrapper;

    event PoolFactorySet(address indexed factory, string name, uint16 maxRewardRatio, bool enabled);
    event DefaultPoolsSet(address[] factories, uint16[] ratios, bytes[] metadata);
    event ImportedPoolCreated(
        address indexed token,
        address indexed community,
        address indexed pool,
        address factory,
        uint16 rewardRatio,
        uint256 position
    );
    // Legacy receipts retain their primary pool. ImportedPoolCreated records every pool in V2.
    event CommunityCreated(
        address indexed token, address indexed community, address indexed pool, address creator, address calculator
    );
    event ImportedCommunityRecorded(address indexed token, address indexed community, address indexed creator);

    error InvalidAddress();
    error InvalidToken();
    error ExistingCommunityUnsupported();
    error TokenAlreadyImported();
    error InsufficientFee();
    error InvalidPoolConfig();

    constructor(
        address communityFactory_,
        address tradeCurationFactory_,
        address committee_,
        address hourlyTickCalculator_,
        address swapWrapper_
    ) {
        if (
            communityFactory_.code.length == 0 || tradeCurationFactory_.code.length == 0 || committee_.code.length == 0
                || hourlyTickCalculator_.code.length == 0 || swapWrapper_.code.length == 0
        ) revert InvalidAddress();
        if (
            TradeCurationFactory(tradeCurationFactory_).communityFactory() != communityFactory_
                || TradeCurationFactory(tradeCurationFactory_).claimSigner() == address(0)
        ) revert InvalidAddress();
        address admin = IImportWrapperOwner(swapWrapper_).owner();
        if (admin == address(0)) revert InvalidAddress();
        _transferOwnership(admin);
        communityFactory = communityFactory_;
        tradeCurationFactory = tradeCurationFactory_;
        committee = committee_;
        hourlyTickCalculator = hourlyTickCalculator_;
        swapWrapper = IImportedTokenMarketRegistrar(swapWrapper_);
        _setPoolFactory(tradeCurationFactory_, "Trade Curation", BPS, true);
        PoolConfig[] memory defaults = new PoolConfig[](1);
        defaults[0] = PoolConfig(tradeCurationFactory_, BPS, bytes(""));
        _setDefaultPools(defaults);
    }

    /// @notice Manage types for future imports. Committee approval is independently enforced.
    function adminSetPoolFactory(address factory, string calldata name, uint16 maxRewardRatio, bool enabled)
        external
        onlyOwner
    {
        _setPoolFactory(factory, name, maxRewardRatio, enabled);
    }

    function _setPoolFactory(address factory, string memory name, uint16 maxRewardRatio, bool enabled) private {
        if (
            factory == address(0) || maxRewardRatio > BPS || bytes(name).length > 64
                || (enabled
                    && (factory.code.length == 0
                        || maxRewardRatio == 0
                        || bytes(name).length == 0
                        || !ICommittee(committee).verifyContract(factory)))
        ) revert InvalidPoolConfig();
        if (!_knownFactory[factory]) {
            if (poolFactoryList.length >= MAX_FACTORY_TYPES) revert InvalidPoolConfig();
            _knownFactory[factory] = true;
            poolFactoryList.push(factory);
        }
        poolFactories[factory] = PoolFactoryConfig(name, maxRewardRatio, enabled);
        emit PoolFactorySet(factory, name, maxRewardRatio, enabled);
    }

    function adminSetDefaultPools(PoolConfig[] calldata configs) external onlyOwner {
        _setDefaultPools(configs);
    }

    function _setDefaultPools(PoolConfig[] memory configs) private {
        _validatePools(configs);
        delete _defaultPools;
        address[] memory factories = new address[](configs.length);
        uint16[] memory ratios = new uint16[](configs.length);
        bytes[] memory metadata = new bytes[](configs.length);
        for (uint256 i; i < configs.length; ++i) {
            _defaultPools.push(configs[i]);
            factories[i] = configs[i].factory;
            ratios[i] = configs[i].rewardRatio;
            metadata[i] = configs[i].meta;
        }
        emit DefaultPoolsSet(factories, ratios, metadata);
    }

    function getDefaultPools() public view returns (PoolConfig[] memory) {
        return _defaultPools;
    }

    function defaultPoolCount() external view returns (uint256) {
        return _defaultPools.length;
    }

    function poolFactoryCount() external view returns (uint256) {
        return poolFactoryList.length;
    }

    /// @param existingCommunity Reserved for legacy ABI; new imports create their own community.
    function createCommunityAndPool(address token, address existingCommunity)
        external
        payable
        nonReentrant
        returns (address community, address pool)
    {
        if (existingCommunity != address(0)) revert ExistingCommunityUnsupported();
        address[] memory pools;
        (community, pools) = _create(token, getDefaultPools());
        pool = pools[0];
    }

    /// @notice Explicit selection must be nonempty, distinct, enabled, and sum to exactly 100%.
    function createCommunityAndPools(address token, PoolConfig[] calldata configs)
        external
        payable
        nonReentrant
        returns (address community, address[] memory pools)
    {
        return _create(token, configs);
    }

    function _validatePools(PoolConfig[] memory configs) private view {
        if (configs.length == 0 || configs.length > MAX_POOLS) revert InvalidPoolConfig();
        uint256 sum;
        for (uint256 i; i < configs.length; ++i) {
            PoolConfig memory c = configs[i];
            PoolFactoryConfig storage f = poolFactories[c.factory];
            if (
                !f.enabled || c.factory.code.length == 0 || c.rewardRatio == 0 || c.rewardRatio > f.maxRewardRatio
                    || c.meta.length > 4096 || !ICommittee(committee).verifyContract(c.factory)
            ) revert InvalidPoolConfig();
            for (uint256 j; j < i; ++j) {
                if (configs[j].factory == c.factory) revert InvalidPoolConfig();
            }
            sum += c.rewardRatio;
        }
        if (sum != BPS) revert InvalidPoolConfig();
    }

    function _create(address token, PoolConfig[] memory configs)
        private
        returns (address community, address[] memory pools)
    {
        if (token.code.length == 0) revert InvalidToken();
        _validatePools(configs);
        (bool registered,,) = swapWrapper.getImportedMarket(token);
        if (registered) revert TokenAlreadyImported();
        address creator = msg.sender;
        uint256 createFee = ICommittee(committee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(committee).getCommunitySettingsFee();
        uint256 totalFee = createFee + settingsFee * configs.length;
        if (msg.value < totalFee) revert InsufficientFee();
        community = ICommunityFactory(communityFactory).createCommunity{value: createFee}(
            false, token, address(0), bytes(""), hourlyTickCalculator, bytes("")
        );
        Community(community).adminSetDev(creator);
        pools = new address[](configs.length);
        uint16[] memory finalRatios = new uint16[](configs.length);
        for (uint256 i; i < configs.length; ++i) {
            finalRatios[i] = configs[i].rewardRatio;
        }
        for (uint256 i; i < configs.length; ++i) {
            uint16[] memory ratios = new uint16[](i + 1);
            if (i + 1 == configs.length) ratios = finalRatios;
            ICommunity(community).adminAddPool{value: settingsFee}(
                poolFactories[configs[i].factory].name, ratios, configs[i].factory, configs[i].meta
            );
            pools[i] = ICommunity(community).activedPools(i);
            emit ImportedPoolCreated(token, community, pools[i], configs[i].factory, configs[i].rewardRatio, i);
        }
        swapWrapper.registerImportedToken(token, community, creator);
        Ownable(community).transferOwnership(creator);
        if (msg.value > totalFee) payable(creator).sendValue(msg.value - totalFee);
        emit CommunityCreated(token, community, pools[0], creator, hourlyTickCalculator);
        emit ImportedCommunityRecorded(token, community, creator);
    }
}
