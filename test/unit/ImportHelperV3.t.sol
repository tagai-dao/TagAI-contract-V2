// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../../src/helper/ImportHelperV3.sol";
import "./ImportHelperV2.t.sol";
import "./AgentSwapWrapper.t.sol";

contract ImportV3RefundReentry {
    ImportHelperV3 private immutable _helper;
    address private immutable _token;
    uint256 public blocked;

    constructor(ImportHelperV3 helper_, address token_) {
        _helper = helper_;
        _token = token_;
    }

    receive() external payable {
        ImportHelperV2.PoolConfig[] memory empty = new ImportHelperV2.PoolConfig[](0);
        bytes[7] memory calls = [
            abi.encodeCall(ImportHelperV3.setNutboxMarket, (_token, address(this), address(this), 100)),
            abi.encodeCall(ImportHelperV3.setTokenNutboxFee, (_token, 100)),
            abi.encodeCall(ImportHelperV3.registerImportedToken, (_token, address(this), address(this))),
            abi.encodeCall(ImportHelperV3.updateImportedMarket, (_token, address(this), address(this))),
            abi.encodeCall(ImportHelperV3.syncAgentMarket, (_token)),
            abi.encodeCall(ImportHelperV2.createCommunityAndPool, (_token, address(0))),
            abi.encodeCall(ImportHelperV2.createCommunityAndPools, (_token, empty))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(_helper).call(calls[i]);
            require(
                !ok
                    && keccak256(reason)
                        == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")),
                "unguarded callback"
            );
            ++blocked;
        }
    }
}

