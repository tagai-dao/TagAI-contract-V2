// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../nutbox/Community.sol";

interface IImportedTokenMarketRegistrar {
    function registerImportedToken(address token, address community, address deployer) external;

    function getImportedMarket(address token)
        external
        view
        returns (bool registered, address community, address deployer);
}

/// @title ImportHelper
/// @notice Creates an external-token Nutbox Community and its SocialCuration pool, then binds the
///         token to that Community in ImportedTokenSwapWrapper.
contract ImportHelper {
    using Address for address payable;

    address public immutable communityFactory;
    address public immutable socialCurationFactory;
    address public immutable committee;
    address public immutable hourlyTickCalculator;
    IImportedTokenMarketRegistrar public immutable swapWrapper;

    event CommunityCreated(
        address indexed token, address indexed community, address indexed pool, address creator, address calculator
    );
    event ImportedCommunityRecorded(address indexed token, address indexed community, address indexed creator);

    error InvalidAddress();
    error InvalidToken();
    error InvalidCommunity();
    error InvalidRewardCalculator();
    error TokenAlreadyImported();
    error InsufficientFee();

    constructor(
        address communityFactory_,
        address socialCurationFactory_,
        address committee_,
        address hourlyTickCalculator_,
        address swapWrapper_
    ) {
        if (
            communityFactory_.code.length == 0 || socialCurationFactory_.code.length == 0 || committee_.code.length == 0
                || hourlyTickCalculator_.code.length == 0 || swapWrapper_.code.length == 0
        ) revert InvalidAddress();
        communityFactory = communityFactory_;
        socialCurationFactory = socialCurationFactory_;
        committee = committee_;
        hourlyTickCalculator = hourlyTickCalculator_;
        swapWrapper = IImportedTokenMarketRegistrar(swapWrapper_);
    }

    /// @notice Imports an ERC20 and binds it to a new or existing Nutbox Community in the Wrapper.
    /// @param token ERC20 token being imported.
    /// @param existingCommunity Optional Community created by communityFactory. Use address(0) to create one.
    function createCommunityAndPool(address token, address existingCommunity)
        external
        payable
        returns (address community, address pool)
    {
        if (token.code.length == 0) revert InvalidToken();
        (bool registered,,) = swapWrapper.getImportedMarket(token);
        if (registered) revert TokenAlreadyImported();
        address creator = msg.sender;

        if (existingCommunity != address(0)) {
            _validateExistingCommunity(token, existingCommunity);
            swapWrapper.registerImportedToken(token, existingCommunity, creator);
            if (msg.value != 0) payable(creator).sendValue(msg.value);
            emit ImportedCommunityRecorded(token, existingCommunity, creator);
            return (existingCommunity, address(0));
        }

        uint256 createFee = ICommittee(committee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(committee).getCommunitySettingsFee();
        uint256 totalFee = createFee + settingsFee;
        if (msg.value < totalFee) revert InsufficientFee();

        community = ICommunityFactory(communityFactory).createCommunity{value: createFee}(
            false, token, address(0), bytes(""), hourlyTickCalculator, bytes("")
        );

        // Community is initially owned by this helper, so devFund is set before ownership transfer.
        Community(community).adminSetDev(creator);

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        ICommunity(community).adminAddPool{value: settingsFee}(
            "Social Curation", ratios, socialCurationFactory, bytes("")
        );
        pool = ICommunity(community).activedPools(0);

        swapWrapper.registerImportedToken(token, community, creator);
        Ownable(community).transferOwnership(creator);

        if (msg.value > totalFee) payable(creator).sendValue(msg.value - totalFee);

        emit CommunityCreated(token, community, pool, creator, hourlyTickCalculator);
        emit ImportedCommunityRecorded(token, community, creator);
    }

    function _validateExistingCommunity(address token, address community) internal view {
        if (community.code.length == 0 || !ICommunityFactory(communityFactory).createdCommunity(community)) {
            revert InvalidCommunity();
        }
        if (ICommunity(community).getCommunityToken() != token) revert InvalidCommunity();
        if (ICommunity(community).rewardCalculator() != hourlyTickCalculator) revert InvalidRewardCalculator();
    }

    receive() external payable {}
}
