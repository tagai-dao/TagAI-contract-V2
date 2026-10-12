// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/helper/ImportHelperV2.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/trade-curation/TradeCurationFactory.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";

contract ImportHelperV2TestToken is ERC20 {
    constructor() ERC20("Imported", "IMPORTED") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract ImportHelperV2RegistrarMock is IImportedTokenMarketRegistrar {
    address public owner = msg.sender;
    address public token;
    address public community;
    address public deployer;
    bool public registered;
    bool public rejectRegistration;

    function setRejectRegistration(bool value) external {
        rejectRegistration = value;
    }

    function registerImportedToken(address token_, address community_, address deployer_) external {
        require(!rejectRegistration, "Registrar rejected");
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

contract ImportHelperV2Test is Test {
    bytes32 private constant DEV_CHANGED_TOPIC = keccak256("DevChanged(address,address)");

    Committee private committee;
    CommunityFactory private communityFactory;
    HourlyTickCalculator private calculator;
    TradeCurationFactory private tradeCurationFactory;
    ImportHelperV2RegistrarMock private registrar;
    ImportHelperV2 private helper;
    ImportHelperV2TestToken private token;

    address private creator;
    address private feeRecipient;

    function setUp() public {
        creator = makeAddr("creator");
        feeRecipient = makeAddr("feeRecipient");
        committee = new Committee(payable(feeRecipient));
        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        tradeCurationFactory = new TradeCurationFactory(address(communityFactory), makeAddr("claimSigner"));
        registrar = new ImportHelperV2RegistrarMock();
        token = new ImportHelperV2TestToken();

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(tradeCurationFactory));

        helper = new ImportHelperV2(
            address(communityFactory),
            address(tradeCurationFactory),
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
        vm.expectRevert();
        community.activedPools(1);
        assertEq(TradeCuration(payable(pool)).factory(), address(tradeCurationFactory));
        assertEq(TradeCuration(payable(pool)).community(), communityAddress);
        assertEq(TradeCuration(payable(pool)).name(), "Trade Curation");
        bytes32 ratioSlot = keccak256(abi.encode(pool, uint256(10)));
        assertEq(uint256(vm.load(communityAddress, ratioSlot)), 10_000);
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
        vm.expectRevert(ImportHelperV2.InsufficientFee.selector);
        helper.createCommunityAndPool{value: totalFee - 1}(address(token), address(0));
    }

    function test_importRejectsTokenAlreadyBoundInWrapperBeforeCreatingCommunity() public {
        address boundCommunity = makeAddr("boundCommunity");
        registrar.registerImportedToken(address(token), boundCommunity, makeAddr("originalDeployer"));
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        vm.expectRevert(ImportHelperV2.TokenAlreadyImported.selector);
        helper.createCommunityAndPool{value: 1 ether}(address(token), address(0));

        assertEq(creator.balance, creatorBalanceBefore);
        assertEq(registrar.community(), boundCommunity);
    }

    function test_rejectsExistingCommunityToGuaranteeTradeOnlyImports() public {
        vm.prank(creator);
        vm.expectRevert(ImportHelperV2.ExistingCommunityUnsupported.selector);
        helper.createCommunityAndPool(address(token), makeAddr("existingCommunity"));
    }

    function test_registrationFailureRollsBackCommunityCreationAndFees() public {
        registrar.setRejectRegistration(true);
        uint256 fee = committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
        uint256 beforeBalance = creator.balance;
        uint256 beforeFees = feeRecipient.balance;
        vm.prank(creator);
        vm.expectRevert(bytes("Registrar rejected"));
        helper.createCommunityAndPool{value: fee}(address(token), address(0));
        assertEq(creator.balance, beforeBalance);
        assertEq(feeRecipient.balance, beforeFees);
        assertEq(address(helper).balance, 0);
        assertFalse(registrar.registered());
    }

    function test_refundFailureRollsBackWholeImport() public {
        address nonReceiver = address(token);
        uint256 fee = committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
        vm.deal(nonReceiver, fee + 1);
        uint256 beforeFees = feeRecipient.balance;
        vm.prank(nonReceiver);
        vm.expectRevert();
        helper.createCommunityAndPool{value: fee + 1}(address(token), address(0));
        assertEq(nonReceiver.balance, fee + 1);
        assertEq(feeRecipient.balance, beforeFees);
        assertFalse(registrar.registered());
    }

    function test_rejectsInvalidToken() public {
        vm.prank(creator);
        vm.expectRevert(ImportHelperV2.InvalidToken.selector);
        helper.createCommunityAndPool(address(0), address(0));
    }

    function test_rejectsFactoryFromAnotherCommunityFactory() public {
        CommunityFactory other = new CommunityFactory(address(committee));
        TradeCurationFactory foreign = new TradeCurationFactory(address(other), makeAddr("signer"));
        vm.expectRevert(ImportHelperV2.InvalidAddress.selector);
        new ImportHelperV2(
            address(communityFactory), address(foreign), address(committee), address(calculator), address(registrar)
        );
    }

    function testFuzz_refundsExcessAndChargesOnlyCreationAndOnePoolSetting(uint96 excess) public {
        uint256 fee = committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
        vm.deal(creator, fee + uint256(excess));
        vm.prank(creator);
        helper.createCommunityAndPool{value: fee + uint256(excess)}(address(token), address(0));
        assertEq(creator.balance, excess);
    }

    function _mixed(uint16 tradeRatio) private returns (ImportHelperV2.PoolConfig[] memory configs) {
        SocialCurationFactory social = new SocialCurationFactory(address(communityFactory), makeAddr("socialSigner"));
        committee.adminAddContract(address(social));
        helper.adminSetPoolFactory(address(social), "Social Curation", 10_000, true);
        configs = new ImportHelperV2.PoolConfig[](2);
        configs[0] = ImportHelperV2.PoolConfig(address(tradeCurationFactory), tradeRatio, bytes(""));
        configs[1] = ImportHelperV2.PoolConfig(address(social), uint16(10_000 - tradeRatio), bytes(""));
    }

    function test_initialOwnerAndDefaultFollowWrapperOwner() public view {
        assertEq(helper.owner(), registrar.owner());
        assertEq(helper.VERSION(), 2);
        ImportHelperV2.PoolConfig[] memory defaults = helper.getDefaultPools();
        assertEq(defaults.length, 1);
        assertEq(defaults[0].factory, address(tradeCurationFactory));
        assertEq(defaults[0].rewardRatio, 10_000);
    }

    function testFuzz_explicitSocialAndTradeSharesHaveExactSum(uint16 ratio) public {
        ratio = uint16(bound(ratio, 1, 9999));
        ImportHelperV2.PoolConfig[] memory configs = _mixed(ratio);
        uint256 fee = committee.getCreateCommunityFee() + 2 * committee.getCommunitySettingsFee();
        uint256 beforeBalance = creator.balance;
        vm.prank(creator);
        (address c, address[] memory pools) = helper.createCommunityAndPools{value: fee + 1}(address(token), configs);
        assertEq(pools.length, 2);
        assertEq(Community(payable(c)).owner(), creator);
        assertEq(TradeCuration(payable(pools[0])).factory(), configs[0].factory);
        assertEq(SocialCuration(payable(pools[1])).factory(), configs[1].factory);
        assertEq(uint256(vm.load(c, keccak256(abi.encode(pools[0], uint256(10))))), ratio);
        assertEq(uint256(vm.load(c, keccak256(abi.encode(pools[1], uint256(10))))), 10_000 - ratio);
        assertEq(beforeBalance - creator.balance, fee);
    }

    function test_ownerCanChangeDefaultForLegacyEntry() public {
        ImportHelperV2.PoolConfig[] memory configs = _mixed(7000);
        helper.adminSetDefaultPools(configs);
        assertEq(helper.defaultPoolCount(), 2);
        uint256 fee = committee.getCreateCommunityFee() + 2 * committee.getCommunitySettingsFee();
        vm.prank(creator);
        (address c, address primary) = helper.createCommunityAndPool{value: fee}(address(token), address(0));
        assertEq(Community(payable(c)).activedPools(0), primary);
        assertEq(uint256(vm.load(c, keccak256(abi.encode(primary, uint256(10))))), 7000);
        assertTrue(Community(payable(c)).poolActived(Community(payable(c)).activedPools(1)));
    }

    function test_onlyOwnerCanConfigureFactoriesOrDefaults() public {
        ImportHelperV2.PoolConfig[] memory configs = _mixed(7000);
        vm.prank(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        helper.adminSetDefaultPools(configs);
        vm.prank(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        helper.adminSetPoolFactory(address(tradeCurationFactory), "Trade", 10_000, true);
    }

    function test_rejectsEmptyDuplicateZeroAndBadTotalSelections() public {
        ImportHelperV2.PoolConfig[] memory empty = new ImportHelperV2.PoolConfig[](0);
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), empty);
        ImportHelperV2.PoolConfig[] memory configs = _mixed(7000);
        configs[1].factory = configs[0].factory;
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        configs = _mixed(7000);
        configs[1].rewardRatio = 2999;
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        configs[1].rewardRatio = 3001;
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        configs[0].rewardRatio = 0;
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
    }

    function test_rechecksFactoryEnablementCapAndCommitteeApproval() public {
        ImportHelperV2.PoolConfig[] memory configs = _mixed(7000);
        helper.adminSetPoolFactory(configs[1].factory, "Social", 2000, true);
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        helper.adminSetPoolFactory(configs[1].factory, "Social", 10_000, false);
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        helper.adminSetPoolFactory(configs[1].factory, "Social", 10_000, true);
        committee.adminRemoveContract(configs[1].factory);
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
    }

    function test_sixPoolsCreateAndSevenAreRejected() public {
        ImportHelperV2.PoolConfig[] memory configs = new ImportHelperV2.PoolConfig[](7);
        for (uint256 i; i < 7; ++i) {
            TradeCurationFactory f = new TradeCurationFactory(address(communityFactory), makeAddr("signer"));
            committee.adminAddContract(address(f));
            helper.adminSetPoolFactory(address(f), "Future pool", 10_000, true);
            configs[i] = ImportHelperV2.PoolConfig(address(f), 1000, bytes(""));
        }
        vm.expectRevert(ImportHelperV2.InvalidPoolConfig.selector);
        helper.createCommunityAndPools(address(token), configs);
        assembly { mstore(configs, 6) }
        configs[5].rewardRatio = 5000;
        uint256 fee = committee.getCreateCommunityFee() + 6 * committee.getCommunitySettingsFee();
        (address c, address[] memory pools) = helper.createCommunityAndPools{value: fee}(address(token), configs);
        assertEq(pools.length, 6);
        assertEq(Community(payable(c)).activedPools(5), pools[5]);
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += uint256(vm.load(c, keccak256(abi.encode(pools[i], uint256(10)))));
        }
        assertEq(sum, 10_000);
    }

    function test_laterPoolFailureRollsBackEarlierPoolsAndFees() public {
        ImportHelperV2.PoolConfig[] memory configs = _mixed(7000);
        TradeCurationFactory later = new TradeCurationFactory(address(communityFactory), makeAddr("laterSigner"));
        committee.adminAddContract(address(later));
        helper.adminSetPoolFactory(address(later), "Later trade", 10_000, true);
        configs[1].factory = address(later);
        configs[1].meta = hex"01"; // The second factory rejects metadata after the first pool has been created.
        uint256 beforeFees = feeRecipient.balance;
        uint256 fee = committee.getCreateCommunityFee() + 2 * committee.getCommunitySettingsFee();
        vm.expectRevert();
        helper.createCommunityAndPools{value: fee}(address(token), configs);
        assertFalse(registrar.registered());
        assertEq(feeRecipient.balance, beforeFees);
    }
}
