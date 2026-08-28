// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/helper/ImportHelper.sol";
import "../../src/helper/TagAISwapWrapper.sol";
import "../../src/pump/IPShare.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import "../../src/interfaces/IIPShare.sol";
import "../../src/interfaces/ICommunity.sol";
import "../../src/interfaces/ICommunityFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Non-mintable ERC20 with pre-minted supply for import tests.
contract ImportTestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @dev Mock Pump：仅 createdTokens 拒绝用。
contract MockPump {
    mapping(address => bool) public createdTokens;
    function markCreated(address t) external { createdTokens[t] = true; }
}

/// @dev 真实 TagAISwapWrapper 作为 registrar（同时验证登记回路）。
contract ImportHelperTest is Test {
    Committee public committee;
    CommunityFactory public communityFactory;
    HourlyTickCalculator public calculator;
    SocialCurationFactory public scf;
    IPShare public ipshare;
    ImportHelper public helper;
    TagAISwapWrapper public wrapper;
    MockPump public pump;

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

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(scf));

        ipshare = new IPShare(feeRecipient);
        ipshare.adminSetCreateFee(IPSHARE_CREATE_FEE);
        ipshare.adminStartTrade();

        pump = new MockPump();

        // Wrapper 先部署（importHelper 暂置 0），Helper 构造传入 pump + wrapper，再回填。
        wrapper = new TagAISwapWrapper(address(0), address(ipshare), makeAddr("weth"), feeRecipient);
        helper = new ImportHelper(
            address(communityFactory),
            address(scf),
            address(committee),
            address(ipshare),
            address(pump),
            address(wrapper)
        );
        wrapper.adminSetImportHelper(address(helper));

        token = new ImportTestERC20("ImportToken", "IMP", 1_000_000 ether);
    }

    function _totalRequired() internal view returns (uint256) {
        return IPSHARE_CREATE_FEE + CREATE_COMMUNITY_FEE + SETTINGS_FEE;
    }

    function test_createCommunityAndPool_revertsInsufficientFeeWithoutIPShare() public {
        uint256 totalRequired = _totalRequired();
        vm.deal(creator, totalRequired);
        vm.prank(creator, creator);
        vm.expectRevert(ImportHelper.InsufficientFee.selector);
        helper.createCommunityAndPool{value: totalRequired - 1}(address(token), address(calculator), bytes(""));
    }

    function test_createCommunityAndPool_createsIPShareAndRecordsImporter() public {
        uint256 totalRequired = _totalRequired();
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
        // Wrapper 登记
        (bool registered, address regCommunity, address regDeployer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(regCommunity, community);
        assertEq(regDeployer, creator);
        // Dust 退还
        assertEq(creator.balance, balanceBefore - totalRequired);
    }

    /// @dev 同一 token 第二次导入 revert TokenAlreadyImported。
    function test_createCommunityAndPool_revertsIfAlreadyImported() public {
        uint256 totalRequired = _totalRequired();
        vm.deal(creator, totalRequired);
        vm.prank(creator, creator);
        helper.createCommunityAndPool{value: totalRequired}(address(token), address(calculator), bytes(""));

        vm.deal(creator, totalRequired);
        vm.prank(creator, creator);
        vm.expectRevert(ImportHelper.TokenAlreadyImported.selector);
        helper.createCommunityAndPool{value: totalRequired}(address(token), address(calculator), bytes(""));
    }

    /// @dev Pump 创建的代币不可导入。
    function test_createCommunityAndPool_revertsIfPumpToken() public {
        pump.markCreated(address(token));
        uint256 totalRequired = _totalRequired();
        vm.deal(creator, totalRequired);
        vm.prank(creator, creator);
        vm.expectRevert(ImportHelper.PumpTokenNotImportable.selector);
        helper.createCommunityAndPool{value: totalRequired}(address(token), address(calculator), bytes(""));
    }

    /// @dev 复用已有 Community：community 由 CommunityFactory 直接创建（token=tokenA），Helper 仅登记，不新建、devFund 不变、不收 Community 费。
    function test_createCommunityAndPool_reusesExistingCommunity() public {
        // 直接经 CommunityFactory 建一个 community（绕过 Helper，故未登记）
        uint256 createFee = CREATE_COMMUNITY_FEE;
        uint256 settingsFee = SETTINGS_FEE;
        vm.deal(creator, createFee + settingsFee);
        vm.startPrank(creator, creator);
        address community = ICommunityFactory(address(communityFactory)).createCommunity{value: createFee}(
            false, address(token), address(0), bytes(""), address(calculator), bytes("")
        );
        Community(payable(community)).adminSetDev(creator);
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        ICommunity(community).adminAddPool{value: settingsFee}("SC", ratios, address(scf), bytes(""));
        Ownable(community).transferOwnership(creator);
        vm.stopPrank();

        address devFundBefore = Community(payable(community)).devFund();
        assertEq(devFundBefore, creator);

        // 复用该 community 导入同一 token。creator 此前未建 IPShare → 收 0.01 ETH IPShare 费，Community 费全额退回。
        bool needIp = !IIPShare(address(ipshare)).ipshareCreated(creator);
        uint256 expectedFee = needIp ? IPSHARE_CREATE_FEE : 0;
        vm.deal(creator, 1 ether);
        uint256 balBefore = creator.balance;

        vm.prank(creator, creator);
        (address c2, address pool2) = helper.createCommunityAndPool{value: 1 ether}(
            address(token), address(calculator), bytes(""), community
        );
        assertEq(c2, community, "reused community");
        assertEq(pool2, address(0), "no new pool");
        assertEq(Community(payable(community)).devFund(), creator, "devFund unchanged");
        assertEq(helper.importerOf(address(token)), creator);
        (bool registered,,) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        // 仅扣 IPShare 费（若需建），Community 费全额退回。
        assertEq(creator.balance, balBefore - expectedFee, "only ipshare fee charged");
    }

    /// @dev 错误 calculator 的 existingCommunity revert InvalidRewardCalculator。
    function test_createCommunityAndPool_reusesExistingCommunity_revertsIfCalculatorMismatch() public {
        // 直接建一个用 calculator 的 community
        uint256 createFee = CREATE_COMMUNITY_FEE;
        uint256 settingsFee = SETTINGS_FEE;
        vm.deal(creator, createFee + settingsFee);
        vm.startPrank(creator, creator);
        address community = ICommunityFactory(address(communityFactory)).createCommunity{value: createFee}(
            false, address(token), address(0), bytes(""), address(calculator), bytes("")
        );
        Community(payable(community)).adminSetDev(creator);
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10000;
        ICommunity(community).adminAddPool{value: settingsFee}("SC", ratios, address(scf), bytes(""));
        Ownable(community).transferOwnership(creator);
        vm.stopPrank();

        // 用另一个 calculator 复用 → revert InvalidRewardCalculator
        HourlyTickCalculator calc2 = new HourlyTickCalculator(address(communityFactory));
        committee.adminAddContract(address(calc2));
        vm.deal(creator, 1 ether);
        vm.prank(creator, creator);
        vm.expectRevert(ImportHelper.InvalidRewardCalculator.selector);
        helper.createCommunityAndPool{value: 1 ether}(address(token), address(calc2), bytes(""), community);
    }
}
