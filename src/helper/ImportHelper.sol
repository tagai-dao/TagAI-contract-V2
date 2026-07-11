// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IImportHelper.sol";
import "../nutbox/Community.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ImportHelper
/// @notice Shared helper contract for importing external tokens into the Nutbox community system.
///         Ensures the importer has an IPShare subject, creates Community + SocialCuration pool,
///         and records the importer for downstream fee routing.
contract ImportHelper is IImportHelper {
    address private immutable communityFactory;
    address private immutable socialCurationFactory;
    address private immutable nutboxCommittee;
    address public immutable ipshare;

    /// @notice Token importer recorded at first successful import (one import per token).
    mapping(address token => address importer) public importerOf;

    error InsufficientFee();
    error TokenAlreadyImported();

    constructor(
        address communityFactory_,
        address socialCurationFactory_,
        address nutboxCommittee_,
        address ipshare_
    ) {
        require(communityFactory_ != address(0), "zero communityFactory");
        require(socialCurationFactory_ != address(0), "zero socialCurationFactory");
        require(nutboxCommittee_ != address(0), "zero nutboxCommittee");
        require(ipshare_ != address(0), "zero ipshare");
        communityFactory = communityFactory_;
        socialCurationFactory = socialCurationFactory_;
        nutboxCommittee = nutboxCommittee_;
        ipshare = ipshare_;
    }

    event CommunityCreated(
        address indexed token,
        address indexed community,
        address indexed pool,
        address creator,
        address calculator
    );

    /// @notice Create a Nutbox Community and SocialCuration pool for an external token.
    /// @param token The ERC20 token address to import.
    /// @param calculator The reward calculator contract address (e.g. HourlyTickCalculator).
    /// @param distributionPolicy The distribution policy data passed to the calculator.
    /// @return community The newly created Nutbox Community address.
    /// @return pool The newly created SocialCuration pool address.
    function createCommunityAndPool(
        address token,
        address calculator,
        bytes calldata distributionPolicy
    ) external payable returns (address community, address pool) {
        address creator = msg.sender;

        if (importerOf[token] != address(0)) {
            revert TokenAlreadyImported();
        }

        // Fee math aligned with Pump.createToken (no Pump-level createFee here).
        bool needCreateIPShare = !IIPShare(ipshare).ipshareCreated(creator);
        uint256 ipshareCreateFee = 0;
        if (needCreateIPShare) {
            ipshareCreateFee = IIPShare(ipshare).createFee();
        }

        uint256 createFee = ICommittee(nutboxCommittee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(nutboxCommittee).getCommunitySettingsFee();
        uint256 totalFixedFee = ipshareCreateFee + createFee + settingsFee;

        if (msg.value < totalFixedFee) {
            revert InsufficientFee();
        }

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

        // 4. Transfer ownership to user
        Ownable(community).transferOwnership(creator);

        importerOf[token] = creator;

        // Refund dust above the fixed fees.
        if (msg.value > totalFixedFee) {
            (bool success,) = creator.call{value: msg.value - totalFixedFee}("");
            require(success, "refund failed");
        }

        emit CommunityCreated(token, community, pool, creator, calculator);
    }

    receive() external payable {}
}
