// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AgentSwapWrapper} from "../../src/helper/AgentSwapWrapper.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import "./ImportedTokenSwapWrapper.t.sol";

contract AgentHandleRegistryMock {
    mapping(address => string) public handleOf;

    function setHandle(address wallet, string calldata handle) external {
        handleOf[wallet] = handle;
    }
}

contract AgentCommunityMock is ImportedCommunityMock {
    address public immutable getCommunityToken;

    constructor(address token_, address calculator_) ImportedCommunityMock(calculator_) {
        getCommunityToken = token_;
    }
}

contract AgentNoOpIPShare {
    function ipshareCreated(address) external pure returns (bool) {
        return false;
    }

    function createFee() external pure returns (uint256) {
        return 0;
    }
    function createShare(address) external payable {}
}

contract AgentReenteringIPShare {
    mapping(address => bool) public ipshareCreated;
    address public target;
    uint256 public blocked;

    function setTarget(address value) external {
        target = value;
    }

    function createFee() external pure returns (uint256) {
        return 0;
    }

    function createShare(address subject) external payable {
        bytes[2] memory calls = [
            abi.encodeCall(
                ImportedTokenSwapWrapper.buyToken,
                (address(1), INutboxRouter.SourceType.V2_PAIR, bytes(""), 1, subject, block.timestamp, address(0))
            ),
            abi.encodeCall(
                ImportedTokenSwapWrapper.sellToken,
                (address(1), INutboxRouter.SourceType.V2_PAIR, bytes(""), 1, 1, subject, block.timestamp, address(0))
            )
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = target.call(calls[i]);
            require(
                !ok
                    && keccak256(reason)
                        == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")),
                "unguarded callback"
            );
            ++blocked;
        }
        ipshareCreated[subject] = true;
    }
}

contract AgentV4ManagerMock {
    address public immutable vault;
    bytes public lastHookData;

    constructor(address value) {
        vault = value;
    }

    function swap(
        ImportedTestPancakeV4PoolKey calldata,
        ImportedTestPancakeV4CLPoolManager.SwapParams calldata p,
        bytes calldata hookData
    ) external returns (ImportedTestPancakeV4BalanceDelta) {
        lastHookData = hookData;
        int128 input = int128(-p.amountSpecified);
        return p.zeroForOne
            ? toImportedTestPancakeV4BalanceDelta(-input, input * 2)
            : toImportedTestPancakeV4BalanceDelta(input * 2, -input);
    }
}

contract AgentV4QuoterMock {
    function quoteExactInputSingle(IImportedPancakeV4Quoter.QuoteExactInputSingleParams calldata p)
        external
        pure
        returns (uint256, uint256)
    {
        require(abi.decode(p.hookData, (address)) == address(0), "stale referral in quote");
        return (uint256(p.exactAmount) * 2, 0);
    }
}

