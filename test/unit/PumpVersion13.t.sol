// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pump, IPumpBasketHook} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {MockCLPoolManager} from "../mocks/MockCLPoolManager.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {MockERC20StakingFactory, MockERC20StakingPool} from "../helpers/Version13ERC20StakingMocks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";

contract Version13Asset is ERC20 {
    constructor() ERC20("Component", "COMP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Version13BlockedAsset is Version13Asset {
    function transfer(address, uint256) public pure override returns (bool) {
        revert("TRANSFERS_BLOCKED");
    }
}

contract Version13Pair {
    address public token0;
    address public token1;
    mapping(address => uint256) public balanceOf;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }

    function mint(address to) external returns (uint256 liquidity) {
        require(Token(payable(token0)).balanceOf(address(this)) > 0, "NO_COMMUNITY_TOKENS");
        require(Version13Asset(token1).balanceOf(address(this)) > 0, "NO_COMPONENTS");
        balanceOf[to] += 1 ether;
        return 1 ether;
    }
}

contract Version13Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        pair = address(new Version13Pair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

// Deterministic external venue doubles: these tests verify canonical Pump/Token wiring,
// allocation and lifecycle, not DEX pricing or Basket's own accounting.
contract Version13Router {
    address public wrappedNative;
    uint256 public nativeSpent;
    uint256 public poolsAdded;
    uint256 public routesAdded;

    struct StoredPool {
        bool enabled;
        address token0;
        address token1;
        INutboxRouter.SourceType sourceType;
        bytes sourceData;
    }
    mapping(bytes32 => StoredPool) private _pools;
    mapping(bytes32 => bytes32[]) private _routes;
    mapping(bytes32 => bool) private _existingRoutes;

    constructor(address wrapped) {
        wrappedNative = wrapped;
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        bytes32 routeId = _routeId(tokenIn, tokenOut);
        return _routes[routeId].length != 0 || _existingRoutes[routeId];
    }

    function setExistingRoute(address tokenIn, address tokenOut) external {
        _existingRoutes[_routeId(tokenIn, tokenOut)] = true;
    }
    function validateRoute(address, address) external pure {}

    function quote(address, address, uint256 amount) external pure returns (uint256) {
        return amount * 100;
    }

    function pricePoolId(address a, address b) external view returns (bytes32) {
        return _poolId(a, b);
    }

    function hasPricePool(bytes32 poolId) external view returns (bool) {
        return _pools[poolId].enabled;
    }

    function pricePool(bytes32 poolId)
        external
        view
        returns (bool, uint32, address, address, INutboxRouter.SourceType, bytes memory)
    {
        StoredPool storage pool = _pools[poolId];
        return (pool.enabled, 0, pool.token0, pool.token1, pool.sourceType, pool.sourceData);
    }

    function addPricePool(INutboxRouter.SourceType sourceType, bytes calldata sourceData)
        external
        returns (bytes32 poolId)
    {
        address token0;
        address token1;
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            (, address pair) = abi.decode(sourceData, (address, address));
            token0 = Version13Pair(pair).token0();
            token1 = Version13Pair(pair).token1();
        } else {
            INutboxRouter.PancakeV4CLSource memory source = abi.decode(sourceData, (INutboxRouter.PancakeV4CLSource));
            token0 = source.currency0;
            token1 = source.currency1;
        }
        poolId = _poolId(token0, token1);
        require(!_pools[poolId].enabled);
        _pools[poolId] = StoredPool(true, token0, token1, sourceType, sourceData);
        ++poolsAdded;
    }

    function addRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external {
        bytes32 routeId = _routeId(tokenIn, tokenOut);
        require(_routes[routeId].length == 0);
        for (uint256 i; i < poolIds.length; ++i) {
            _routes[routeId].push(poolIds[i]);
        }
        ++routesAdded;
    }

    function routePoolCount(address tokenIn, address tokenOut) external view returns (uint256) {
        return _routes[_routeId(tokenIn, tokenOut)].length;
    }

    function routePoolAt(address tokenIn, address tokenOut, uint256 index) external view returns (bytes32) {
        return _routes[_routeId(tokenIn, tokenOut)][index];
    }

    function _normalized(address token) private view returns (address) {
        return token == address(0) ? wrappedNative : token;
    }

    function _poolId(address a, address b) private view returns (bytes32) {
        a = _normalized(a);
        b = _normalized(b);
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _routeId(address a, address b) private view returns (bytes32) {
        return _poolId(a, b);
    }

    function swapExactInput(
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        address to,
        uint256 deadline
    ) external payable returns (uint256 result) {
        require(input == address(0) && msg.value == amount && deadline >= block.timestamp);
        result = amount * 100;
        require(result >= minimum);
        nativeSpent += amount;
        Version13Asset(output).mint(to, result);
    }
}

contract Version13BasketHook {
    uint32 public constant tokenVersion = 4;
    address public settlementToken;
    address public v2Factory;
    address public nutboxRouter;
    address public lastCreator;
    uint256 public creations;

    constructor(address settlement, address factory, address router) {
        settlementToken = settlement;
        v2Factory = factory;
        nutboxRouter = router;
    }

    function createBasketFor(address creator, bytes32, IPumpBasketHook.CreateParams calldata p)
        external
        returns (address)
    {
        require(p.creator == creator && p.constituentAssets.length > 0 && p.constituentAssets.length <= 10);
        require(p.constituentRoutes[0].venue == IPumpBasketHook.Venue.V2);
        require(IToken(p.constituentRoutes[0].poolQuoteToken).listed());
        lastCreator = creator;
        ++creations;
        return address(new Version13Asset());
    }
}

contract PumpVersion13Test is Test {
    Pump internal pump;
    Token internal token;
    IPShare internal ipshare;
    MockVault internal vault;
    MockCLPoolManager internal manager;
    TagAISwapHook internal hook;
    Version13Router internal router;
    Version13Factory internal factory;
    Version13BasketHook internal basket;
    Version13Asset internal assetA;
    Version13Asset internal assetB;
    Committee internal committee;
    MockERC20StakingFactory internal stakingFactory;
    address internal creator;
    address internal feeReceiver;
    address internal listingKeeper;

    function setUp() public {
        creator = makeAddr("creator");
        feeReceiver = makeAddr("feeReceiver");
        listingKeeper = makeAddr("listingKeeper");
        vm.deal(creator, 1000 ether);
        vm.warp(3600);
        committee = new Committee(payable(feeReceiver));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        address cf = deployCode("CommunityFactory.sol:CommunityFactory", abi.encode(address(committee)));
        HourlyTickCalculator calculator = new HourlyTickCalculator(cf);
        stakingFactory = new MockERC20StakingFactory();
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(stakingFactory));
        ipshare = new IPShare(feeReceiver);
        pump = new Pump(address(ipshare), feeReceiver, new address[](0));
        vault = new MockVault();
        manager = new MockCLPoolManager();
        pump.adminSetPoolManager(address(manager));
        pump.adminSetVault(address(vault));
        pump.adminSetNutbox(cf, address(calculator), address(stakingFactory), address(committee));
        hook = new TagAISwapHook(ICLPoolManager(address(manager)), IVault(address(vault)), address(pump));
        pump.adminSetHookAddress(address(hook));
        assetA = new Version13Asset();
        assetB = new Version13Asset();
        factory = new Version13Factory();
        router = new Version13Router(address(new Version13Asset()));
        router.setExistingRoute(router.wrappedNative(), address(assetA));
        router.setExistingRoute(router.wrappedNative(), address(assetB));
        basket = new Version13BasketHook(address(new Version13Asset()), address(factory), address(router));
        pump.adminSetIndexInfrastructure(address(router), address(basket), address(factory), basket.settlementToken());
        pump.adminSetConstituentApproval(address(assetA), true);
        pump.adminSetConstituentApproval(address(assetB), true);
        pump.adminSetListingKeeper(listingKeeper);
        uint256 creationValue = 0.005 ether + ipshare.createFee();
        vm.prank(creator, creator);
        token = Token(payable(pump.createToken{value: creationValue}("V13", bytes32(0), _config())));
    }

    function _config() internal view returns (IPump.IndexConfig memory c) {
        c.name = "V13 Index";
        c.symbol = "V13I";
        c.constituentAssets = new address[](2);
        c.constituentAssets[0] = address(assetA);
        c.constituentAssets[1] = address(assetB);
        c.targetWeights = new uint16[](2);
        c.targetWeights[0] = 3333;
        c.targetWeights[1] = 6667;
        c.basketFeeBps = 100;
        c.creatorShareBps = 3000;
        c.retainCommunityOwnership = true;
    }

    function test_canonicalContractsCreateConfiguredToken() public view {
        assertTrue(pump.createdTokens(address(token)));
        assertEq(token.indexCreator(), creator);
        assertEq(token.indexName(), "V13 Index");
        assertEq(token.componentCount(), 2);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.COMPONENT_POOL_TAX_BPS(), 10);
        assertGt(token.nutboxCommunity().code.length, 0);
        assertEq(Token(payable(pump.tokenImplementation())).V4_TOKEN_ALLOCATION(), 150_000_000 ether);
    }

    function test_creationBuildsOneNonLockingLPStakingPoolPerComponent() public view {
        Community community = Community(payable(token.nutboxCommunity()));
        assertEq(community.owner(), creator);

        for (uint256 i; i < token.componentCount(); ++i) {
            (,, address pair) = token.componentAt(i);
            address poolAddress = community.activedPools(i);
            MockERC20StakingPool pool = MockERC20StakingPool(poolAddress);
            assertEq(pool.factory(), address(stakingFactory));
            assertEq(pool.community(), address(community));
            assertEq(pool.stakeToken(), pair);
        }
    }

    function test_finalCommunityPoolRatiosMatchIndexWeights() public {
        uint256 creationFee = pump.createFee();
        vm.recordLogs();
        vm.prank(creator, creator);
        pump.createToken{value: creationFee}("WEIGHTS", bytes32(uint256(76)), _config());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 ratioEvent = keccak256("AdminSetPoolRatio(address[],uint16[])");
        bool foundFinalRatios;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == ratioEvent) {
                (, uint16[] memory ratios) = abi.decode(logs[i].data, (address[], uint16[]));
                if (ratios.length == 2) {
                    assertEq(ratios[0], 3333);
                    assertEq(ratios[1], 6667);
                    foundFinalRatios = true;
                }
            }
        }
        assertTrue(foundFinalRatios);
    }

    function test_creatorMayPermanentlyRenounceCommunityOwnershipAtCreation() public {
        IPump.IndexConfig memory c = _config();
        c.retainCommunityOwnership = false;
        uint256 creationFee = pump.createFee();
        vm.prank(creator, creator);
        Token renounced = Token(payable(pump.createToken{value: creationFee}("NOADMIN", bytes32(uint256(77)), c)));

        Community community = Community(payable(renounced.nutboxCommunity()));
        assertEq(community.owner(), address(0));
        assertGt(community.activedPools(0).code.length, 0);
        assertGt(community.activedPools(1).code.length, 0);

        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        vm.prank(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        community.adminSetPoolRatios(ratios);
    }

    function test_creationChargesOneSettingsFeePerLPStakingPool() public {
        uint256 createCommunityFee = 0.002 ether;
        uint256 settingsFee = 0.003 ether;
        committee.adminSetCreateCommunityFee(createCommunityFee);
        committee.adminSetCommunitySettingsFee(settingsFee);
        uint256 expected = pump.createFee() + createCommunityFee + settingsFee * 2;

        vm.prank(creator, creator);
        vm.expectRevert(IPump.InsufficientCreateFee.selector);
        pump.createToken{value: expected - 1}("LOWFEE", bytes32(uint256(78)), _config());

        uint256 recipientBefore = feeReceiver.balance;
        vm.prank(creator, creator);
        pump.createToken{value: expected}("POOLFEES", bytes32(uint256(79)), _config());
        assertEq(feeReceiver.balance - recipientBefore, expected);
    }

    function test_blockedComponentTransferLeavesListingPermanentlyPending() public {
        Version13BlockedAsset blocked = new Version13BlockedAsset();
        pump.adminSetConstituentApproval(address(blocked), true);
        router.setExistingRoute(router.wrappedNative(), address(blocked));
        IPump.IndexConfig memory c = _config();
        c.constituentAssets[0] = address(blocked);
        uint256 creationFee = pump.createFee();
        vm.prank(creator, creator);
        Token blockedToken = Token(payable(pump.createToken{value: creationFee}("BLOCKED", bytes32(uint256(80)), c)));

        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        blockedToken.buyToken{value: 100 ether}(0, creator, 0);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(
                toBalanceDelta(-int128(int256(15 ether)), -int128(int256(150_000_000 ether))), BalanceDelta.wrap(0)
            )
        );
        uint256[] memory mins = _componentMins(1, 1);
        for (uint256 i; i < 2; ++i) {
            vm.prank(listingKeeper);
            vm.expectRevert("TRANSFERS_BLOCKED");
            pump.finalizeTokenListing(address(blockedToken), mins, block.timestamp);
            assertTrue(blockedToken.listingPending());
            assertFalse(blockedToken.listed());
        }
        vm.clearMockedCalls();
    }

    function test_fourComponentsCanCreateAndList() public {
        IPump.IndexConfig memory c;
        c.name = "Four Component Index";
        c.symbol = "FOUR";
        c.constituentAssets = new address[](4);
        c.targetWeights = new uint16[](4);
        for (uint256 i; i < 4; ++i) {
            c.constituentAssets[i] = address(new Version13Asset());
            pump.adminSetConstituentApproval(c.constituentAssets[i], true);
            router.setExistingRoute(router.wrappedNative(), c.constituentAssets[i]);
            c.targetWeights[i] = 2500;
        }
        c.basketFeeBps = 100;
        c.creatorShareBps = 3000;
        c.retainCommunityOwnership = true;

        uint256 creationFee = pump.createFee();
        uint256 createGasBefore = gasleft();
        vm.prank(creator, creator);
        Token four = Token(payable(pump.createToken{value: creationFee}("FOUR", bytes32(uint256(81)), c)));
        emit log_named_uint("four-component creation gas", createGasBefore - gasleft());

        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        four.buyToken{value: 100 ether}(0, creator, 0);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(
                toBalanceDelta(-int128(int256(15 ether)), -int128(int256(150_000_000 ether))), BalanceDelta.wrap(0)
            )
        );
        uint256[] memory mins = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            mins[i] = 1;
        }
        uint256 listingGasBefore = gasleft();
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(four), mins, block.timestamp);
        emit log_named_uint("four-component listing gas", listingGasBefore - gasleft());
        vm.clearMockedCalls();
        assertTrue(four.listed());
    }

    function test_oldCreationRequiresIndexConfig() public {
        vm.expectRevert(IPump.IndexConfigRequired.selector);
        pump.createToken("OLD", bytes32(0));
    }

    function _countConfig(uint256 count) internal returns (IPump.IndexConfig memory c) {
        c = _config();
        c.constituentAssets = new address[](count);
        c.targetWeights = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            c.constituentAssets[i] = address(new Version13Asset());
            pump.adminSetConstituentApproval(c.constituentAssets[i], true);
            router.setExistingRoute(router.wrappedNative(), c.constituentAssets[i]);
            c.targetWeights[i] = uint16(i + 1 == count ? 10_000 - (10_000 / count) * (count - 1) : 10_000 / count);
        }
    }

    function testFuzz_rejectsMoreThanFourBeforeChargingFees(uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 5, 10);
        IPump.IndexConfig memory c = _countConfig(count);
        address freshCreator = makeAddr("over-limit-creator");
        vm.deal(freshCreator, 10 ether);
        uint256 beforeFees = feeReceiver.balance;
        vm.recordLogs();
        vm.prank(freshCreator, freshCreator);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        pump.createToken{value: 1 ether}("OVERLIMIT", bytes32(uint256(400)), c);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(freshCreator.balance, 10 ether);
        assertEq(feeReceiver.balance, beforeFees);
        assertFalse(ipshare.ipshareCreated(freshCreator));
        assertFalse(pump.createdTicks("OVERLIMIT"));
        assertEq(pump.MAX_COMPONENTS(), 4);
    }

    function test_tokenInitializerAlsoRejectsFiveComponents() public {
        IPump.IndexConfig memory c = _countConfig(5);
        Token fresh = new Token();
        fresh.initialize(address(pump), creator, "DIRECT");
        address settlement = basket.settlementToken();
        vm.prank(address(pump));
        vm.expectRevert(Token.InvalidIndexConfig.selector);
        fresh.initializeIndex(
            address(pump), creator, address(factory), address(router), address(basket), settlement, address(hook), c
        );
        assertEq(fresh.componentCount(), 0);
    }

    function test_rejectsInvalidWeights() public {
        IPump.IndexConfig memory c = _config();
        c.targetWeights[0] = 1;
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        pump.createToken("BAD", bytes32(uint256(1)), c);
    }

    function test_rejectsOversizedIndexMetadata() public {
        IPump.IndexConfig memory c = _config();
        c.name = "12345678901234567890123456789012345678901234567890123456789012345";
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        pump.createToken("LONGNAME", bytes32(uint256(83)), c);

        c = _config();
        c.symbol = "12345678901234567";
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        pump.createToken("LONGSYMBOL", bytes32(uint256(84)), c);
    }

    function test_rejectsComponentOutsidePlatformAllowlist() public {
        IPump.IndexConfig memory c = _config();
        c.constituentAssets[0] = address(new Version13Asset());
        vm.prank(creator, creator);
        vm.expectRevert(IPump.InvalidIndexConfig.selector);
        pump.createToken("UNAPPROVED", bytes32(uint256(82)), c);
    }

    function test_componentTransferBlockedBeforeListing() public {
        vm.warp(block.timestamp + 16);
        vm.startPrank(creator, creator);
        token.buyToken{value: 1 ether}(0, creator, 0);
        (,, address pair) = token.componentAt(0);
        vm.expectRevert(IToken.TokenNotListed.selector);
        token.transfer(pair, 1 ether);
        vm.stopPrank();
    }

    function test_onlyCanonicalPumpMayInitializeIndex() public {
        Token fresh = new Token();
        fresh.initialize(address(pump), creator, "FRESH");
        address settlement = basket.settlementToken();
        vm.expectRevert(Token.InvalidIndexConfig.selector);
        fresh.initializeIndex(
            address(this),
            creator,
            address(factory),
            address(router),
            address(basket),
            settlement,
            address(hook),
            _config()
        );
    }

    function test_existingTokenKeepsCreationInfrastructureAfterPumpUpgrade() public {
        (address savedRouter, address savedBasket, address savedSettlement, address savedManager) =
            token.listingInfrastructure();
        assertEq(savedRouter, address(router));
        assertEq(savedBasket, address(basket));
        assertEq(savedSettlement, basket.settlementToken());
        assertEq(savedManager, address(manager));
        assertEq(token.listingHook(), address(hook));
        assertEq(token.pancakeV2Factory(), address(factory));

        MockCLPoolManager replacementManager = new MockCLPoolManager();
        MockVault replacementVault = new MockVault();
        TagAISwapHook replacementHook = new TagAISwapHook(
            ICLPoolManager(address(replacementManager)), IVault(address(replacementVault)), address(pump)
        );
        Version13Factory replacementFactory = new Version13Factory();
        Version13Router replacementRouter = new Version13Router(address(new Version13Asset()));
        Version13BasketHook replacementBasket = new Version13BasketHook(
            address(new Version13Asset()), address(replacementFactory), address(replacementRouter)
        );

        pump.adminSetPoolManager(address(replacementManager));
        pump.adminSetVault(address(replacementVault));
        pump.adminSetHookAddress(address(replacementHook));
        pump.adminSetIndexInfrastructure(
            address(replacementRouter),
            address(replacementBasket),
            address(replacementFactory),
            replacementBasket.settlementToken()
        );

        _list();

        assertTrue(token.listed());
        assertEq(router.routesAdded(), 2);
        assertEq(replacementRouter.routesAdded(), 0);
        assertEq(basket.creations(), 1);
        assertEq(replacementBasket.creations(), 0);
        assertEq(token.balanceOf(address(hook)), token.NUTBOX_ALLOCATION());
        assertEq(token.balanceOf(address(replacementHook)), 0);
        assertGt(address(vault).balance, 0);
        assertEq(address(replacementVault).balance, 0);
    }

    function test_onlyCreatedTokensMayFinalize() public {
        vm.expectRevert(IPump.OnlyCreatedToken.selector);
        pump.finalizeTokenListing();
    }

    function test_premineStillUsesCanonicalToken() public {
        vm.prank(creator, creator);
        Token premine = Token(payable(pump.createToken{value: 1.005 ether}("PRE", bytes32(uint256(1)), _config())));
        assertGt(premine.balanceOf(creator), 0);
        assertEq(premine.componentCount(), 2);
        assertFalse(premine.listed());
    }

    function _list() internal returns (uint256 nativeSeed, uint256 tokenSeed, uint256 raisedNative) {
        uint160 price = 225060284636549774439465527763777;
        uint128 liquidity = 52804626975085827442929;
        nativeSeed = SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtRatioAtTick(191940), liquidity, true);
        tokenSeed = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(-887220), price, liquidity, true);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-int128(int256(nativeSeed)), -int128(int256(tokenSeed))), BalanceDelta.wrap(0))
        );
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        raisedNative = address(token).balance;
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), _componentMins(1, 1), block.timestamp);
        vm.clearMockedCalls();
    }

    function _fillToListingPending() internal {
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
    }

    function _componentMins(uint256 first, uint256 second) internal pure returns (uint256[] memory mins) {
        mins = new uint256[](2);
        mins[0] = first;
        mins[1] = second;
    }

    function test_listingSeedsBothVenuesAndCreatesIndex() public {
        (uint256 nativeSeed, uint256 tokenSeed, uint256 raisedNative) = _list();
        assertTrue(token.listed());
        assertLe(nativeSeed, 15 ether);
        assertLe(tokenSeed, 150_000_000 ether);
        assertEq(address(vault).balance, nativeSeed);
        assertEq(token.balanceOf(address(vault)), tokenSeed);
        assertEq(router.nativeSpent(), raisedNative - nativeSeed);
        assertEq(address(token).balance, 0, "all post-V4 native funds seed components");
        assertEq(router.poolsAdded(), 1);
        assertEq(router.routesAdded(), 2);
        assertEq(router.routePoolCount(address(token), address(0)), 1);
        assertEq(router.routePoolCount(address(token), basket.settlementToken()), 2);
        assertEq(basket.lastCreator(), creator);
        assertEq(basket.creations(), 1);
        assertEq(pump.indexTokenOf(address(token)), token.indexToken());
        assertTrue(pump.listingFinalized(address(token)));
        uint256 totalTokens;
        uint256 totalAssets;
        for (uint256 i; i < 2; ++i) {
            (address asset,, address pair) = token.componentAt(i);
            assertFalse(router.hasPricePool(router.pricePoolId(address(token), asset)));
            totalTokens += token.balanceOf(pair);
            totalAssets += Version13Asset(asset).balanceOf(pair);
            assertGt(Version13Pair(pair).balanceOf(token.LP_BURN_ADDRESS()), 0);
        }
        assertEq(totalTokens, 50_000_000 ether);
        assertEq(totalAssets, router.nativeSpent() * 100);
        assertEq(address(token).balance, 0);
    }

    function test_componentPoolTransferTaxAppliesInBothDirectionsAfterListing() public {
        _list();
        (,, address pair) = token.componentAt(0);
        address recipient = makeAddr("componentBuyer");
        uint256 grossAmount = 100 ether;
        uint256 expectedTax = grossAmount * token.COMPONENT_POOL_TAX_BPS() / 10_000;

        uint256 pairBeforeSell = token.balanceOf(pair);
        uint256 burnBefore = token.balanceOf(token.LP_BURN_ADDRESS());
        vm.prank(creator);
        token.transfer(pair, grossAmount);
        assertEq(token.balanceOf(pair) - pairBeforeSell, grossAmount - expectedTax, "sell credits pair net amount");
        assertEq(token.balanceOf(token.LP_BURN_ADDRESS()) - burnBefore, expectedTax, "sell burns token tax");

        uint256 pairBeforeBuy = token.balanceOf(pair);
        uint256 recipientBefore = token.balanceOf(recipient);
        burnBefore = token.balanceOf(token.LP_BURN_ADDRESS());
        vm.prank(pair);
        token.transfer(recipient, grossAmount);
        assertEq(pairBeforeBuy - token.balanceOf(pair), grossAmount, "buy debits pair gross amount");
        assertEq(token.balanceOf(recipient) - recipientBefore, grossAmount - expectedTax, "buyer receives net amount");
        assertEq(token.balanceOf(token.LP_BURN_ADDRESS()) - burnBefore, expectedTax, "buy burns token tax");
    }

    function test_componentPoolTransferFromSpendsGrossAllowanceAndTaxesOnce() public {
        _list();
        (,, address pair) = token.componentAt(0);
        address spender = makeAddr("spender");
        uint256 grossAmount = 100 ether;
        uint256 expectedTax = grossAmount * token.COMPONENT_POOL_TAX_BPS() / 10_000;

        vm.prank(creator);
        token.approve(spender, grossAmount);
        uint256 pairBefore = token.balanceOf(pair);
        uint256 burnBefore = token.balanceOf(token.LP_BURN_ADDRESS());
        vm.prank(spender);
        token.transferFrom(creator, pair, grossAmount);

        assertEq(token.allowance(creator, spender), 0, "allowance consumes gross amount once");
        assertEq(token.balanceOf(pair) - pairBefore, grossAmount - expectedTax);
        assertEq(token.balanceOf(token.LP_BURN_ADDRESS()) - burnBefore, expectedTax, "no recursive second tax");
    }

    function test_regularTransfersRemainUntaxedAfterListing() public {
        _list();
        address recipient = makeAddr("regularRecipient");
        uint256 amount = 100 ether;
        uint256 burnBefore = token.balanceOf(token.LP_BURN_ADDRESS());

        vm.prank(creator);
        token.transfer(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(token.LP_BURN_ADDRESS()), burnBefore);
    }

    function test_buyToCapEntersPendingAndLocksBondingCurve() public {
        _fillToListingPending();
        assertTrue(token.listingPending());
        assertFalse(token.listed());

        vm.prank(creator, creator);
        vm.expectRevert(IToken.TokenListingPending.selector);
        token.buyToken{value: 1 ether}(0, creator, 0);

        vm.prank(creator, creator);
        vm.expectRevert(IToken.TokenListingPending.selector);
        token.sellToken(1 ether, 0, creator, 0);
    }

    function test_onlyKeeperOrOwnerCanFinalizePendingListing() public {
        _fillToListingPending();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IPump.OnlyListingKeeper.selector);
        pump.finalizeTokenListing(address(token), _componentMins(1, 1), block.timestamp);
    }

    function test_failedKeeperMinOutLeavesListingPendingAndCanRetry() public {
        uint160 price = 225060284636549774439465527763777;
        uint128 liquidity = 52804626975085827442929;
        uint256 nativeSeed = SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtRatioAtTick(191940), liquidity, true);
        uint256 tokenSeed = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(-887220), price, liquidity, true);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-int128(int256(nativeSeed)), -int128(int256(tokenSeed))), BalanceDelta.wrap(0))
        );
        _fillToListingPending();

        vm.prank(listingKeeper);
        vm.expectRevert();
        pump.finalizeTokenListing(address(token), _componentMins(type(uint256).max, 1), block.timestamp);
        assertTrue(token.listingPending());
        assertFalse(token.listed());

        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), _componentMins(1, 1), block.timestamp);
        assertFalse(token.listingPending());
        assertTrue(token.listed());
        vm.clearMockedCalls();
    }

    function test_zeroKeeperMinOutIsRejected() public {
        _fillToListingPending();
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(
                toBalanceDelta(-int128(int256(15 ether)), -int128(int256(150_000_000 ether))), BalanceDelta.wrap(0)
            )
        );
        uint256[] memory mins = _componentMins(0, 1);
        vm.prank(listingKeeper);
        vm.expectRevert();
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        vm.clearMockedCalls();
        assertTrue(token.listingPending());
        assertFalse(token.listed());
    }

    function test_ownerCanRecoverFailedListingAndHoldersCanExit() public {
        _fillToListingPending();
        uint256 supplyAtCap = token.bondingCurveSupply();

        vm.prank(creator);
        vm.expectRevert("Ownable: caller is not the owner");
        pump.adminRecoverFailedListing(address(token));

        pump.adminRecoverFailedListing(address(token));
        assertFalse(token.listingPending());
        assertFalse(token.listed());

        vm.prank(creator, creator);
        vm.expectRevert(IToken.TokenListingPending.selector);
        token.buyToken{value: 1 ether}(0, creator, 0);

        uint256 sellAmount = 1_000_000 ether;
        uint256 creatorBnbBefore = creator.balance;
        vm.prank(creator, creator);
        token.sellToken(sellAmount, 0, creator, 0);
        assertGt(creator.balance, creatorBnbBefore);
        assertEq(token.bondingCurveSupply(), supplyAtCap - sellAmount);

        vm.prank(creator, creator);
        token.buyToken{value: 0.01 ether}(0, creator, 0);
        assertGt(token.bondingCurveSupply(), supplyAtCap - sellAmount);
    }

    function test_recoveredFullCapCanRetryListing() public {
        _fillToListingPending();
        pump.adminRecoverFailedListing(address(token));
        assertFalse(token.listingPending());

        uint160 price = 225060284636549774439465527763777;
        uint128 liquidity = 52804626975085827442929;
        uint256 nativeSeed = SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtRatioAtTick(191940), liquidity, true);
        uint256 tokenSeed = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(-887220), price, liquidity, true);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-int128(int256(nativeSeed)), -int128(int256(tokenSeed))), BalanceDelta.wrap(0))
        );
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), _componentMins(1, 1), block.timestamp);
        vm.clearMockedCalls();

        assertTrue(token.listed());
        assertFalse(token.listingPending());
    }

    function test_collectFeesUsesMergedListingPosition() public {
        _list();
        uint256 beforeFee = feeReceiver.balance;
        uint256 beforeCaller = address(this).balance;
        uint256 beforeHook = token.balanceOf(address(hook));
        manager.setMockFees(1 ether, 100 ether);
        token.collectFees();
        assertEq(feeReceiver.balance - beforeFee, 0.995 ether);
        assertEq(address(this).balance - beforeCaller, 0.005 ether);
        assertEq(token.balanceOf(address(hook)) - beforeHook, 100 ether);
    }

    receive() external payable {}
}