/// @dev Real helpers, wrappers, CommunityFactory, calculator and reward pool factories.
///      Only DEX pricing and Handle registry are deterministic local fixtures.
contract ImportHelperV3Test is Test {
    address private constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address private constant MANAGER = 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611;
    Committee private committee;
    CommunityFactory private factory;
    HourlyTickCalculator private calculator;
    TradeCurationFactory private tradeFactory;
    ImportedTokenSwapWrapper private ordinary;
    AgentSwapWrapper private agent;
    ImportHelperV3 private helper;
    ImportedTestToken private token;
    ImportedTestWrappedNative private wrapped;
    ImportedCoreRouterMock private core;
    ImportedV2RouterMock private dex;
    IPShare private shares;
    address private creator;
    address private fees;
    uint256 private createFee;
    uint256 private settingsFee;

    function setUp() public {
        vm.etch(REGISTRY, type(AgentHandleRegistryMock).runtimeCode);
        creator = makeAddr("creator");
        fees = makeAddr("fees");
        committee = new Committee(payable(fees));
        factory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(factory));
        tradeFactory = new TradeCurationFactory(address(factory), makeAddr("signer"));
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(tradeFactory));
        createFee = committee.getCreateCommunityFee();
        settingsFee = committee.getCommunitySettingsFee();
        wrapped = new ImportedTestWrappedNative();
        dex = new ImportedV2RouterMock();
        core = new ImportedCoreRouterMock(
            address(wrapped), address(new ImportedV3RouterMock()), address(new ImportedV3FactoryMock())
        );
        shares = new IPShare(payable(fees));
        ordinary = new ImportedTokenSwapWrapper(address(core), fees, address(shares));
        agent = new AgentSwapWrapper(address(core), fees, address(shares));
        helper = _newHelper(address(ordinary), address(agent), MANAGER);
        ordinary.setRegistrar(address(helper));
        agent.setOperator(address(helper));
        token = new ImportedTestToken("Imported", "IMP");
        vm.deal(creator, 100 ether);
    }

    function _newHelper(address normal, address agentTarget, address manager) private returns (ImportHelperV3) {
        return new ImportHelperV3(
            address(factory),
            address(tradeFactory),
            address(committee),
            address(calculator),
            normal,
            agentTarget,
            manager
        );
    }

    function _fee(uint256 count) private view returns (uint256) {
        return createFee + settingsFee * count;
    }

    function _import(uint256 excess) private returns (address community, address pool) {
        vm.prank(creator);
        return helper.createCommunityAndPool{value: _fee(1) + excess}(address(token), address(0));
    }

    function _assertMarket(IImportedTokenMarketRegistrar wrapper, address community) private view {
        (bool registered, address storedCommunity, address deployer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(storedCommunity, community);
        assertEq(deployer, creator);
    }

    function _unboundCommunity() private returns (address) {
        return address(new AgentCommunityMock(address(token), address(calculator)));
    }

    function test_importRegistersTheSameRealCommunityInBothWrappersAndDoesNotEnableAgentFees() public {
        uint256 balanceBefore = creator.balance;
        (address community, address pool) = _import(0.1 ether);
        _assertMarket(IImportedTokenMarketRegistrar(address(ordinary)), community);
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), community);
        assertTrue(factory.createdCommunity(community));
        assertEq(Community(payable(community)).owner(), creator);
        assertEq(Community(payable(community)).getCommunityToken(), address(token));
        assertEq(Community(payable(community)).rewardCalculator(), address(calculator));
        assertEq(Community(payable(community)).activedPools(0), pool);
        assertEq(TradeCuration(payable(pool)).factory(), address(tradeFactory));
        assertEq(balanceBefore - creator.balance, _fee(1));
        assertEq(address(helper).balance, 0);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
        assertEq(helper.VERSION(), 3);
        assertEq(helper.owner(), address(this));
        assertEq(helper.managementOperator(), MANAGER);
        // Creating a community is public; it neither requires a Handle nor creates IPShare.
        assertFalse(shares.ipshareCreated(creator));
    }

    function test_explicitMultiplePoolsAlsoRegisterBothWrappersOnce() public {
        SocialCurationFactory social = new SocialCurationFactory(address(factory), makeAddr("socialSigner"));
        committee.adminAddContract(address(social));
        helper.adminSetPoolFactory(address(social), "Social", 5000, true);
        ImportHelperV2.PoolConfig[] memory configs = new ImportHelperV2.PoolConfig[](2);
        configs[0] = ImportHelperV2.PoolConfig(address(tradeFactory), 7000, bytes(""));
        configs[1] = ImportHelperV2.PoolConfig(address(social), 3000, bytes(""));
        vm.prank(creator);
        (address community, address[] memory pools) =
            helper.createCommunityAndPools{value: _fee(2)}(address(token), configs);
        assertEq(pools.length, 2);
        _assertMarket(IImportedTokenMarketRegistrar(address(ordinary)), community);
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), community);
    }

    function test_eitherMissingActivationRollsBackBothRegistrationsCommunityAndFees() public {
        uint256 beforeCreator = creator.balance;
        uint256 beforeFees = fees.balance;
        uint64 factoryNonce = vm.getNonce(address(factory));
        address predictedCommunity = vm.computeCreateAddress(address(factory), factoryNonce);
        agent.setOperator(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.UnauthorizedOperator.selector, address(helper)));
        _import(0);
        (bool registered,,) = ordinary.getImportedMarket(address(token));
        assertFalse(registered);
        (registered,,) = agent.getImportedMarket(address(token));
        assertFalse(registered);
        assertEq(creator.balance, beforeCreator);
        assertEq(fees.balance, beforeFees);
        assertEq(vm.getNonce(address(factory)), factoryNonce);
        assertFalse(factory.createdCommunity(predictedCommunity));
        assertEq(predictedCommunity.code.length, 0);
        // A second attempt succeeds with the same token after activation.
        agent.setOperator(address(helper));
        ordinary.setRegistrar(address(0));
        vm.expectRevert(ImportedTokenSwapWrapper.UnauthorizedRegistrar.selector);
        _import(0);
        assertEq(creator.balance, beforeCreator);
        assertEq(fees.balance, beforeFees);
        ordinary.setRegistrar(address(helper));
        _import(0);
    }

    function test_duplicateInEitherWrapperRefusesNewCommunityBeforeSpendingFees() public {
        address community = _unboundCommunity();
        agent.registerImportedToken(address(token), community, creator);
        uint256 beforeFees = fees.balance;
        vm.expectRevert(ImportHelperV2.TokenAlreadyImported.selector);
        _import(0);
        assertEq(fees.balance, beforeFees);
        ImportedTestToken next = new ImportedTestToken("Next", "NEXT");
        ordinary.registerImportedToken(address(next), community, creator);
        vm.prank(creator);
        vm.expectRevert(ImportHelperV2.TokenAlreadyImported.selector);
        helper.createCommunityAndPool{value: _fee(1)}(address(next), address(0));
        assertEq(fees.balance, beforeFees);
    }

    function test_currentWalletCanManageAllAgentBindingAndFeeMethodsWithoutOwnerAccess() public {
        address first = _unboundCommunity();
        address second = _unboundCommunity();
        vm.startPrank(MANAGER);
        helper.registerImportedToken(address(token), first, creator);
        helper.setTokenNutboxFee(address(token), 20);
        helper.updateImportedMarket(address(token), second, creator);
        helper.setNutboxMarket(address(token), first, creator, 40);
        vm.stopPrank();
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), first);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 40);
        (bool registered,,) = ordinary.getImportedMarket(address(token));
        assertFalse(registered);
        // The EOA now uses Helper; its old direct Agent operator permission is not duplicated.
        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.UnauthorizedOperator.selector, MANAGER));
        agent.setTokenNutboxFee(address(token), 0);
        helper.setTokenNutboxFee(address(token), 0);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
    }

    function test_strangersAndImportCreatorsCannotConfigureBindingsOrFeesOrSynchronizeHistory() public {
        bytes memory reason = abi.encodeWithSelector(ImportHelperV3.UnauthorizedManagementOperator.selector, creator);
        vm.startPrank(creator);
        vm.expectRevert(reason);
        helper.setNutboxMarket(address(token), address(1), creator, 20);
        vm.expectRevert(reason);
        helper.setTokenNutboxFee(address(token), 20);
        vm.expectRevert(reason);
        helper.registerImportedToken(address(token), address(1), creator);
        vm.expectRevert(reason);
        helper.updateImportedMarket(address(token), address(1), creator);
        vm.expectRevert(reason);
        helper.syncAgentMarket(address(token));
        vm.stopPrank();
    }

    function test_managerReplacementRevocationAndOwnershipTransferPreserveOwnerControl() public {
        address first = _unboundCommunity();
        helper.registerImportedToken(address(token), first, creator);
        vm.startPrank(MANAGER);
        vm.expectRevert("Ownable: caller is not the owner");
        helper.setManagementOperator(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        helper.adminSetPoolFactory(address(tradeFactory), "Renamed", 10000, true);
        vm.expectRevert("Ownable: caller is not the owner");
        helper.transferOwnership(creator);
        vm.stopPrank();
        helper.setManagementOperator(creator);
        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(ImportHelperV3.UnauthorizedManagementOperator.selector, MANAGER));
        helper.setTokenNutboxFee(address(token), 20);
        vm.prank(creator);
        helper.setTokenNutboxFee(address(token), 20);
        helper.transferOwnership(creator);
        vm.prank(creator);
        helper.acceptOwnership();
        vm.prank(creator);
        helper.setManagementOperator(address(0));
        assertEq(helper.managementOperator(), address(0));
        vm.prank(creator);
        helper.setTokenNutboxFee(address(token), 0);
        vm.expectRevert(abi.encodeWithSelector(ImportHelperV3.UnauthorizedManagementOperator.selector, address(this)));
        helper.setTokenNutboxFee(address(token), 20);
    }

    function test_historicalSyncUsesExistingCommunityDoesNotChargeOrResetExistingFeeAndIsIdempotent() public {
        address community = _unboundCommunity();
        ordinary.registerImportedToken(address(token), community, creator);
        uint256 beforeFees = fees.balance;
        vm.prank(MANAGER);
        helper.syncAgentMarket(address(token));
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), community);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
        helper.setTokenNutboxFee(address(token), 37);
        vm.prank(MANAGER);
        helper.syncAgentMarket(address(token));
        assertEq(agent.tokenNutboxFeeBps(address(token)), 37);
        assertEq(fees.balance, beforeFees);
    }

    function test_historicalSyncRefusesMissingLegacyAndConflictingAgentCommunityOrCreator() public {
        vm.expectRevert(abi.encodeWithSelector(ImportHelperV3.LegacyMarketNotRegistered.selector, address(token)));
        helper.syncAgentMarket(address(token));
        address community = _unboundCommunity();
        ordinary.registerImportedToken(address(token), community, creator);
        helper.registerImportedToken(address(token), _unboundCommunity(), creator);
        vm.expectRevert(abi.encodeWithSelector(ImportHelperV3.AgentMarketConflict.selector, address(token)));
        helper.syncAgentMarket(address(token));
        helper.updateImportedMarket(address(token), community, MANAGER);
        vm.expectRevert(abi.encodeWithSelector(ImportHelperV3.AgentMarketConflict.selector, address(token)));
        helper.syncAgentMarket(address(token));
    }

    function test_underlyingCommunityFeeAndPendingRewardProtectionsRemainEnforced() public {
        (address community,) = _import(0);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        helper.setTokenNutboxFee(address(token), 2001);
        ImportedTestToken foreign = new ImportedTestToken("Foreign", "FOR");
        address wrongCommunity = address(new AgentCommunityMock(address(foreign), address(calculator)));
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        helper.setNutboxMarket(address(token), wrongCommunity, creator, 20);
        helper.setTokenNutboxFee(address(token), 20);

        ImportedV2FactoryMock v2Factory = new ImportedV2FactoryMock();
        ImportedV2PairMock pair = new ImportedV2PairMock(address(v2Factory), address(token), address(wrapped));
        v2Factory.setPair(address(token), address(wrapped), address(pair));
        core.setV2(address(v2Factory), address(dex), true);
        bytes memory source = abi.encode(ImportedTokenSwapWrapper.V2Source(address(dex), address(pair)));
        AgentHandleRegistryMock(REGISTRY).setHandle(creator, "creator");
        vm.prank(creator);
        agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, 1, creator, block.timestamp + 1, creator
        );
        uint256 pending = agent.pendingNutboxInjection(address(token));
        assertGt(pending, 0);
        address replacementCommunity = _unboundCommunity();
        vm.expectRevert(
            abi.encodeWithSelector(
                ImportedTokenSwapWrapper.PendingNutboxInjectionExists.selector, address(token), pending
            )
        );
        helper.updateImportedMarket(address(token), replacementCommunity, creator);
        helper.setTokenNutboxFee(address(token), 0);
        helper.syncAgentMarket(address(token));
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), community);
    }

    function test_constructorRejectsSameWrapperInvalidTargetManagerAndOwnerMismatch() public {
        vm.expectRevert(ImportHelperV3.InvalidWrapperConfiguration.selector);
        _newHelper(address(ordinary), address(ordinary), MANAGER);
        vm.expectRevert(ImportHelperV3.InvalidWrapperConfiguration.selector);
        _newHelper(address(ordinary), address(0), MANAGER);
        vm.expectRevert(ImportHelperV3.InvalidWrapperConfiguration.selector);
        _newHelper(address(ordinary), address(agent), address(0));
        agent.transferOwnership(creator);
        vm.prank(creator);
        agent.acceptOwnership();
        vm.expectRevert(ImportHelperV3.InvalidWrapperConfiguration.selector);
        _newHelper(address(ordinary), address(agent), MANAGER);
    }

    function test_refundFailureRevertsBothRegistrationsAndFees() public {
        ImportedRejectNative rejector = new ImportedRejectNative();
        vm.deal(address(rejector), _fee(1) + 1);
        uint256 beforeFees = fees.balance;
        vm.prank(address(rejector));
        vm.expectRevert();
        helper.createCommunityAndPool{value: _fee(1) + 1}(address(token), address(0));
        (bool registered,,) = ordinary.getImportedMarket(address(token));
        assertFalse(registered);
        (registered,,) = agent.getImportedMarket(address(token));
        assertFalse(registered);
        assertEq(fees.balance, beforeFees);
    }

    function test_refundCallbackCannotReenterImportOrAnyAgentManagementMethodEvenAsManager() public {
        ImportV3RefundReentry receiver = new ImportV3RefundReentry(helper, address(token));
        helper.setManagementOperator(address(receiver));
        vm.deal(address(receiver), _fee(1) + 1);
        vm.prank(address(receiver));
        (address community,) = helper.createCommunityAndPool{value: _fee(1) + 1}(address(token), address(0));
        assertEq(receiver.blocked(), 7);
        assertEq(Community(payable(community)).owner(), address(receiver));
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
        assertEq(address(receiver).balance, 1);
        assertEq(address(helper).balance, 0);
    }

    function testFuzz_importExcessRefundKeepsBothBindingsAndZeroAgentFee(uint96 excess) public {
        vm.deal(creator, _fee(1) + uint256(excess));
        (address community,) = _import(uint256(excess));
        assertEq(creator.balance, excess);
        _assertMarket(IImportedTokenMarketRegistrar(address(ordinary)), community);
        _assertMarket(IImportedTokenMarketRegistrar(address(agent)), community);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
    }
}
