// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../nutbox/Community.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ImportHelper
/// @notice Shared helper contract for importing external tokens into the Nutbox community system.
///         Creates a Nutbox Community + SocialCuration pool in a single transaction.
///         Replaces the old Pump6 import flow.
contract ImportHelper {
    address constant COMMUNITY_FACTORY      = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address constant NUTBOX_COMMITTEE       = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;

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

        // 1. Create Nutbox Community (ImportHelper becomes owner)
        uint256 createFee = ICommittee(NUTBOX_COMMITTEE).getCreateCommunityFee();
        community = ICommunityFactory(COMMUNITY_FACTORY).createCommunity{value: createFee}(
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
        uint256 settingsFee = ICommittee(NUTBOX_COMMITTEE).getCommunitySettingsFee();
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        ICommunity(community).adminAddPool{value: settingsFee}(
            "Social Curation",
            ratios,
            SOCIAL_CURATION_FACTORY,
            bytes("")
        );
        pool = ICommunity(community).activedPools(0);

        // 4. Transfer ownership to user
        Ownable(community).transferOwnership(creator);

        emit CommunityCreated(token, community, pool, creator, calculator);
    }

    receive() external payable {}
}
