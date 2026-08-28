// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IImportHelper.sol";
import "../interfaces/IPump.sol";
import "../nutbox/Community.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ImportHelper
/// @notice Shared helper contract for importing external tokens into the Nutbox community system.
///         一次登记、可复用 Community、拒绝 Pump 代币；登记信息写入 TagAISwapWrapper。
///         保留 IPShare 门槛与现有费用流（新建 Community 收 Community+settings+ipshare；复用 Community 仍补建缺失 IPShare，Community 费全额退回）。
contract ImportHelper is IImportHelper {
    address private immutable communityFactory;
    address private immutable socialCurationFactory;
    address private immutable nutboxCommittee;
    address public immutable ipshare;
    /// @dev Pump 工厂，用于拒绝 Pump 创建的代币；address(0) 仅限测试。
    address public immutable pump;
    /// @dev 导入代币市场登记器（TagAISwapWrapper）。
    IImportedTokenMarketRegistrar public immutable swapWrapper;

    /// @notice Token importer recorded at first successful import (one import per token)。
    mapping(address token => address importer) public importerOf;

    error InsufficientFee();
    error InvalidToken();
    error InvalidCommunity();
    error InvalidRewardCalculator();
    error PumpTokenNotImportable();
    error TokenAlreadyImported();

    constructor(
        address communityFactory_,
        address socialCurationFactory_,
        address nutboxCommittee_,
        address ipshare_,
        address pump_,
        address swapWrapper_
    ) {
        require(communityFactory_ != address(0), "zero communityFactory");
        require(socialCurationFactory_ != address(0), "zero socialCurationFactory");
        require(nutboxCommittee_ != address(0), "zero nutboxCommittee");
        require(ipshare_ != address(0), "zero ipshare");
        require(swapWrapper_ != address(0), "zero swapWrapper");
        communityFactory = communityFactory_;
        socialCurationFactory = socialCurationFactory_;
        nutboxCommittee = nutboxCommittee_;
        ipshare = ipshare_;
        pump = pump_;
        swapWrapper = IImportedTokenMarketRegistrar(swapWrapper_);
    }

    event CommunityCreated(
        address indexed token,
        address indexed community,
        address indexed pool,
        address creator,
        address calculator
    );
    event ImportedCommunityRecorded(address indexed token, address indexed community, address indexed creator);

    /// @notice 三参数 overload：existingCommunity = address(0) → 新建 Community。
    function createCommunityAndPool(
        address token,
        address calculator,
        bytes calldata distributionPolicy
    ) external payable returns (address community, address pool) {
        return _createCommunityAndPool(token, calculator, distributionPolicy, address(0));
    }

    /// @notice 导入 ERC20 并绑定到新建或已有 Nutbox Community。
    /// @param token 待导入 ERC20。
    /// @param calculator 奖励计算器（新建 Community 用；复用时必须与 existingCommunity 一致）。
    /// @param distributionPolicy 计算器分发策略（仅新建时使用）。
    /// @param existingCommunity 可选复用 Community；address(0) 表示新建。
    function createCommunityAndPool(
        address token,
        address calculator,
        bytes calldata distributionPolicy,
        address existingCommunity
    ) external payable returns (address community, address pool) {
        return _createCommunityAndPool(token, calculator, distributionPolicy, existingCommunity);
    }

    /// @dev 内部实现：internal 调用保留原始 msg.value（避免 external this. 调用重置 msg.value）。
    function _createCommunityAndPool(
        address token,
        address calculator,
        bytes calldata distributionPolicy,
        address existingCommunity
    ) internal returns (address community, address pool) {
        if (token.code.length == 0) revert InvalidToken();
        // 拒绝 Pump 创建的代币（pump==address(0) 时跳过，仅测试用）。
        if (pump != address(0) && IPump(pump).createdTokens(token)) revert PumpTokenNotImportable();
        // 已登记（Wrapper 或 importerOf）→ 拒绝重复导入。
        (bool registered,,) = swapWrapper.getImportedMarket(token);
        if (registered || importerOf[token] != address(0)) revert TokenAlreadyImported();

        address creator = msg.sender;

        // IPShare 门槛：无论新建还是复用 Community，缺失则补建。
        bool needCreateIPShare = !IIPShare(ipshare).ipshareCreated(creator);
        uint256 ipshareCreateFee = needCreateIPShare ? IIPShare(ipshare).createFee() : 0;

        if (existingCommunity != address(0)) {
            _validateExistingCommunity(token, calculator, existingCommunity);
            if (needCreateIPShare) {
                IIPShare(ipshare).createShare{value: ipshareCreateFee}(creator);
            }
            // 复用 Community：不新建、不 adminAddPool；Community 费全额退回，仅收 IPShare 费。
            swapWrapper.registerImportedToken(token, existingCommunity, creator);
            importerOf[token] = creator;
            if (msg.value > ipshareCreateFee) {
                (bool ok,) = creator.call{value: msg.value - ipshareCreateFee}("");
                require(ok, "refund failed");
            }
            emit ImportedCommunityRecorded(token, existingCommunity, creator);
            return (existingCommunity, address(0));
        }

        // 新建 Community：收 Community + settings + ipshare 费。
        uint256 createFee = ICommittee(nutboxCommittee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(nutboxCommittee).getCommunitySettingsFee();
        uint256 totalFixedFee = ipshareCreateFee + createFee + settingsFee;
        if (msg.value < totalFixedFee) revert InsufficientFee();

        if (needCreateIPShare) {
            IIPShare(ipshare).createShare{value: ipshareCreateFee}(creator);
        }

        // 1. Create Nutbox Community (ImportHelper becomes owner)
        community = ICommunityFactory(communityFactory).createCommunity{value: createFee}(
            false,              // isMintable = false (external token, not mintable)
            token,              // communityToken = the imported token
            address(0),         // communityTokenFactory = not needed
            bytes(""),          // tokenMeta
            calculator,         // rewardCalculator
            distributionPolicy  // distributionPolicy
        );

        // 2. Set devFund to user address (requires Community concrete call)
        Community(community).adminSetDev(creator);

        // 3. Create SocialCuration pool (100% reward allocation)
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        ICommunity(community).adminAddPool{value: settingsFee}(
            "Social Curation",
            ratios,
            socialCurationFactory,
            bytes("")
        );
        pool = ICommunity(community).activedPools(0);

        // 4. 登记到 Wrapper 并记录 importer，再转交所有权。
        swapWrapper.registerImportedToken(token, community, creator);
        importerOf[token] = creator;
        Ownable(community).transferOwnership(creator);

        // Refund dust above the fixed fees.
        if (msg.value > totalFixedFee) {
            (bool success,) = creator.call{value: msg.value - totalFixedFee}("");
            require(success, "refund failed");
        }

        emit CommunityCreated(token, community, pool, creator, calculator);
        emit ImportedCommunityRecorded(token, community, creator);
    }

    /// @dev 复用 Community 校验：工厂创建、token 匹配、calculator 匹配。
    function _validateExistingCommunity(address token, address calculator, address community) internal view {
        if (community.code.length == 0 || !ICommunityFactory(communityFactory).createdCommunity(community)) {
            revert InvalidCommunity();
        }
        if (ICommunity(community).getCommunityToken() != token) revert InvalidCommunity();
        if (ICommunity(community).rewardCalculator() != calculator) revert InvalidRewardCalculator();
    }

    receive() external payable {}
}
