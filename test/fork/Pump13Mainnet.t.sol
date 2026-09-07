// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

interface ForkOwner {
    function owner() external view returns (address);
}

interface ForkCreate {
    function createToken(string calldata, bytes32, IPump.IndexConfig calldata) external payable returns (address);
}

interface ForkRegistry {
    function setRegistrarApproval(address, bool) external;
    function setCreatorForwarderApproval(address, bool) external;
    function isBasket(address) external view returns (bool);
}

interface ForkBasketRouter {
    function buyExactSettlement(address, uint256, uint256, bytes calldata, address) external returns (uint256);
    function sellExactBasket(address, uint256, uint256, bytes calldata, address) external returns (uint256);
}

interface ForkBasket {
    function protocolVersion() external view returns (uint32);
    function assetAt(uint256) external view returns (address, uint16, uint256);
}

interface ForkPair is IERC20 {
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address) external returns (uint256);
    function burn(address) external returns (uint256, uint256);
    function token0() external view returns (address);
    function swap(uint256, uint256, address, bytes calldata) external;
    function sync() external;
}

interface ForkStake {
    function stakeToken() external view returns (address);
    function deposit(uint256) external payable;
    function withdraw(uint256) external payable;
    function getUserStakedAmount(address) external view returns (uint256);
}