contract AgentSwapWrapperTest is Test {
    address private constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    ImportedTestToken private token;
    ImportedTestToken private quote;
    ImportedTestWrappedNative private wrapped;
    ImportedV2RouterMock private v2;
    ImportedV3RouterMock private v3;
    ImportedV3QuoterMock private v3Quoter;
    ImportedCoreRouterMock private core;
    IPShare private shares;
    AgentSwapWrapper private agent;
    address private buyer;
    address private seller;
    address private referral;
    address private fees;
    bytes private source;

    function setUp() public {
        vm.etch(REGISTRY, type(AgentHandleRegistryMock).runtimeCode);
        token = new ImportedTestToken("External", "EXT");
        quote = new ImportedTestToken("Quote", "QUOTE");
        wrapped = new ImportedTestWrappedNative();
        v2 = new ImportedV2RouterMock();
        v3 = new ImportedV3RouterMock();
        v3Quoter = new ImportedV3QuoterMock();
        core = new ImportedCoreRouterMock(address(wrapped), address(v3), address(new ImportedV3FactoryMock()));
        fees = makeAddr("platform");
        referral = makeAddr("referral");
        buyer = makeAddr("agentBuyer");
        seller = makeAddr("agentSeller");
        shares = new IPShare(payable(fees));
        agent = new AgentSwapWrapper(address(core), fees, address(shares));
        AgentHandleRegistryMock(REGISTRY).setHandle(buyer, "buyer");
        AgentHandleRegistryMock(REGISTRY).setHandle(seller, "seller");
        source = _v2Source(address(token), address(quote));
        vm.deal(buyer, 100 ether);
        vm.deal(seller, 10 ether);
        vm.deal(address(core), 1_000 ether);
        vm.deal(address(wrapped), 1_000 ether);
        token.mint(seller, 1_000 ether);
        vm.prank(seller);
        token.approve(address(agent), 1_000 ether);
    }

    function _v2Source(address asset, address settlement) private returns (bytes memory) {
        ImportedV2FactoryMock factory = new ImportedV2FactoryMock();
        ImportedV2PairMock pair = new ImportedV2PairMock(address(factory), asset, settlement);
        factory.setPair(asset, settlement, address(pair));
        core.setV2(address(factory), address(v2), true);
        return abi.encode(ImportedTokenSwapWrapper.V2Source(address(v2), address(pair)));
    }

    function _buy(address user, uint256 minimum, address recipient, address subject) private returns (uint256) {
        vm.prank(user);
        return agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, minimum, recipient, block.timestamp + 1, subject
        );
    }

    function _sell(address user, uint256 minimum) private returns (uint256) {
        vm.prank(user);
        uint256 result = agent.sellToken(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            source,
            10 ether,
            minimum,
            user,
            block.timestamp + 1,
            referral
        );
        return result;
    }

    function _assertShare(address user) private view {
        assertTrue(shares.ipshareCreated(user));
        assertEq(shares.ipshareSupply(user), 10 ether);
        assertEq(shares.totalStakedIPshare(user), 10 ether);
        (address holder, uint256 staked) = shares.getMaxStaker(user);
        assertEq(holder, user);
        assertEq(staked, 10 ether);
    }

    function test_buyCreatesOnlyCallerIPShareAndKeepsAllTradePrincipal() public {
        assertEq(_buy(buyer, 1.992 ether, buyer, referral), 1.992 ether);
        _assertShare(buyer);
        assertFalse(shares.ipshareCreated(referral));
        assertFalse(shares.ipshareCreated(fees));
        assertFalse(shares.ipshareCreated(address(agent)));
        assertFalse(shares.ipshareCreated(address(0)));
        assertEq(fees.balance, 0.002 ether);
        assertEq(referral.balance, 0.002 ether);
        assertEq(token.balanceOf(buyer), 1.992 ether);
        assertEq(address(agent).balance, 0);
        assertEq(token.balanceOf(address(agent)), 0);
    }

    function test_sellCreatesCallerShareAndPreservesNetNativeAmount() public {
        uint256 beforeBalance = seller.balance;
        assertEq(_sell(seller, 19.92 ether), 19.92 ether);
        _assertShare(seller);
        assertEq(seller.balance - beforeBalance, 19.92 ether);
        assertEq(fees.balance, 0.04 ether);
        assertEq(referral.balance, 0.04 ether);
        assertEq(token.allowance(address(agent), address(v2)), 0);
        assertEq(quote.allowance(address(agent), address(core)), 0);
    }

    function test_existingShareIsNotRecreatedEvenIfCreationIsPausedOrNowCostsMoney() public {
        shares.createShare(buyer);
        shares.adminSetCreateFee(0.01 ether);
        shares.pause();
        assertEq(_buy(buyer, 1, buyer, referral), 1.992 ether);
        _assertShare(buyer);
    }

    function test_buyAndSellWithoutHandleRevertBeforeCreationOrFees() public {
        AgentHandleRegistryMock(REGISTRY).setHandle(buyer, "");
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, buyer));
        _buy(buyer, 1, buyer, referral);
        AgentHandleRegistryMock(REGISTRY).setHandle(seller, "");
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, seller));
        _sell(seller, 1);
        assertFalse(shares.ipshareCreated(buyer));
        assertFalse(shares.ipshareCreated(seller));
        assertEq(fees.balance, 0);
        assertEq(token.balanceOf(seller), 1_000 ether);
    }

    function test_existingShareDoesNotBypassHandleRevocation() public {
        shares.createShare(buyer);
        AgentHandleRegistryMock(REGISTRY).setHandle(buyer, "");
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, buyer));
        _buy(buyer, 1, buyer, referral);
    }

    function test_registeredRecipientCannotAuthenticateUnregisteredCallerOrTxOrigin() public {
        address intermediary = makeAddr("intermediary");
        vm.deal(intermediary, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, intermediary));
        vm.prank(intermediary, buyer);
        agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, 1, buyer, block.timestamp + 1, referral
        );
        assertFalse(shares.ipshareCreated(buyer));
        assertFalse(shares.ipshareCreated(intermediary));
    }

    function test_creationAlwaysTargetsCallerEvenWhenRecipientIsDifferent() public {
        address recipient = makeAddr("giftRecipient");
        assertEq(_buy(buyer, 1, recipient, referral), 1.992 ether);
        _assertShare(buyer);
        assertFalse(shares.ipshareCreated(recipient));
        assertEq(token.balanceOf(recipient), 1.992 ether);
    }

    function test_creationFeeNeverComesFromPrincipalOrStrandedBalances() public {
        shares.adminSetCreateFee(0.001 ether);
        vm.deal(address(agent), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.IPShareCreationFeeRequired.selector, 0.001 ether));
        _buy(buyer, 1, buyer, referral);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.IPShareCreationFeeRequired.selector, 0.001 ether));
        _sell(seller, 1);
        assertFalse(shares.ipshareCreated(buyer));
        assertFalse(shares.ipshareCreated(seller));
        assertEq(address(agent).balance, 1 ether);
        assertEq(buyer.balance, 100 ether);
        assertEq(fees.balance, 0);
    }

    function test_pausedIPShareRevertsNewUserBuyAndSellAtomically() public {
        shares.pause();
        vm.expectRevert("Pausable: paused");
        _buy(buyer, 1, buyer, referral);
        vm.expectRevert("Pausable: paused");
        _sell(seller, 1);
        assertFalse(shares.ipshareCreated(buyer));
        assertFalse(shares.ipshareCreated(seller));
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(seller), 1_000 ether);
    }

    function test_slippageAndDexFailuresRollBackNewSharesAndAllFees() public {
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        _buy(buyer, 2 ether, buyer, referral);
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        _sell(seller, 20 ether);
        assertFalse(shares.ipshareCreated(buyer));
        assertFalse(shares.ipshareCreated(seller));
        assertEq(fees.balance, 0);
        assertEq(referral.balance, 0);
        core.setBridgeEnabled(false);
        vm.expectRevert();
        _buy(buyer, 1, buyer, referral);
        assertFalse(shares.ipshareCreated(buyer));
    }

    function test_noTokenSideFeeEvenForRegisteredCommunityAndBothQuoteDirections() public {
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(token));
        AgentCommunityMock community = new AgentCommunityMock(address(token), address(calculator));
        agent.registerImportedToken(address(token), address(community), makeAddr("deployer"));
        assertEq(agent.nutboxTokenRatio(), 0);
        assertEq(agent.quoteBuy(address(token), INutboxRouter.SourceType.V2_PAIR, source, 1 ether), 1.992 ether);
        assertEq(agent.quoteSell(address(token), INutboxRouter.SourceType.V2_PAIR, source, 10 ether), 19.92 ether);
        _buy(buyer, 1, buyer, referral);
        _sell(seller, 1);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(calculator.injected(address(community)), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(token.balanceOf(address(community)), 0);
    }

    function test_nativeFeeSetterRequiresPerTokenNutboxConfiguration() public {
        vm.expectRevert(AgentSwapWrapper.UsePerTokenNutboxConfig.selector);
        agent.setFeeRatios(20, 20, 1);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        agent.setFeeRatios(1001, 1000, 0);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(buyer);
        agent.setFeeRatios(0, 0, 0);
        agent.setFeeRatios(30, 40, 0);
        assertEq(agent.sellsmanRatio(), 30);
        assertEq(agent.tagaiRatio(), 40);
        assertEq(agent.nutboxTokenRatio(), 0);
        assertEq(_buy(buyer, 1, buyer, referral), 1.986 ether);
    }

    function _nutbox(uint16 feeBps) private returns (AgentCommunityMock community, ImportedCalculatorMock calculator) {
        calculator = new ImportedCalculatorMock(address(token));
        community = new AgentCommunityMock(address(token), address(calculator));
        agent.setNutboxMarket(address(token), address(community), referral, feeBps);
    }

    function test_unappointedRegistrarCannotBindOrSetNutboxFees() public {
        (AgentCommunityMock community,) = _nutbox(20);
        agent.setRegistrar(buyer);
        bytes memory reason = abi.encodeWithSelector(AgentSwapWrapper.UnauthorizedOperator.selector, buyer);
        vm.startPrank(buyer);
        vm.expectRevert(reason);
        agent.setNutboxMarket(address(token), address(community), buyer, 30);
        vm.expectRevert(reason);
        agent.setTokenNutboxFee(address(token), 30);
        vm.expectRevert(reason);
        agent.registerImportedToken(address(quote), address(community), buyer);
        vm.expectRevert(reason);
        agent.updateImportedMarket(address(token), address(community), buyer);
        vm.stopPrank();
        assertEq(agent.tokenNutboxFeeBps(address(token)), 20);
        (, address boundCommunity, address deployer) = agent.getImportedMarket(address(token));
        assertEq(boundCommunity, address(community));
        assertEq(deployer, referral);
    }

    function test_onlyOwnerCanAppointReplaceOrRevokeOperator() public {
        assertEq(agent.operator(), address(0));
        vm.expectEmit(true, true, false, true, address(agent));
        emit AgentSwapWrapper.OperatorChanged(address(0), buyer);
        agent.setOperator(buyer);
        assertEq(agent.operator(), buyer);
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        agent.setOperator(seller);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidAddress.selector);
        agent.setOperator(address(agent));
        assertEq(agent.operator(), buyer);
        agent.setOperator(seller);
        assertEq(agent.operator(), seller);
        agent.setOperator(address(0));
        assertEq(agent.operator(), address(0));
    }

    function test_operatorCanRegisterUpdateAndConfigureNutboxFeesWithoutRegistrarRole() public {
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(token));
        AgentCommunityMock firstCommunity = new AgentCommunityMock(address(token), address(calculator));
        AgentCommunityMock secondCommunity = new AgentCommunityMock(address(token), address(calculator));
        agent.setOperator(buyer);
        vm.startPrank(buyer);
        agent.registerImportedToken(address(token), address(firstCommunity), referral);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
        agent.setTokenNutboxFee(address(token), 20);
        agent.updateImportedMarket(address(token), address(secondCommunity), seller);
        agent.setNutboxMarket(address(token), address(firstCommunity), referral, 40);
        vm.stopPrank();
        (, address community, address deployer) = agent.getImportedMarket(address(token));
        assertEq(community, address(firstCommunity));
        assertEq(deployer, referral);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 40);
        // Register a previously unbound token through the atomic configuration entry point as operator.
        ImportedCalculatorMock quoteCalculator = new ImportedCalculatorMock(address(quote));
        AgentCommunityMock quoteCommunity = new AgentCommunityMock(address(quote), address(quoteCalculator));
        vm.prank(buyer);
        agent.setNutboxMarket(address(quote), address(quoteCommunity), referral, 25);
        assertEq(agent.tokenNutboxFeeBps(address(quote)), 25);
        assertEq(_buy(buyer, 1, buyer, referral), 1.984032 ether);
        assertEq(agent.pendingNutboxInjection(address(token)), 0.007968 ether);
        // Owner retains direct access even while an operator is appointed.
        agent.setTokenNutboxFee(address(token), 0);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
    }

    function test_replacedAndRevokedOperatorLoseAllNutboxConfigurationAccess() public {
        (AgentCommunityMock community,) = _nutbox(20);
        agent.setOperator(buyer);
        agent.setOperator(seller);
        bytes memory reason = abi.encodeWithSelector(AgentSwapWrapper.UnauthorizedOperator.selector, buyer);
        vm.startPrank(buyer);
        vm.expectRevert(reason);
        agent.setNutboxMarket(address(token), address(community), buyer, 30);
        vm.expectRevert(reason);
        agent.setTokenNutboxFee(address(token), 30);
        vm.expectRevert(reason);
        agent.registerImportedToken(address(quote), address(community), buyer);
        vm.expectRevert(reason);
        agent.updateImportedMarket(address(token), address(community), buyer);
        vm.stopPrank();
        vm.prank(seller);
        agent.setTokenNutboxFee(address(token), 40);
        agent.setOperator(address(0));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.UnauthorizedOperator.selector, seller));
        agent.setTokenNutboxFee(address(token), 0);
        agent.setTokenNutboxFee(address(token), 0);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
    }

    function test_operatorCannotExerciseOtherOwnerPowers() public {
        agent.setOperator(buyer);
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(agent.setOperator, (seller));
        calls[1] = abi.encodeCall(agent.setFeeRatios, (30, 40, 0));
        calls[2] = abi.encodeCall(agent.setFeeAddress, (seller));
        calls[3] = abi.encodeCall(agent.setIPShare, (address(shares)));
        calls[4] = abi.encodeCall(agent.setRegistrar, (buyer));
        calls[5] = abi.encodeCall(agent.setReferralHook, (address(token), true));
        calls[6] = abi.encodeCall(agent.pause, ());
        calls[7] = abi.encodeCall(agent.transferOwnership, (buyer));
        calls[8] = abi.encodeCall(agent.renounceOwnership, ());
        vm.startPrank(buyer);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(agent).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSignature("Error(string)", "Ownable: caller is not the owner"));
        }
        vm.stopPrank();
        assertEq(agent.owner(), address(this));
        assertFalse(agent.paused());
    }

    function test_operatorMustRespectCommunityFeeAndPendingRewardChecks() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        AgentCommunityMock replacement = new AgentCommunityMock(address(token), address(calculator));
        AgentCommunityMock wrongToken = new AgentCommunityMock(address(quote), address(calculator));
        _buy(buyer, 1, buyer, referral);
        uint256 pending = agent.pendingNutboxInjection(address(token));
        agent.setOperator(buyer);
        vm.startPrank(buyer);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        agent.setTokenNutboxFee(address(token), 2001);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        agent.setNutboxMarket(address(token), address(community), referral, 2001);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        agent.setNutboxMarket(address(token), address(wrongToken), referral, 20);
        vm.expectRevert(
            abi.encodeWithSelector(
                ImportedTokenSwapWrapper.PendingNutboxInjectionExists.selector, address(token), pending
            )
        );
        agent.setNutboxMarket(address(token), address(replacement), referral, 20);
        vm.expectRevert(
            abi.encodeWithSelector(
                ImportedTokenSwapWrapper.PendingNutboxInjectionExists.selector, address(token), pending
            )
        );
        agent.updateImportedMarket(address(token), address(replacement), referral);
        agent.setTokenNutboxFee(address(token), 0);
        vm.stopPrank();
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        vm.warp(block.timestamp + 600);
        agent.flushNutboxInjection(address(token));
        assertEq(calculator.injected(address(community)), pending);
        assertEq(calculator.injected(address(replacement)), 0);
    }

    function test_bindingRejectsWrongTokenMissingCalculatorAndInvalidRate() public {
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(token));
        AgentCommunityMock wrongToken = new AgentCommunityMock(address(quote), address(calculator));
        AgentCommunityMock noCalculator = new AgentCommunityMock(address(token), buyer);
        AgentCommunityMock valid = new AgentCommunityMock(address(token), address(calculator));
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        agent.setNutboxMarket(address(token), address(wrongToken), referral, 20);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        agent.setNutboxMarket(address(token), address(noCalculator), referral, 20);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        agent.setNutboxMarket(address(token), address(valid), address(0), 20);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        agent.setNutboxMarket(address(token), address(valid), referral, 2001);
        (bool registered,,) = agent.getImportedMarket(address(token));
        assertFalse(registered);
        vm.expectRevert(ImportedTokenSwapWrapper.MarketNotRegistered.selector);
        agent.setTokenNutboxFee(address(token), 20);
        agent.setNutboxMarket(address(token), address(valid), referral, 20);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidFeeRatio.selector);
        agent.setTokenNutboxFee(address(token), 2001);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        agent.updateImportedMarket(address(token), address(wrongToken), referral);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 20);
    }

    function test_configuredBuyAndSellFeesMatchQuotesAndAccrueToBoundCommunity() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        uint256 buyFee = 1.992 ether * 20 / 10_000;
        uint256 sellFee = 10 ether * 20 / 10_000;
        uint256 netBuy = 1.992 ether - buyFee;
        uint256 netSell = 19.92 ether * 9980 / 10_000;
        assertEq(agent.quoteBuy(address(token), INutboxRouter.SourceType.V2_PAIR, source, 1 ether), netBuy);
        assertEq(agent.quoteSell(address(token), INutboxRouter.SourceType.V2_PAIR, source, 10 ether), netSell);
        (uint256 netPreview, uint256 feePreview) = agent.previewTokenFee(address(token), 10 ether);
        assertEq(netPreview, 10 ether - sellFee);
        assertEq(feePreview, sellFee);
        vm.recordLogs();
        assertEq(_buy(buyer, netBuy, buyer, referral), netBuy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 tradeTopic = keccak256(
            "ImportedTokenTrade(address,address,address,bool,address,uint8,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,address)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(agent) && logs[i].topics[0] == tradeTopic) {
                // Non-indexed ABI words: isBuy, quote, sourceType, sourceHash, tokenAmount,
                // grossNative, netNative, platformFee, referralFee, Nutbox fee, recipient.
                bytes memory data = logs[i].data;
                uint256 eventFee;
                assembly { eventFee := mload(add(data, 320)) }
                assertEq(eventFee, buyFee);
                found = true;
            }
        }
        assertTrue(found);
        assertEq(_sell(seller, netSell), netSell);
        _assertShare(buyer);
        _assertShare(seller);
        assertEq(agent.pendingNutboxInjection(address(token)), buyFee + sellFee);
        assertEq(token.balanceOf(address(agent)), buyFee + sellFee);
        assertEq(calculator.injected(address(community)), 0);
        assertEq(fees.balance, 0.002 ether + 0.03992 ether);
        assertEq(referral.balance, fees.balance);
        (netPreview, feePreview) = agent.previewTokenFee(address(quote), 10 ether);
        assertEq(netPreview, 10 ether);
        assertEq(feePreview, 0);
    }

    function test_explicitFlushTransfersRewardsAndResetsAllowance() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        _buy(buyer, 1, buyer, referral);
        uint256 pending = agent.pendingNutboxInjection(address(token));
        vm.expectRevert(ImportedTokenSwapWrapper.InjectionIntervalActive.selector);
        agent.flushNutboxInjection(address(token));
        vm.warp(block.timestamp + 600);
        vm.prank(buyer); // Permissionless settlement.
        assertEq(agent.flushNutboxInjection(address(token)), pending);
        assertEq(calculator.injected(address(community)), pending);
        assertEq(token.balanceOf(address(community)), pending);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(token.allowance(address(agent), address(calculator)), 0);
    }

    function test_expiredTradeInjectsOldFeesAndKeepsNewFeesPending() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        _buy(buyer, 1, buyer, referral);
        uint256 firstFee = agent.pendingNutboxInjection(address(token));
        vm.warp(block.timestamp + 600);
        _sell(seller, 1);
        assertEq(calculator.injected(address(community)), firstFee);
        assertEq(agent.pendingNutboxInjection(address(token)), 0.02 ether);
        assertEq(token.balanceOf(address(agent)), 0.02 ether);
        assertEq(token.allowance(address(agent), address(calculator)), 0);
    }

    function test_failedInjectionRetainsRewardsAndDoesNotBlockTrade() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        _buy(buyer, 1, buyer, referral);
        uint256 firstFee = agent.pendingNutboxInjection(address(token));
        calculator.setInjectionReverts(true);
        vm.warp(block.timestamp + 600);
        _sell(seller, 1);
        uint256 pending = firstFee + 0.02 ether;
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        assertEq(token.balanceOf(address(agent)), pending);
        assertEq(token.allowance(address(agent), address(calculator)), 0);
        assertEq(agent.flushNutboxInjection(address(token)), 0);
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        calculator.setInjectionReverts(false);
        assertEq(agent.flushNutboxInjection(address(token)), pending);
        assertEq(calculator.injected(address(community)), pending);
    }

    function test_pendingRewardsCannotBeRedirectedByEitherBindingSetter() public {
        (AgentCommunityMock oldCommunity, ImportedCalculatorMock calculator) = _nutbox(20);
        AgentCommunityMock newCommunity = new AgentCommunityMock(address(token), address(calculator));
        _buy(buyer, 1, buyer, referral);
        uint256 pending = agent.pendingNutboxInjection(address(token));
        bytes memory reason = abi.encodeWithSelector(
            ImportedTokenSwapWrapper.PendingNutboxInjectionExists.selector, address(token), pending
        );
        vm.expectRevert(reason);
        agent.setNutboxMarket(address(token), address(newCommunity), buyer, 50);
        vm.expectRevert(reason);
        agent.updateImportedMarket(address(token), address(newCommunity), buyer);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 20);
        vm.warp(block.timestamp + 600);
        agent.flushNutboxInjection(address(token));
        assertEq(calculator.injected(address(oldCommunity)), pending);
        assertEq(calculator.injected(address(newCommunity)), 0);
        agent.setNutboxMarket(address(token), address(newCommunity), buyer, 50);
        (, address boundCommunity, address deployer) = agent.getImportedMarket(address(token));
        assertEq(boundCommunity, address(newCommunity));
        assertEq(deployer, buyer);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 50);
    }

    function test_disableFeeKeepsOldRewardsFlushableAndTradingFeeFree() public {
        (AgentCommunityMock community, ImportedCalculatorMock calculator) = _nutbox(20);
        _buy(buyer, 1, buyer, referral);
        uint256 pending = agent.pendingNutboxInjection(address(token));
        agent.setTokenNutboxFee(address(token), 0);
        assertEq(_buy(buyer, 1.992 ether, buyer, referral), 1.992 ether);
        assertEq(_sell(seller, 19.92 ether), 19.92 ether);
        assertEq(agent.pendingNutboxInjection(address(token)), pending);
        vm.warp(block.timestamp + 600);
        assertEq(agent.flushNutboxInjection(address(token)), pending);
        assertEq(calculator.injected(address(community)), pending);
        (, address boundCommunity, address deployer) = agent.getImportedMarket(address(token));
        assertEq(boundCommunity, address(community));
        assertEq(deployer, referral);
    }

    function test_configuredFeeAndNewShareRollbackOnSlippage() public {
        _nutbox(20);
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        _buy(buyer, 1.992 ether, buyer, referral);
        assertFalse(shares.ipshareCreated(buyer));
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        assertEq(token.balanceOf(address(agent)), 0);
        assertEq(fees.balance, 0);
        assertEq(referral.balance, 0);
    }

    function testFuzz_ownerConfiguredTokenFeeMatchesActualBuy(uint16 rate) public {
        rate = uint16(bound(rate, 0, 2000));
        _nutbox(rate);
        uint256 fee = 1.992 ether * uint256(rate) / 10_000;
        assertEq(_buy(buyer, 1.992 ether - fee, buyer, referral), 1.992 ether - fee);
        assertEq(agent.pendingNutboxInjection(address(token)), fee);
        assertEq(token.balanceOf(address(agent)), fee);
    }

    function test_quotesDoNotRequireHandleOrCreateShares() public {
        AgentHandleRegistryMock(REGISTRY).setHandle(buyer, "");
        vm.prank(buyer);
        assertEq(agent.quoteBuy(address(token), INutboxRouter.SourceType.V2_PAIR, source, 1 ether), 1.992 ether);
        assertFalse(shares.ipshareCreated(buyer));
    }

    function test_selfReferralUsesNewlyCreatedIPShareValueCapture() public {
        _buy(buyer, 1, buyer, buyer);
        assertTrue(shares.ipshareCreated(buyer));
        assertGt(shares.getPendingProfits(buyer, buyer), 0);
        // IPShare itself pays its configured subject fee back to the share owner.
        assertEq(buyer.balance, 99 ether + 0.002 ether * shares.subjectFeePercent() / 10_000);
    }

    function test_noOpCreationIsRejected() public {
        agent.setIPShare(address(new AgentNoOpIPShare()));
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.IPShareCreationFailed.selector, buyer));
        _buy(buyer, 1, buyer, referral);
    }

    function test_creationCallbacksCannotReenterEitherTradeEntry() public {
        AgentReenteringIPShare attack = new AgentReenteringIPShare();
        attack.setTarget(address(agent));
        agent.setIPShare(address(attack));
        _buy(buyer, 1, buyer, referral);
        assertEq(attack.blocked(), 2);
        assertTrue(attack.ipshareCreated(buyer));
    }

    function test_ordinaryContractSubjectFailsWithoutCreatingForRecipient() public {
        address contractWallet = address(new AgentNoOpIPShare());
        vm.deal(contractWallet, 1 ether);
        AgentHandleRegistryMock(REGISTRY).setHandle(contractWallet, "contract");
        vm.expectRevert("Subject must be EOA");
        _buy(contractWallet, 1, buyer, referral);
        assertFalse(shares.ipshareCreated(contractWallet));
        assertFalse(shares.ipshareCreated(buyer));
    }

    function test_eip7702AgentCanCreateItsOwnShare() public {
        vm.etch(buyer, abi.encodePacked(hex"ef0100", makeAddr("delegatedImplementation")));
        _buy(buyer, 1, buyer, referral);
        _assertShare(buyer);
    }

    function test_handleRegistryFailureCannotFallBackToOpenTrading() public {
        vm.mockCallRevert(REGISTRY, abi.encodeWithSignature("handleOf(address)", buyer), "REGISTRY_UNAVAILABLE");
        vm.expectRevert(bytes("REGISTRY_UNAVAILABLE"));
        _buy(buyer, 1, buyer, referral);
        assertFalse(shares.ipshareCreated(buyer));
    }

    function test_pauseExpiryAndZeroRecipientRejectBeforeCreating() public {
        agent.pause();
        vm.expectRevert("Pausable: paused");
        _buy(buyer, 1, buyer, referral);
        agent.unpause();
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidRecipient.selector);
        _buy(buyer, 1, address(0), referral);
        vm.expectRevert(ImportedTokenSwapWrapper.DeadlineExpired.selector);
        vm.prank(buyer);
        agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, 1, buyer, block.timestamp - 1, referral
        );
        assertFalse(shares.ipshareCreated(buyer));
    }

    function test_v2TaxTokenRoundTripUsesActualBalancesAndNoNutboxFee() public {
        ImportedFeeOnTransferToken taxed = new ImportedFeeOnTransferToken();
        bytes memory taxedSource = _v2Source(address(taxed), address(quote));
        vm.prank(buyer);
        uint256 bought = agent.buyToken{value: 1 ether}(
            address(taxed), INutboxRouter.SourceType.V2_PAIR, taxedSource, 1, buyer, block.timestamp + 1, referral
        );
        assertEq(bought, taxed.balanceOf(buyer));
        assertLt(bought, 1.992 ether);
        _assertShare(buyer);
        vm.startPrank(buyer);
        taxed.approve(address(agent), bought);
        uint256 sold = agent.sellToken(
            address(taxed),
            INutboxRouter.SourceType.V2_PAIR,
            taxedSource,
            bought,
            1,
            buyer,
            block.timestamp + 1,
            referral
        );
        vm.stopPrank();
        assertGt(sold, 0);
        assertEq(taxed.balanceOf(address(agent)), 0);
        assertEq(agent.pendingNutboxInjection(address(taxed)), 0);
    }

    function test_configuredNutboxTaxTokenFeeUsesActualReceivedAmounts() public {
        ImportedFeeOnTransferToken taxed = new ImportedFeeOnTransferToken();
        bytes memory taxedSource = _v2Source(address(taxed), address(quote));
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(taxed));
        AgentCommunityMock community = new AgentCommunityMock(address(taxed), address(calculator));
        agent.setNutboxMarket(address(taxed), address(community), referral, 20);
        // The router mints output; the token taxes Wrapper -> recipient and both sell input transfers.
        uint256 buyFee = 1.992 ether * 20 / 10_000;
        uint256 beforeTransferTax = 1.992 ether - buyFee;
        uint256 expectedBuy = beforeTransferTax - beforeTransferTax / 100;
        vm.prank(buyer);
        uint256 bought = agent.buyToken{value: 1 ether}(
            address(taxed),
            INutboxRouter.SourceType.V2_PAIR,
            taxedSource,
            expectedBuy,
            buyer,
            block.timestamp + 1,
            referral
        );
        assertEq(bought, expectedBuy);
        assertEq(agent.pendingNutboxInjection(address(taxed)), buyFee);
        uint256 actualReceived = bought - bought / 100;
        uint256 sellFee = actualReceived * 20 / 10_000;
        uint256 inputToRouter = actualReceived - sellFee;
        uint256 grossNative = (inputToRouter - inputToRouter / 100) * 2;
        uint256 expectedSell = grossNative - 2 * (grossNative * 20 / 10_000);
        vm.startPrank(buyer);
        taxed.approve(address(agent), bought);
        assertEq(
            agent.sellToken(
                address(taxed),
                INutboxRouter.SourceType.V2_PAIR,
                taxedSource,
                bought,
                expectedSell,
                buyer,
                block.timestamp + 1,
                referral
            ),
            expectedSell
        );
        vm.stopPrank();
        assertEq(agent.pendingNutboxInjection(address(taxed)), buyFee + sellFee);
        assertEq(taxed.balanceOf(address(agent)), buyFee + sellFee);
    }

    function test_v3BuySellCreatesSharesAndKeepsFeeAccounting() public {
        ImportedV3PoolMock pool =
            new ImportedV3PoolMock(address(new ImportedV3FactoryMock()), address(token), address(quote), 500);
        bytes memory v3Source =
            abi.encode(ImportedTokenSwapWrapper.V3Source(address(v3), address(v3Quoter), address(pool)));
        vm.prank(buyer);
        assertEq(
            agent.buyToken{value: 1 ether}(
                address(token), INutboxRouter.SourceType.V3_POOL, v3Source, 1, buyer, block.timestamp + 1, referral
            ),
            1.992 ether
        );
        vm.startPrank(seller);
        token.approve(address(agent), 10 ether);
        assertEq(
            agent.sellToken(
                address(token),
                INutboxRouter.SourceType.V3_POOL,
                v3Source,
                10 ether,
                1,
                seller,
                block.timestamp + 1,
                referral
            ),
            19.92 ether
        );
        vm.stopPrank();
        _assertShare(buyer);
        _assertShare(seller);
    }

    function test_v4NativeQuotePreservesHookSubjectAndClearsItForPublicQuotes() public {
        ImportedPancakeV4VaultMock vault = new ImportedPancakeV4VaultMock();
        AgentV4ManagerMock manager = new AgentV4ManagerMock(address(vault));
        vm.deal(address(vault), 100 ether);
        address hook = address(new AgentNoOpIPShare());
        agent.setReferralHook(hook, true);
        INutboxRouter.PancakeV4CLSource memory pool =
            INutboxRouter.PancakeV4CLSource(address(0), address(token), hook, address(manager), 500, bytes32(0));
        bytes memory v4Source =
            abi.encode(ImportedTokenSwapWrapper.PancakeV4Source(address(new AgentV4QuoterMock()), pool));
        vm.prank(buyer);
        assertEq(
            agent.buyToken{value: 1 ether}(
                address(token),
                INutboxRouter.SourceType.PANCAKE_V4_CL,
                v4Source,
                1,
                buyer,
                block.timestamp + 1,
                referral
            ),
            1.992 ether
        );
        assertEq(abi.decode(manager.lastHookData(), (address)), referral);
        vm.startPrank(seller);
        token.approve(address(agent), 10 ether);
        assertEq(
            agent.sellToken(
                address(token),
                INutboxRouter.SourceType.PANCAKE_V4_CL,
                v4Source,
                10 ether,
                1,
                seller,
                block.timestamp + 1,
                seller
            ),
            19.92 ether
        );
        vm.stopPrank();
        assertEq(abi.decode(manager.lastHookData(), (address)), seller);
        _assertShare(buyer);
        assertTrue(shares.ipshareCreated(seller));
        assertEq(shares.totalStakedIPshare(seller), 10 ether);
        assertGt(shares.ipshareSupply(seller), 10 ether);
        assertEq(agent.quoteBuy(address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, v4Source, 1 ether), 1.992 ether);
        vm.prank(buyer);
        agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, v4Source, 1, buyer, block.timestamp + 1, address(0)
        );
        assertEq(abi.decode(manager.lastHookData(), (address)), address(0));
        agent.setReferralHook(hook, false);
        vm.prank(buyer);
        agent.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, v4Source, 1, buyer, block.timestamp + 1, referral
        );
        assertEq(manager.lastHookData(), bytes(""));
    }

    function test_constructorRequiresRealRegistryContract() public {
        vm.etch(REGISTRY, "");
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidAddress.selector);
        new AgentSwapWrapper(address(core), fees, address(shares));
    }

    function test_referralHookConfigurationRequiresOwnerAndReviewedCode() public {
        address hook = address(new AgentNoOpIPShare());
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(buyer);
        agent.setReferralHook(hook, true);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidAddress.selector);
        agent.setReferralHook(address(0), true);
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidAddress.selector);
        agent.setReferralHook(makeAddr("noCode"), true);
        agent.setReferralHook(hook, true);
        assertEq(agent.referralHookCodeHash(hook), hook.codehash);
        INutboxRouter.PancakeV4CLSource memory pool =
            INutboxRouter.PancakeV4CLSource(address(0), address(token), hook, address(1), 500, bytes32(0));
        bytes memory data = abi.encode(ImportedTokenSwapWrapper.PancakeV4Source(address(new AgentV4QuoterMock()), pool));
        assertEq(agent.quoteBuy(address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, data, 1 ether), 1.992 ether);
        vm.etch(hook, hex"600160005260206000f3");
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.ReferralHookCodeChanged.selector, hook));
        agent.quoteBuy(address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, data, 1 ether);
    }

    function test_firstTradeCostsMoreGasButRepeatedTradeDoesNotCreateAgain() public {
        uint256 start = gasleft();
        _buy(buyer, 1, buyer, referral);
        uint256 first = start - gasleft();
        start = gasleft();
        _buy(buyer, 1, buyer, referral);
        uint256 repeated = start - gasleft();
        _assertShare(buyer);
        assertGt(first, repeated);
        emit log_named_uint("first call execution gas (includes cold reads)", first);
        emit log_named_uint("repeat call execution gas (warm state)", repeated);
    }

    function testFuzz_v2NativeInputPreservesPrincipalMinusOnlyNativeFees(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 10 ether);
        uint256 fee = amount * 20 / 10_000;
        uint256 expected = (amount - fee - fee) * 2;
        vm.prank(buyer);
        uint256 received = agent.buyToken{value: amount}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, expected, buyer, block.timestamp + 1, referral
        );
        assertEq(received, expected);
        assertEq(fees.balance, fee);
        assertEq(referral.balance, fee);
        assertEq(agent.nutboxTokenRatio(), 0);
        assertEq(agent.pendingNutboxInjection(address(token)), 0);
        _assertShare(buyer);
    }

    function testFuzz_missingHandleCannotBuyRegardlessOfValue(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10 ether);
        AgentHandleRegistryMock(REGISTRY).setHandle(buyer, "");
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, buyer));
        vm.prank(buyer);
        agent.buyToken{value: amount}(
            address(token), INutboxRouter.SourceType.V2_PAIR, source, 1, buyer, block.timestamp + 1, referral
        );
        assertFalse(shares.ipshareCreated(buyer));
        assertEq(fees.balance, 0);
        assertEq(buyer.balance, 100 ether);
    }
}
