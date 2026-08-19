// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/helper/ImportHelper.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";

contract ImportHelperTestToken is ERC20 {
    constructor() ERC20("Imported", "IMPORTED") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract ImportHelperRegistrarMock is IImportedTokenMarketRegistrar {
    address public token;
    address public community;
    address public deployer;
    bool public registered;

    function registerImportedToken(address token_, address community_, address deployer_) external {
        token = token_;
        community = community_;
        deployer = deployer_;
        registered = true;
    }

    function getImportedMarket(address token_)
        external
        view
        returns (bool isRegistered, address storedCommunity, address storedDeployer)
    {
        if (token_ != token) return (false, address(0), address(0));
        return (registered, community, deployer);
    }
}

contract ImportHelperTest is Test {
    bytes32 private constant DEV_CHANGED_TOPIC = keccak256("DevChanged(address,address)");

    Committee private committee;
    CommunityFactory private communityFactory;
    HourlyTickCalculator private calculator;
    SocialCurationFactory private socialCurationFactory;
    ImportHelperRegistrarMock private registrar;
    ImportHelper private helper;
    ImportHelperTestToken private token;

    address private creator;
    address private feeRecipient;

    function setUp() public {
        creator = makeAddr("creator");
        feeRecipient = makeAddr("feeRecipient");
        committee = new Committee(payable(feeRecipient));
        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        socialCurationFactory = new SocialCurationFactory(address(communityFactory), makeAddr("claimSigner"));
        registrar = new ImportHelperRegistrarMock();
        token = new ImportHelperTestToken();

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(socialCurationFactory));

        helper = new ImportHelper(
            address(communityFactory),
            address(socialCurationFactory),
            address(committee),
            address(calculator),
            address(registrar)
        );
        vm.deal(creator, 10 ether);
    }

    function test_importUsesFixedCalculatorSetsDevAndRegistersCommunity() public {
        uint256 totalFee = committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
        uint256 creatorBalanceBefore = creator.balance;

        vm.recordLogs();
        vm.prank(creator);
        (address communityAddress, address pool) =
            helper.createCommunityAndPool{value: totalFee + 0.1 ether}(address(token), address(0));

        Community community = Community(payable(communityAddress));
        assertEq(community.owner(), creator);
        assertEq(community.rewardCalculator(), address(calculator));
        assertEq(community.getCommunityToken(), address(token));
        assertEq(community.activedPools(0), pool);
        assertTrue(community.poolActived(pool));
        assertTrue(calculator.registered(communityAddress));
        assertEq(creatorBalanceBefore - creator.balance, totalFee);

        assertEq(registrar.token(), address(token));
        assertEq(registrar.community(), communityAddress);
        assertEq(registrar.deployer(), creator);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundCreatorDev;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != communityAddress || logs[i].topics.length != 3) continue;
            if (logs[i].topics[0] != DEV_CHANGED_TOPIC) continue;
            address newDev = address(uint160(uint256(logs[i].topics[2])));
            if (newDev == creator) foundCreatorDev = true;
        }
        assertTrue(foundCreatorDev);
    }

    function test_importRejectsInsufficientCombinedFee() public {
        uint256 totalFee = committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
        vm.prank(creator);
        vm.expectRevert(ImportHelper.InsufficientFee.selector);
        helper.createCommunityAndPool{value: totalFee - 1}(address(token), address(0));
    }

    function test_importRejectsTokenAlreadyBoundInWrapperBeforeCreatingCommunity() public {
        address boundCommunity = makeAddr("boundCommunity");
        registrar.registerImportedToken(address(token), boundCommunity, makeAddr("originalDeployer"));
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        vm.expectRevert(ImportHelper.TokenAlreadyImported.selector);
        helper.createCommunityAndPool{value: 1 ether}(address(token), address(0));

        assertEq(creator.balance, creatorBalanceBefore);
        assertEq(registrar.community(), boundCommunity);
    }

    function test_importCanReuseValidCommunityWithoutCreatingPoolOrChargingFee() public {
        address existingCommunity = _createCommunity(address(token), address(calculator));
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        (address communityAddress, address pool) =
            helper.createCommunityAndPool{value: 0.1 ether}(address(token), existingCommunity);

        assertEq(communityAddress, existingCommunity);
        assertEq(pool, address(0));
        assertEq(creator.balance, creatorBalanceBefore);
        assertEq(registrar.token(), address(token));
        assertEq(registrar.community(), existingCommunity);
        assertEq(registrar.deployer(), creator);
    }

    function test_importRejectsCommunityFromAnotherFactory() public {
        CommunityFactory otherFactory = new CommunityFactory(address(committee));
        HourlyTickCalculator otherCalculator = new HourlyTickCalculator(address(otherFactory));
        committee.adminAddContract(address(otherCalculator));
        uint256 createFee = committee.getCreateCommunityFee();
        vm.prank(creator);
        address foreignCommunity = otherFactory.createCommunity{value: createFee}(
            false, address(token), address(0), bytes(""), address(otherCalculator), bytes("")
        );

        vm.prank(creator);
        vm.expectRevert(ImportHelper.InvalidCommunity.selector);
        helper.createCommunityAndPool(address(token), foreignCommunity);
    }

    function test_importRejectsCommunityUsingDifferentRewardCalculator() public {
        HourlyTickCalculator otherCalculator = new HourlyTickCalculator(address(communityFactory));
        committee.adminAddContract(address(otherCalculator));
        address existingCommunity = _createCommunity(address(token), address(otherCalculator));

        vm.prank(creator);
        vm.expectRevert(ImportHelper.InvalidRewardCalculator.selector);
        helper.createCommunityAndPool(address(token), existingCommunity);
    }

    function test_importRejectsCommunityBoundToDifferentToken() public {
        ImportHelperTestToken otherToken = new ImportHelperTestToken();
        address existingCommunity = _createCommunity(address(otherToken), address(calculator));

        vm.prank(creator);
        vm.expectRevert(ImportHelper.InvalidCommunity.selector);
        helper.createCommunityAndPool(address(token), existingCommunity);
    }

    function _createCommunity(address communityToken, address rewardCalculator) private returns (address community) {
        uint256 createFee = committee.getCreateCommunityFee();
        vm.prank(creator);
        community = communityFactory.createCommunity{value: createFee}(
            false, communityToken, address(0), bytes(""), rewardCalculator, bytes("")
        );
    }
}
