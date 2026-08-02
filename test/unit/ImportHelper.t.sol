// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/helper/ImportHelper.sol";
import "../../src/pump/IPShare.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import "../../src/nutbox/dapps/ai-channel/AIChannelPoolFactory.sol";
import "../../src/interfaces/IIPShare.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Non-mintable ERC20 with pre-minted supply for import tests.
contract ImportTestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @title ImportHelperTest
/// @notice Local unit tests for ImportHelper IPShare gate + importerOf recording.
contract ImportHelperTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    SocialCurationFactory public scf;
    AIChannelPoolFactory public aiChannelFactory;
    IPShare public ipshare;
    ImportHelper public helper;
    ImportTestERC20 public token;

    address public feeRecipient;
    address public claimSigner;
    address public creator;

    uint256 internal constant CREATE_COMMUNITY_FEE = 0.001 ether;
    uint256 internal constant SETTINGS_FEE = 0.001 ether;
    uint256 internal constant IPSHARE_CREATE_FEE = 0.01 ether;

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");
        creator = makeAddr("creator");

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(CREATE_COMMUNITY_FEE);
        committee.adminSetCommunitySettingsFee(SETTINGS_FEE);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        scf = new SocialCurationFactory(address(communityFactory), claimSigner);
        aiChannelFactory = new AIChannelPoolFactory(address(communityFactory), claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(scf));
        committee.adminAddContract(address(aiChannelFactory));

        ipshare = new IPShare(feeRecipient);
        ipshare.adminSetCreateFee(IPSHARE_CREATE_FEE);
        ipshare.adminStartTrade();

        helper = new ImportHelper(
            address(communityFactory), address(scf), address(aiChannelFactory), address(committee), address(ipshare)
        );

        token = new ImportTestERC20("ImportToken", "IMP", 1_000_000 ether);
    }

    function test_createCommunityAndPool_revertsInsufficientFeeWithoutIPShare() public {
        uint256 nutboxFees = CREATE_COMMUNITY_FEE + (SETTINGS_FEE * 2);
        uint256 totalRequired = IPSHARE_CREATE_FEE + nutboxFees;

        vm.deal(creator, totalRequired);
        vm.prank(creator, creator);
        vm.expectRevert(ImportHelper.InsufficientFee.selector);
        helper.createCommunityAndPool{value: totalRequired - 1}(address(token), address(calculator), bytes(""));
    }

    function test_createCommunityAndPool_createsIPShareAndRecordsImporter() public {
        uint256 nutboxFees = CREATE_COMMUNITY_FEE + (SETTINGS_FEE * 2);
        uint256 totalRequired = IPSHARE_CREATE_FEE + nutboxFees;
        uint256 dust = 0.005 ether;

        assertFalse(IIPShare(address(ipshare)).ipshareCreated(creator));

        vm.deal(creator, totalRequired + dust);
        uint256 balanceBefore = creator.balance;

        vm.prank(creator, creator);
        (address community, address pool) =
            helper.createCommunityAndPool{value: totalRequired + dust}(address(token), address(calculator), bytes(""));

        assertTrue(community != address(0));
        assertTrue(pool != address(0));
        assertTrue(IIPShare(address(ipshare)).ipshareCreated(creator));
        assertEq(helper.importerOf(address(token)), creator);
        assertEq(Community(payable(community)).activedPools(1) != address(0), true);
        assertEq(Community(payable(community)).poolRatios(pool), 5000);
        assertEq(Community(payable(community)).poolRatios(Community(payable(community)).activedPools(1)), 5000);

        // Dust above required fees should be refunded to the creator.
        assertEq(creator.balance, balanceBefore - totalRequired);
    }
}