contract ForkForceBnb {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

/// @notice Real BSC DEX/assets, current Pump13 and Basket V4 deployments. No broadcast, etch, or DEX mocks.
/// @dev Build ../bsc-basket-contract first. The separate artifacts preserve its OZ5 dependency graph.
contract Pump13MainnetForkTest is Test {
    using PoolIdLibrary for PoolKey;
    address constant LIVE_ROUTER = 0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f;
    address constant MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address constant STAKING_FACTORY = 0xDc3f940ac6Da516d5C9cc59c8AFE0F85A576E2A4;
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address constant AUCTION = 0xfCF8C3cd5dCACb7b911149D1bc5bBCf275975396;
    uint256 constant DEFAULT_BLOCK = 120508054;
    address constant DEAD = address(0xdead);
    Pump pump;
    TagAISwapHook hook;
    NutboxRouter router;
    ForkRegistry registry;
    address basketHook;
    ForkBasketRouter basketRouter;
    HourlyTickCalculator calculator;
    Config.AssetConfig[] assets;
    address creator;
    address keeper;
    address platform;
    uint256 serial;

    receive() external payable {}

    struct BasketFactoryConfig {
        address launcher;
        address auction;
        address deployer;
        address v3Factory;
        address executor;
    }

    // ABI-compatible with BasketHook.TradeData in the separately compiled Basket project.
    struct BasketTradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minSettlementOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 settlementToWbnbSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("PUMP13_FORK_BLOCK", DEFAULT_BLOCK));
        require(block.chainid == 56 && LIVE_ROUTER.code.length > 0, "WRONG_FORK");
        creator = makeAddr("pump13-mainnet-creator");
        keeper = makeAddr("pump13-keeper");
        platform = makeAddr("platform");
        vm.deal(creator, 100_000 ether);
        vm.deal(address(this), 100_000 ether);
        Config.AssetConfig[] memory seeds = Config.assetConfigs();
        for (uint256 i; i < seeds.length; ++i) {
            bool available = INutboxRouter(LIVE_ROUTER).hasRoute(seeds[i].token, Config.wrappedNative())
                && INutboxRouter(LIVE_ROUTER).hasRoute(seeds[i].token, Config.settlementToken());
            // The original 14 assets are mandatory. New catalog additions need not have
            // existed at the pinned block; do not invent their historical registration.
            if (!available) {
                require(i >= 14, "PINNED_ASSET_ROUTE_MISSING");
                console2.log("not registered at fork block", seeds[i].symbol);
                continue;
            }
            assets.push(seeds[i]);
        }
        _importRouter();
        _deployBasket();
        calculator = new HourlyTickCalculator(COMMUNITY_FACTORY);
        vm.prank(ForkOwner(COMMITTEE).owner());
        ICommittee(COMMITTEE).adminAddContract(address(calculator));
        // Permission setup is simulated on the fork, exactly as an authorized deployment must do.
        vm.prank(ForkOwner(COMMITTEE).owner());
        ICommittee(COMMITTEE).adminAddContract(STAKING_FACTORY);
        pump = new Pump(IPSHARE, platform, _defaultConstituents());
        pump.adminSetPoolManager(MANAGER);
        pump.adminSetVault(VAULT);
        hook = new TagAISwapHook(ICLPoolManager(MANAGER), IVault(VAULT), address(pump));
        pump.adminSetHookAddress(address(hook));
        pump.adminSetNutbox(COMMUNITY_FACTORY, address(calculator), STAKING_FACTORY, COMMITTEE);
        pump.adminSetIndexInfrastructure(
            address(router), basketHook, Config.pancakeV2Factory(), Config.settlementToken()
        );
        pump.adminSetListingKeeper(keeper);
        router.addOperator(address(pump));
        registry.setCreatorForwarderApproval(address(pump), true);
        pump.adminSetBuybackRouter(
            address(
                new TagAIBuybackRouter(address(pump), address(router), address(basketRouter), Config.settlementToken())
            )
        );
    }

    function _defaultConstituents() internal view returns (address[] memory tokens) {
        tokens = new address[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            tokens[i] = assets[i].token;
        }
    }

    function _one(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _importRouter() internal {
        router = new NutboxRouter(
            Config.wrappedNative(),
            Config.pancakeV3Router(),
            _one(Config.pancakeV2Router()),
            _one(Config.pancakeV2Factory()),
            _one(Config.pancakeV3Factory()),
            new address[](0),
            _one(MANAGER),
            ""
        );
        INutboxRouter live = INutboxRouter(LIVE_ROUTER);
        // Asset addresses are discovery seeds only; sourceData and ordered routes come from live storage.
        for (uint256 i; i < assets.length; ++i) {
            _copyRoute(live, assets[i].token, Config.wrappedNative());
            _copyRoute(live, assets[i].token, Config.settlementToken());
        }
        _copyRoute(live, Config.wrappedNative(), Config.settlementToken());
    }

    function _copyRoute(INutboxRouter live, address a, address b) internal {
        require(live.hasRoute(a, b), "LIVE_ROUTE_MISSING");
        uint256 n = live.routePoolCount(a, b);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 j; j < n; ++j) {
            ids[j] = live.routePoolAt(a, b, j);
            if (!router.hasPricePool(ids[j])) {
                (bool enabled,,,, INutboxRouter.SourceType kind, bytes memory data) = live.pricePool(ids[j]);
                require(enabled, "DISABLED_LIVE_POOL");
                assertEq(router.addPricePool(kind, data), ids[j]);
            }
        }
        router.addRoute(a, b, ids);
    }

    function _artifact(string memory name, bytes memory args) internal returns (address) {
        return deployCode(string.concat("../bsc-basket-contract/out/", name, ".sol/", name, ".json"), args);
    }

    function _deployBasket() internal {
        registry = ForkRegistry(_artifact("BasketRegistry", abi.encode(address(this))));
        PoolKey memory hub = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(Config.settlementToken()),
            IHooks(address(0)),
            IPoolManager(MANAGER),
            67,
            bytes32(uint256(1) << 16)
        );
        address routes = _artifact("BasketRouteRegistry", abi.encode(MANAGER, address(0), hub));
        address executor = _artifact(
            "BasketRebalanceExecutor",
            abi.encode(
                MANAGER,
                address(registry),
                routes,
                Config.settlementToken(),
                address(0),
                Config.wrappedNative(),
                Config.pancakeV3Factory(),
                Config.pancakeV2Factory(),
                address(router)
            )
        );
        address deployer = _artifact("BasketTokenDeployerV4", "");
        basketHook = _artifact(
            "BasketHook",
            abi.encode(
                MANAGER,
                address(registry),
                routes,
                Config.settlementToken(),
                Config.wrappedNative(),
                BasketFactoryConfig(platform, AUCTION, deployer, Config.pancakeV3Factory(), executor)
            )
        );
        registry.setRegistrarApproval(basketHook, true);
        basketRouter =
            ForkBasketRouter(_artifact("BasketSwapRouter", abi.encode(MANAGER, basketHook, Config.settlementToken())));
        registry.setCreatorForwarderApproval(address(basketRouter), true);
    }

    function _config(uint256 start, uint256 n, bool retain) internal view returns (IPump.IndexConfig memory c) {
        c.name = "Mainnet stock index";
        c.symbol = "MFI";
        c.constituentAssets = new address[](n);
        c.targetWeights = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            c.constituentAssets[i] = assets[(start + i) % assets.length].token;
            c.targetWeights[i] = uint16(i + 1 == n ? 10000 - (10000 / n) * (n - 1) : 10000 / n);
        }
        c.basketFeeBps = 100;
        c.creatorShareBps = 3000;
        c.retainCommunityOwnership = retain;
    }

    function _create(IPump.IndexConfig memory c) internal returns (Token t) {
        uint256 ipFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 fee = pump.createFee() + ipFee + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * c.constituentAssets.length;
        uint256 gasBefore = gasleft();
        vm.prank(creator, creator);
        t = Token(payable(pump.createToken{value: fee}(string.concat("F", vm.toString(++serial)), bytes32(serial), c)));
        console2.log("create gas", gasBefore - gasleft());
        assertTrue(IIPShare(IPSHARE).ipshareCreated(creator));
        assertEq(ForkOwner(t.nutboxCommunity()).owner(), c.retainCommunityOwnership ? creator : address(0));
        for (uint256 i; i < c.constituentAssets.length; ++i) {
            (,, address pair) = t.componentAt(i);
            address staking = ICommunity(t.nutboxCommunity()).activedPools(i);
            assertEq(ForkStake(staking).stakeToken(), pair);
            assertEq(IERC20(pair).totalSupply(), 0);
        }
    }

    function _fill(Token t) internal {
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        t.buyToken{value: 100 ether}(0, creator, 0);
        assertTrue(t.listingPending());
        assertFalse(t.listed());
        assertEq(t.bondingCurveSupply(), 650_000_000 ether);
    }

    function _mins(Token t) internal view returns (uint256[] memory m) {
        m = new uint256[](t.componentCount());
        uint256 budget = t.componentListingNativeBudget();
        uint256 allocated;
        for (uint256 i; i < m.length; ++i) {
            (address a, uint16 w,) = t.componentAt(i);
            uint256 input = i + 1 == m.length ? budget - allocated : budget * w / 10000;
            allocated += input;
            m[i] = router.quote(address(0), a, input) * 95 / 100;
            require(m[i] > 0, "DUST_QUOTE");
        }
    }

    function _list(Token t) internal {
        uint256[] memory m = _mins(t);
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        console2.log("list gas", gasBefore - gasleft());
        assertTrue(t.listed());
        assertFalse(t.listingPending());
        assertTrue(registry.isBasket(t.indexToken()));
        assertEq(ForkBasket(t.indexToken()).protocolVersion(), 4);
        assertEq(t.balanceOf(address(hook)), 150_000_000 ether);
        uint256 total;
        for (uint256 i; i < m.length; ++i) {
            (address a,, address pair) = t.componentAt(i);
            total += t.balanceOf(pair);
            assertGt(IERC20(a).balanceOf(pair), 0);
            assertEq(IERC20(pair).balanceOf(DEAD), IERC20(pair).totalSupply() - 1000);
            assertFalse(router.hasPricePool(router.pricePoolId(address(t), a)));
        }
        assertEq(total, 50_000_000 ether);
        router.validateRoute(address(t), address(0));
        router.validateRoute(address(t), Config.settlementToken());
        assertEq(IVault(VAULT).getUnsettledDeltasCount(), 0);
        assertEq(address(t).balance, 0);
    }

    function test_importedLiveRoutesMatchQuotes() public view {
        INutboxRouter live = INutboxRouter(LIVE_ROUTER);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(
                router.quote(address(0), assets[i].token, 0.01 ether),
                live.quote(address(0), assets[i].token, 0.01 ether)
            );
            assertEq(
                router.routePoolCount(assets[i].token, address(0)), live.routePoolCount(assets[i].token, address(0))
            );
        }
    }

    function _singleAsset(uint256 i) internal {
        console2.log("asset", assets[i].symbol);
        Token t = _create(_config(i, 1, i % 2 == 0));
        _fill(t);
        _list(t);
    }

    // Separate cases ensure one broken asset does not prevent the remaining assets from being exercised.
    function test_asset_ETH() public {
        _singleAsset(0);
    }

    function test_asset_BTCB() public {
        _singleAsset(1);
    }

    function test_asset_QQQB() public {
        _singleAsset(2);
    }

    function test_asset_SPCXB() public {
        _singleAsset(3);
    }

    function test_asset_AAPLB() public {
        _singleAsset(4);
    }

    function test_asset_SKHYB() public {
        _singleAsset(5);
    }

    function test_asset_SPYB() public {
        _singleAsset(6);
    }

    function test_asset_XAUt() public {
        _singleAsset(7);
    }

    function test_asset_NVDAB() public {
        _singleAsset(8);
    }

    function test_asset_TSLAB() public {
        _singleAsset(9);
    }

    function test_asset_MSFTB() public {
        _singleAsset(10);
    }

    function test_asset_HOODB() public {
        _singleAsset(11);
    }

    function test_asset_BABAB() public {
        _singleAsset(12);
    }

    function test_asset_GMEB() public {
        _singleAsset(13);
    }

    function test_sameCreatorMultipleTokensAndIPShareReuse() public {
        assertFalse(IIPShare(IPSHARE).ipshareCreated(creator));
        Token a = _create(_config(2, 2, true));
        Token b = _create(_config(7, 1, false));
        _fill(a);
        _list(a);
        _fill(b);
        _list(b);
        assertTrue(a.indexToken() != b.indexToken());
        assertTrue(a.nutboxCommunity() != b.nutboxCommunity());
        assertEq(a.balanceOf(address(b)), 0);
        assertEq(b.balanceOf(address(a)), 0);
    }

    function test_componentDonationAndSyncBeforeList() public {
        Token t = _create(_config(7, 1, true));
        (address a,, address p) = t.componentAt(0);
        uint256 bought =
            router.swapExactInput{value: 0.01 ether}(address(0), a, 0.01 ether, 1, address(this), block.timestamp + 60);
        IERC20(a).transfer(p, bought);
        ForkPair(p).sync();
        _fill(t);
        vm.prank(creator);
        vm.expectRevert(IToken.TokenNotListed.selector);
        t.transfer(p, 1 ether);
        _list(t);
    }

    function test_realFrontRunRejectsStaleKeeperMinimum() public {
        Token t = _create(_config(4, 1, true));
        _fill(t);
        uint256[] memory m = _mins(t);
        uint256 beforeBnb = address(t).balance;
        // Move the actual stock pool in bounded increments. A huge single V3 trade
        // can exhaust liquidity and scan thousands of empty tick words on the RPC.
        uint256 spent;
        uint256 budget = t.componentListingNativeBudget();
        while (router.quote(address(0), assets[4].token, budget) >= m[0] * 99 / 100 && spent < 200 ether) {
            router.swapExactInput{value: 1 ether}(
                address(0), assets[4].token, 1 ether, 1, address(this), block.timestamp + 60
            );
            spent += 1 ether;
        }
        console2.log("front-run BNB spent", spent);
        assertLt(router.quote(address(0), assets[4].token, budget), m[0] * 99 / 100, "price did not move enough");
        vm.prank(keeper);
        vm.expectRevert();
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        assertTrue(t.listingPending());
        assertEq(address(t).balance, beforeBnb);
        assertEq(t.indexToken(), address(0));
        pump.adminRecoverFailedListing(address(t));
        vm.prank(creator);
        t.sellToken(1_000_000 ether, 0, creator, 0);
    }

    function test_nativeDustUsesActualRemainingBalance() public {
        Token t = _create(_config(2, 3, true));
        _fill(t);
        // Token's receive restricts callers; forced native transfers can still add dust.
        new ForkForceBnb{value: 0.0123456789 ether}(payable(address(t)));
        _list(t);
        assertEq(address(t).balance, 0);
    }

    function test_fourComponentsIncludingSixDecimalGold() public {
        Token t = _create(_config(4, 4, true));
        _fill(t);
        _list(t);
    }

    function test_fourComponentsOneBpsMinorLegs() public {
        IPump.IndexConfig memory c = _config(4, 4, false);
        for (uint256 i; i < 4; ++i) {
            c.targetWeights[i] = i == 0 ? 9997 : 1;
        }
        c.basketFeeBps = 300;
        c.creatorShareBps = 0;
        Token t = _create(c);
        _fill(t);
        _list(t);
    }

    function _gasBoundedCreate(uint256 count, uint256 allowance) internal returns (bool ok, bytes memory result) {
        IPump.IndexConfig memory c = _config(2, count, true);
        uint256 fee = pump.createFee() + IIPShare(IPSHARE).createFee() + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * count;
        bytes memory payload = abi.encodeCall(ForkCreate.createToken, ("GAS", bytes32(uint256(123)), c));
        vm.prank(creator, creator);
        (ok, result) = address(pump).call{value: fee, gas: allowance}(payload);
    }

    function test_fourComponentsFitConservativeTransactionGasBudget() public {
        // Reserve 177,216 gas for transaction intrinsic cost and external call overhead.
        (bool ok, bytes memory result) = _gasBoundedCreate(4, 16_600_000);
        assertTrue(ok, "four-component creation exceeds conservative budget");
        Token t = Token(payable(abi.decode(result, (address))));
        assertEq(t.componentCount(), 4);
        _fill(t);
        _list(t);
    }

    function _assertExcessComponentsRejected(uint256 count) internal {
        uint256 beforeBalance = creator.balance;
        // Reject before creating IPShare, Token, community, or pairs, not by running out of gas.
        (bool ok, bytes memory result) = _gasBoundedCreate(count, 200_000);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(IPump.InvalidIndexConfig.selector));
        assertEq(creator.balance, beforeBalance);
        assertFalse(IIPShare(IPSHARE).ipshareCreated(creator));
        assertFalse(pump.createdTicks("GAS"));
    }

    function test_fiveComponentsRejectedBeforeCreation() public {
        _assertExcessComponentsRejected(5);
    }

    function test_tenComponentsRejectedBeforeCreation() public {
        _assertExcessComponentsRejected(10);
    }

    function test_lastLegSlippageRollsBackThenRecoveryAndRetry() public {
        Token t = _create(_config(2, 3, true));
        _fill(t);
        uint256 beforeBnb = address(t).balance;
        uint256 beforeT = t.balanceOf(address(t));
        uint256[] memory m = _mins(t);
        m[m.length - 1] = type(uint256).max;
        vm.prank(keeper);
        vm.expectRevert();
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        assertEq(address(t).balance, beforeBnb);
        assertEq(t.balanceOf(address(t)), beforeT);
        assertEq(t.balanceOf(address(hook)), 0);
        assertEq(t.indexToken(), address(0));
        assertTrue(t.listingPending());
        for (uint256 i; i < m.length; ++i) {
            (address a,, address p) = t.componentAt(i);
            assertEq(IERC20(a).balanceOf(p), 0);
            assertEq(t.balanceOf(p), 0);
        }
        pump.adminRecoverFailedListing(address(t));
        vm.prank(creator, creator);
        t.sellToken(1_000_000 ether, 0, creator, 0);
        assertLt(t.bondingCurveSupply(), 650_000_000 ether);
        _fill(t);
        _list(t);
    }

    function test_missingRouterPermissionRollsBackAndRetries() public {
        Token t = _create(_config(4, 2, true));
        _fill(t);
        uint256[] memory m = _mins(t);
        router.removeOperator(address(pump));
        vm.prank(keeper);
        vm.expectRevert(NutboxRouter.NotOwnerOrOperator.selector);
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        assertTrue(t.listingPending());
        assertEq(t.balanceOf(address(hook)), 0);
        router.addOperator(address(pump));
        _list(t);
    }

    function test_missingBasketPermissionRollsBackAllRegistrations() public {
        Token t = _create(_config(4, 2, true));
        _fill(t);
        uint256[] memory m = _mins(t);
        registry.setCreatorForwarderApproval(address(pump), false);
        vm.prank(keeper);
        vm.expectRevert();
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        assertTrue(t.listingPending());
        assertEq(t.balanceOf(address(hook)), 0);
        assertFalse(router.hasRoute(address(t), address(0)));
        registry.setCreatorForwarderApproval(address(pump), true);
        _list(t);
    }

    function test_deadlineAndUnauthorizedKeeper() public {
        Token t = _create(_config(7, 1, true));
        _fill(t);
        uint256[] memory m = _mins(t);
        vm.prank(creator);
        vm.expectRevert(IPump.OnlyListingKeeper.selector);
        pump.finalizeTokenListing(address(t), m, block.timestamp + 60);
        vm.prank(keeper);
        vm.expectRevert(IToken.ListingDeadlineExpired.selector);
        pump.finalizeTokenListing(address(t), m, block.timestamp - 1);
        _list(t);
    }

    function test_pumpManagerAndHookChangesDoNotBreakExistingToken() public {
        Token t = _create(_config(2, 2, true));
        pump.adminSetHookAddress(address(123));
        pump.adminSetPoolManager(address(456));
        pump.adminSetVault(address(789));
        _fill(t);
        _list(t);
    }

    function _buybackData(Token t, bytes memory basketData) internal view returns (bytes memory) {
        uint256 minimum =
            router.quote(address(0), Config.settlementToken(), hook.buybackBnbReserve(address(t))) * 95 / 100;
        require(minimum > 0, "ZERO_SETTLEMENT_MINIMUM");
        return abi.encode(minimum, basketData);
    }

    function _buyT(Token t, uint256 bnb) internal returns (uint256) {
        return router.swapExactInput{value: bnb}(address(0), address(t), bnb, 1, address(this), block.timestamp + 60);
    }

    function test_v4FeesActualBuybackClaimsAndBasketRedeem() public {
        Token t = _create(_config(2, 2, true));
        _fill(t);
        _list(t);
        uint256 beforePlatform = platform.balance;
        uint256 bought = _buyT(t, 0.1 ether);
        assertGt(bought, 0);
        assertEq(platform.balance - beforePlatform, 0.0003 ether);
        assertEq(hook.buybackBnbReserve(address(t)), 0.0003 ether);
        // A second token's reserve must not receive fees from this pool.
        Token second = _create(_config(7, 1, false));
        assertEq(hook.buybackBnbReserve(address(second)), 0);
        // First mint requires per-leg minimums. An empty payload must roll back the
        // BNB reserve and all intermediate swaps, leaving the buyback retryable.
        vm.expectRevert();
        hook.executeBuyback(address(t), 1, block.timestamp + 60, "");
        assertEq(hook.buybackBnbReserve(address(t)), 0.0003 ether);
        assertEq(IERC20(t.indexToken()).totalSupply(), 0);
        BasketTradeData memory data;
        data.legMins = new uint256[](t.componentCount());
        for (uint256 i; i < data.legMins.length; ++i) {
            data.legMins[i] = 1;
        }
        data.legSqrtPriceLimitsX96 = new uint160[](0);
        data.allowFailedLegs = new bool[](t.componentCount());
        // Minimal nonzero bounds exercise real settlement, not a keeper pricing policy.
        beforePlatform = platform.balance;
        uint256 indexOut = hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, abi.encode(data)));
        assertGt(indexOut, 0);
        // Basket purchases traverse T-BNB again and generate fresh, equally split fees.
        uint256 newReserve = hook.buybackBnbReserve(address(t));
        assertGt(newReserve, 0);
        assertLt(newReserve, 0.0003 ether);
        assertEq(newReserve, platform.balance - beforePlatform);
        assertEq(address(hook).balance, newReserve);
        assertEq(IERC20(t.indexToken()).balanceOf(address(t)), indexOut);
        uint256 holderBefore = IERC20(t.indexToken()).balanceOf(creator);
        t.claimBuybackReward(creator);
        assertGt(IERC20(t.indexToken()).balanceOf(creator), holderBefore);
        for (uint256 i; i < t.componentCount(); ++i) {
            (,, address pair) = t.componentAt(i);
            assertEq(t.pendingBuybackReward(pair), 0);
        }
        assertEq(t.pendingBuybackReward(DEAD), 0);
        t.claimBuybackReward(address(this));
        uint256 shares = IERC20(t.indexToken()).balanceOf(address(this));
        IERC20(t.indexToken()).approve(address(basketRouter), shares);
        uint256 u = basketRouter.sellExactBasket(t.indexToken(), shares, 1, "", address(this));
        assertGt(u, 0);
        t.approve(address(router), bought / 2);
        assertGt(router.swapExactInput(address(t), address(0), bought / 2, 1, address(this), block.timestamp + 60), 0);
        assertEq(IVault(VAULT).getUnsettledDeltasCount(), 0);
    }

    function test_hookExternalTopupAndRealLPStaking() public {
        Token t = _create(_config(7, 1, true));
        _fill(t);
        _list(t);
        _buyT(t, 0.1 ether);
        uint256 hookBefore = t.balanceOf(address(hook));
        t.transfer(address(hook), 100 ether);
        assertEq(t.balanceOf(address(hook)), hookBefore + 100 ether);
        vm.warp((block.timestamp / 600 + 1) * 600);
        _buyT(t, 0.01 ether);
        assertGt(calculator.totalInjected(t.nutboxCommunity()), 0);
        (address a,, address p) = t.componentAt(0);
        uint256 tIn = t.balanceOf(address(this)) / 10;
        uint256 aIn = IERC20(a).balanceOf(p) * tIn / t.balanceOf(p);
        router.swapExactInput{value: 0.1 ether}(address(0), a, 0.1 ether, aIn, address(this), block.timestamp + 60);
        uint256 deadBefore = t.balanceOf(DEAD);
        t.transfer(p, tIn);
        IERC20(a).transfer(p, aIn);
        uint256 lp = ForkPair(p).mint(address(this));
        assertEq(t.balanceOf(DEAD) - deadBefore, tIn / 1000);
        address stake = ICommunity(t.nutboxCommunity()).activedPools(0);
        IERC20(p).approve(stake, lp);
        ForkStake(stake).deposit{value: ICommittee(COMMITTEE).getPoolOperationFee()}(lp);
        assertEq(ForkStake(stake).getUserStakedAmount(address(this)), lp);
        ForkStake(stake).withdraw{value: ICommittee(COMMITTEE).getPoolOperationFee()}(lp);
        assertEq(ForkStake(stake).getUserStakedAmount(address(this)), 0);
        assertEq(IERC20(p).balanceOf(address(this)), lp);
        uint256 tBefore = t.balanceOf(address(this));
        deadBefore = t.balanceOf(DEAD);
        IERC20(p).transfer(p, lp);
        (uint256 out0, uint256 out1) = ForkPair(p).burn(address(this));
        uint256 grossT = ForkPair(p).token0() == address(t) ? out0 : out1;
        assertEq(t.balanceOf(address(this)) - tBefore, grossT - grossT / 1000);
        assertEq(t.balanceOf(DEAD) - deadBefore, grossT / 1000);
    }

    function _v2Swap(ForkPair p, address input, address output, uint256 amount) internal returns (uint256 netOut) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool input0 = p.token0() == input;
        uint256 reserveIn = input0 ? r0 : r1;
        uint256 reserveOut = input0 ? r1 : r0;
        IERC20(input).transfer(address(p), amount);
        // An aggregator must calculate from actual receipt when T is the taxed input.
        uint256 actualIn = IERC20(input).balanceOf(address(p)) - reserveIn;
        uint256 grossOut = actualIn * 9975 * reserveOut / (reserveIn * 10000 + actualIn * 9975);
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        p.swap(input0 ? 0 : grossOut, input0 ? grossOut : 0, address(this), "");
        netOut = IERC20(output).balanceOf(address(this)) - beforeOut;
        assertGt(netOut, 0);
    }

    function test_splitV4AndV2ExecutionTaxesBothV2Directions() public {
        Token t = _create(_config(4, 1, true));
        _fill(t);
        _list(t);
        (address a,, address pair) = t.componentAt(0);
        _buyT(t, 0.02 ether);
        uint256 reserveBefore = hook.buybackBnbReserve(address(t));
        uint256 stock =
            router.swapExactInput{value: 0.02 ether}(address(0), a, 0.02 ether, 1, address(this), block.timestamp + 60);
        uint256 deadBefore = t.balanceOf(DEAD);
        uint256 pairBefore = t.balanceOf(pair);
        uint256 netBought = _v2Swap(ForkPair(pair), a, address(t), stock);
        uint256 grossBought = pairBefore - t.balanceOf(pair);
        assertEq(netBought, grossBought - grossBought / 1000);
        assertEq(t.balanceOf(DEAD) - deadBefore, grossBought / 1000);
        deadBefore = t.balanceOf(DEAD);
        _v2Swap(ForkPair(pair), address(t), a, netBought);
        assertEq(t.balanceOf(DEAD) - deadBefore, netBought / 1000);
        // Component V2 trades burn T but do not add a Hook BNB buyback fee.
        assertEq(hook.buybackBnbReserve(address(t)), reserveBefore);
        assertEq(IVault(VAULT).getUnsettledDeltasCount(), 0);
    }
}
