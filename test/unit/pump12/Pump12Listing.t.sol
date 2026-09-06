// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {Token12} from "../../../src/pump12/Token12.sol";
import {NetNetHook} from "../../../src/pump12/NetNetHook.sol";
import {PermanentLiquidityVault} from "../../../src/pump12/PermanentLiquidityVault.sol";
import {BurnNet} from "../../../src/pump12/burnnet/BurnNet.sol";
import {Treasury} from "../../../src/pump12/treasury/Treasury.sol";
import {SToken} from "../../../src/pump12/staking/SToken.sol";
import {Staking} from "../../../src/pump12/staking/Staking.sol";
import {Distributor} from "../../../src/pump12/distributor/Distributor.sol";
import {BondDepository} from "../../../src/pump12/bond/BondDepository.sol";
import {PremiumSeller} from "../../../src/pump12/premium/PremiumSeller.sol";
import {PTeam} from "../../../src/pump12/pteam/PTeam.sol";
import {IndexBondDesk} from "../../../src/pump12/pteam/IndexBondDesk.sol";
import {IndexFundV1} from "../../../src/pump12/fund/IndexFundV1.sol";
import {IndexFundFactory} from "../../../src/pump12/fund/IndexFundFactory.sol";
import {
    Pump12TestBasketRegistry,
    Pump12TestWETH,
    Pump12TestBasket,
    Pump12TestBasketHookConfig,
    Pump12TestBasketRouter,
    Pump12TestRouteRegistry
} from "./Pump12IndexTestHelpers.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract ListingTestUsdG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Pump12ListingTest is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    address internal indexToken;
    address internal pTeamHolder = makeAddr("pTeamHolder");

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    Pump12 internal pump;
    NetNetHook internal hook;
    Token12 internal token;

    function setUp() public {
        vm.chainId(RH_CHAIN_ID);

        ListingTestUsdG usdgImplementation = new ListingTestUsdG();
        vm.etch(USDG, address(usdgImplementation).code);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), POOL_MANAGER);
        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);

        Pump12TestWETH weth = new Pump12TestWETH();
        Pump12TestBasket basket = new Pump12TestBasket(address(weth));
        Pump12TestBasketRegistry basketRegistry = new Pump12TestBasketRegistry();
        basketRegistry.setBasket(address(basket), true);
        Pump12TestRouteRegistry routeRegistry = new Pump12TestRouteRegistry(manager, USDG);
        Pump12TestBasketHookConfig basketHookConfig = new Pump12TestBasketHookConfig(
            manager, address(basketRegistry), address(routeRegistry), USDG, address(weth)
        );
        Pump12TestBasketRouter basketRouter = new Pump12TestBasketRouter(manager, USDG, address(basketHookConfig));
        indexToken = address(basket);

        vm.prank(tagAI);
        pump = new Pump12(USDG, POOL_MANAGER);
        hook = _deployHook();
        vm.prank(tagAI);
        pump.setHook(address(hook));
        Treasury treasuryImplementation = new Treasury();
        SToken sTokenImplementation = new SToken();
        Staking stakingImplementation = new Staking();
        Distributor distributorImplementation = new Distributor();
        BondDepository bondImplementation = new BondDepository();
        PremiumSeller premiumImplementation = new PremiumSeller();
        vm.prank(tagAI);
        pump.setEmissionImplementations(
            address(treasuryImplementation),
            address(sTokenImplementation),
            address(stakingImplementation),
            address(distributorImplementation),
            address(bondImplementation),
            address(premiumImplementation)
        );
        IndexFundV1 indexFundImplementation = new IndexFundV1();
        IndexFundFactory indexFundFactory = new IndexFundFactory(
            address(pump),
            tagAI,
            USDG,
            POOL_MANAGER,
            address(weth),
            address(basketRegistry),
            address(basketRouter),
            address(routeRegistry),
            address(indexFundImplementation)
        );
        PTeam pTeamImplementation = new PTeam();
        IndexBondDesk indexBondDeskImplementation = new IndexBondDesk();
        vm.prank(tagAI);
        pump.setPTeamImplementations(
            address(pTeamImplementation), address(indexBondDeskImplementation), address(indexFundFactory)
        );

        vm.prank(creator);
        token = Token12(pump.createToken(_params()));

        ListingTestUsdG(USDG).mint(buyer, 30_000e6);
        vm.prank(buyer);
        ListingTestUsdG(USDG).approve(address(token), type(uint256).max);
    }

    function test_listRevertsBeforeCurveIsFull() public {
        vm.expectRevert(Pump12.CurveNotComplete.selector);
        pump.list(address(token));
    }

    function test_createRejectsIndexOutsideConfiguredRegistry() public {
        Pump12.CreateParams memory invalid = _params(bytes32("bad-index"), "BADIDX");
        invalid.indexToken = address(new Pump12TestBasket(makeAddr("otherWeth")));
        vm.expectRevert(Pump12.InvalidIndexToken.selector);
        vm.prank(creator);
        pump.createToken(invalid);
    }

    function test_listLocksBasePOLAndPreservesFeeLiabilities() public {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);

        uint256 feeLiabilities = token.claimableTagAI() + token.claimableCreator();
        (PoolId poolId, address vaultAddress) = pump.list(address(token));
        PermanentLiquidityVault vault = PermanentLiquidityVault(vaultAddress);

        assertTrue(token.listed());
        assertEq(token.curveReserveRaw(), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(token)), feeLiabilities);
        assertEq(token.liquidityVault(), vaultAddress);
        assertEq(token.v4PoolId(), PoolId.unwrap(poolId));
        assertEq(token.initialAnchor(), token.curveEndPrice());
        assertEq(token.listTime(), block.timestamp);

        assertTrue(vault.initialized());
        assertGt(vault.lockedLiquidity(), 0);
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(poolId));
        assertApproxEqAbs(vault.polTokenInventory(), vault.tokenUsed(), 1);

        (uint128 positionLiquidity,,) =
            manager.getPositionInfo(poolId, vaultAddress, vault.TICK_LOWER(), vault.TICK_UPPER(), vault.BASE_LP_SALT());
        assertEq(positionLiquidity, vault.lockedLiquidity());
        assertEq(hook.poolToken(poolId), address(token));
        assertEq(token.burnNet(), pump.tokenBurnNet(address(token)));
        assertEq(hook.poolBurnNet(poolId), token.burnNet());
    }

    function test_listingWiresEmissionModulesAndTreasuryIsSoleMinter() public {
        _fillAndList();
        (
            address treasuryAddress,
            address sTokenAddress,
            address stakingAddress,
            address distributorAddress,
            address bondAddress,
            address premiumAddress,
            address pTeamAddress,
            address indexBondDeskAddress,
            address indexFundAddress
        ) = pump.tokenEmissionModules(address(token));
        Treasury treasury = Treasury(treasuryAddress);
        SToken sToken = SToken(sTokenAddress);
        Staking staking = Staking(stakingAddress);
        Distributor distributor = Distributor(distributorAddress);

        assertEq(token.treasury(), treasuryAddress);
        assertEq(treasury.token(), address(token));
        assertEq(treasury.burnNet(), token.burnNet());
        assertEq(treasury.distributor(), distributorAddress);
        assertEq(address(staking.token()), address(token));
        assertEq(address(staking.sToken()), sTokenAddress);
        assertEq(address(staking.distributor()), distributorAddress);
        assertEq(sToken.staking(), stakingAddress);
        assertEq(address(distributor.treasury()), treasuryAddress);
        assertEq(distributor.staking(), stakingAddress);
        assertEq(treasury.bondDepository(), bondAddress);
        assertEq(treasury.premiumSeller(), premiumAddress);
        assertEq(treasury.pTeam(), pTeamAddress);
        assertGt(indexBondDeskAddress.code.length, 0);
        assertGt(indexFundAddress.code.length, 0);

        vm.expectRevert(Token12.OnlyTreasury.selector);
        token.mint(address(this), 1);
        vm.expectRevert(Treasury.OnlyDistributor.selector);
        treasury.mintByDistributor(address(this), 1);
    }

    function test_realDistributorQueuesThenRebasesRewardToStakers() public {
        (PoolId poolId,) = _fillAndList();
        (address treasuryAddress, address sTokenAddress, address stakingAddress, address distributorAddress,,,,,) =
            pump.tokenEmissionModules(address(token));
        Treasury treasury = Treasury(treasuryAddress);
        SToken sToken = SToken(sTokenAddress);
        Staking staking = Staking(stakingAddress);
        Distributor distributor = Distributor(distributorAddress);

        uint256 principal = 100_000_000e18;
        vm.startPrank(buyer);
        token.approve(stakingAddress, principal);
        staking.stake(buyer, principal);
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        uint256 supplyBefore = token.totalSupply();
        staking.rebase();
        (,,, uint256 queued) = staking.epoch();

        assertGt(distributor.currentRateWad(), 0);
        assertLt(distributor.currentRateWad(), distributor.MAX_RATE_WAD());
        assertGt(queued, 0);
        assertEq(token.totalSupply(), supplyBefore + queued);
        assertEq(treasury.mintedByDistributor(), queued);
        assertEq(sToken.balanceOf(buyer), principal);

        uint40 secondStart = start + 8 hours + 1;
        _checkpointFor(poolId, secondStart, 16);
        vm.warp(secondStart + 8 hours + 1);
        staking.rebase();

        assertApproxEqAbs(sToken.balanceOf(buyer), principal + queued, 1);
        assertEq(distributor.totalMinted(), treasury.mintedByDistributor());
    }

    function test_bondDepositoryDiscountPendingClassificationAndVesting() public {
        (PoolId poolId,) = _fillAndList();
        (address treasuryAddress,,,, address bondAddress,,,,) = pump.tokenEmissionModules(address(token));
        Treasury treasury = Treasury(treasuryAddress);
        BondDepository bond = BondDepository(bondAddress);

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        uint256 twap = hook.validTWAP(poolId);
        uint256 expectedPrice = Math.max(twap * 9_700 / 10_000, BurnNet(token.burnNet()).anchor());
        assertEq(bond.bondPrice(), expectedPrice);

        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(bondAddress, 100e6);
        vm.expectRevert(abi.encodeWithSelector(BondDepository.PriceAboveMax.selector, expectedPrice, expectedPrice - 1));
        bond.deposit(100e6, expectedPrice - 1, trader);
        (uint256 noteId, uint256 payout) = bond.deposit(100e6, expectedPrice, trader);
        vm.stopPrank();

        assertEq(hook.pendingUSDG(poolId), 100e6);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 0);
        assertEq(treasury.mintedByBond(), payout);
        assertEq(token.balanceOf(bondAddress), payout);
        assertEq(bond.noteCount(trader), 1);

        BondDepository.Note memory createdNote = bond.note(trader, noteId);
        vm.warp(createdNote.start + 1 days);
        vm.prank(trader);
        uint256 halfPaid = bond.redeem(noteId, trader);
        assertApproxEqAbs(halfPaid, payout / 2, 1);
        vm.warp(createdNote.end);
        vm.prank(trader);
        uint256 remainder = bond.redeem(noteId, trader);
        assertEq(halfPaid + remainder, payout);
        assertEq(token.balanceOf(bondAddress), 0);
    }

    function test_premiumSellerUsesPolClipIsFeeExemptAndFundsBurnNet() public {
        (PoolId poolId, address vaultAddress) = _fillAndList();
        (address treasuryAddress,,,,, address premiumAddress,,,) = pump.tokenEmissionModules(address(token));
        Treasury treasury = Treasury(treasuryAddress);
        PremiumSeller premium = PremiumSeller(premiumAddress);

        ListingTestUsdG(USDG).mint(trader, 12_000e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(_poolKey(), _usdgIsCurrency0(), -int256(10_000e6));
        vm.stopPrank();
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        uint256 twap = hook.validTWAP(poolId);
        assertGt(twap, 2 * BurnNet(token.burnNet()).anchor());

        uint256 expectedClip = PermanentLiquidityVault(vaultAddress).polTokenInventory() * 25 / 10_000;
        uint256 tagBefore = hook.claimableTagAI(poolId);
        uint256 creatorBefore = hook.claimableCreator(poolId);
        uint256 eligibleBefore = hook.pendingEligibleTradeFeeUSDG(poolId);
        uint256 pendingBefore = hook.pendingUSDG(poolId);
        uint256 supplyBefore = token.totalSupply();
        vm.expectPartialRevert(PremiumSeller.SlippageExceeded.selector);
        premium.execute(type(uint256).max);
        (uint256 sold, uint256 usdgOut) = premium.execute(0);

        assertEq(sold, expectedClip);
        assertGt(usdgOut, 0);
        assertEq(treasury.mintedByPremium(), sold);
        assertEq(token.totalSupply(), supplyBefore + sold);
        assertEq(token.balanceOf(premiumAddress), 0);
        assertEq(hook.pendingUSDG(poolId), pendingBefore + usdgOut);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), eligibleBefore);
        assertEq(hook.claimableTagAI(poolId), tagBefore);
        assertEq(hook.claimableCreator(poolId), creatorBefore);
        vm.expectRevert(abi.encodeWithSelector(PremiumSeller.IntervalNotElapsed.selector, premium.nextExecuteAt()));
        premium.execute(0);
    }

    function test_baseVaultHasNoLiquidityRemovalOrTokenRecoverySurface() public {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);
        (, address vaultAddress) = pump.list(address(token));

        (bool removeOk,) = vaultAddress.call(abi.encodeWithSignature("decreaseLiquidity(uint128)", uint128(1)));
        (bool collectOk,) = vaultAddress.call(abi.encodeWithSignature("collect(address)", address(this)));
        (bool recoverOk,) =
            vaultAddress.call(abi.encodeWithSignature("recoverToken(address,address)", USDG, address(this)));

        assertFalse(removeOk);
        assertFalse(collectOk);
        assertFalse(recoverOk);
    }

    function test_hookCollectsUsdGOnBuyAndSellAndPreservesThreeWayAccounting() public {
        (PoolId poolId, address vaultAddress) = _fillAndList();
        PoolKey memory key = _poolKey();
        PermanentLiquidityVault vault = PermanentLiquidityVault(vaultAddress);
        uint256 polTokensBefore = vault.polTokenInventory();

        ListingTestUsdG(USDG).mint(trader, 1_000e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);

        uint256 grossBuyInput = 100e6;
        uint256 tokenBefore = token.balanceOf(trader);
        vm.prank(trader);
        _swap(key, _usdgIsCurrency0(), -int256(grossBuyInput));

        assertGt(token.balanceOf(trader), tokenBefore);
        assertLt(vault.polTokenInventory(), polTokensBefore);
        assertEq(ListingTestUsdG(USDG).balanceOf(trader), 900e6);
        assertEq(hook.claimableTagAI(poolId), 500_000);
        assertEq(hook.claimableCreator(poolId), 1_000_000);
        assertEq(hook.pendingUSDG(poolId), 3_500_000);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 3_500_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), 5e6);

        uint256 tokenToSell = (token.balanceOf(trader) - tokenBefore) / 2;
        vm.prank(trader);
        token.approve(address(swapRouter), tokenToSell);
        uint256 usdgBeforeSell = ListingTestUsdG(USDG).balanceOf(trader);
        uint256 hookBeforeSell = ListingTestUsdG(USDG).balanceOf(address(hook));

        vm.prank(trader);
        BalanceDelta sellDelta = _swap(key, !_usdgIsCurrency0(), -int256(tokenToSell));

        uint256 netOutput = ListingTestUsdG(USDG).balanceOf(trader) - usdgBeforeSell;
        uint256 sellFee = ListingTestUsdG(USDG).balanceOf(address(hook)) - hookBeforeSell;
        uint256 grossOutput = netOutput + sellFee;
        assertEq(sellFee, grossOutput * 500 / 10_000);
        assertEq(
            hook.claimableTagAI(poolId) + hook.claimableCreator(poolId) + hook.pendingUSDG(poolId),
            ListingTestUsdG(USDG).balanceOf(address(hook))
        );
        assertTrue(BalanceDelta.unwrap(sellDelta) != 0);
    }

    function test_addPendingIsPoolScopedAndNeverEligible() public {
        (PoolId poolId,) = _fillAndList();
        ListingTestUsdG(USDG).mint(trader, 77e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 77e6);

        vm.prank(trader);
        uint256 received = hook.addPendingUSDG(poolId, 77e6);

        assertEq(received, 77e6);
        assertEq(hook.pendingUSDG(poolId), 77e6);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 0);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), 77e6);

        vm.expectRevert(NetNetHook.PoolNotRegistered.selector);
        hook.addPendingUSDG(PoolId.wrap(bytes32(uint256(123))), 1);
    }

    function test_feeClaimsDoNotConsumeBurnNetPending() public {
        (PoolId poolId,) = _fillAndList();
        PoolKey memory key = _poolKey();
        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 100e6);
        _swap(key, _usdgIsCurrency0(), -int256(100e6));
        vm.stopPrank();

        uint256 pendingBefore = hook.pendingUSDG(poolId);
        hook.claimTagAIFees(poolId);
        hook.claimCreatorFees(poolId);

        assertEq(ListingTestUsdG(USDG).balanceOf(tagAI), 500_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(creatorFeeRecipient), 1_000_000);
        assertEq(hook.pendingUSDG(poolId), pendingBefore);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(hook)), pendingBefore);
    }

    function test_officialPoolRejectsExactOutput() public {
        _fillAndList();
        PoolKey memory key = _poolKey();

        ListingTestUsdG(USDG).mint(trader, 1_000e6);
        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);

        vm.prank(trader);
        vm.expectRevert();
        _swap(key, _usdgIsCurrency0(), int256(1e18));
    }

    function test_hookSupportsReverseTokenUsdGAddressOrder() public {
        Token12 reverseToken;
        for (uint256 i = 1; i < 100; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = pump.predictTokenAddress(creator, salt);
            if (predicted < USDG) {
                vm.prank(creator);
                reverseToken = Token12(pump.createToken(_params(salt, "P12R")));
                break;
            }
        }
        assertTrue(address(reverseToken) != address(0), "reverse-order salt not found");

        vm.prank(buyer);
        ListingTestUsdG(USDG).approve(address(reverseToken), type(uint256).max);
        vm.prank(buyer);
        reverseToken.buy(20_000e6, 750_000_000e18);
        (PoolId reversePoolId,) = pump.list(address(reverseToken));

        PoolKey memory key = _poolKey(address(reverseToken));
        assertEq(Currency.unwrap(key.currency1), USDG);
        ListingTestUsdG(USDG).mint(trader, 110e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 10e6);
        hook.addPendingUSDG(reversePoolId, 10e6);
        vm.stopPrank();
        uint40 oracleStart = uint40(block.timestamp);
        _checkpointFor(reversePoolId, oracleStart, 16);
        vm.warp(oracleStart + 8 hours + 1);
        assertApproxEqRel(hook.validTWAP(reversePoolId), 60_000_000_000_000, 2e14);
        BurnNet reverseBurnNet = BurnNet(reverseToken.burnNet());
        reverseBurnNet.poke();
        assertGt(reverseBurnNet.totalUnfilledUSDG(), 0);
        assertFalse(reverseBurnNet.usdgIsCurrency0());

        vm.prank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 100e6);
        vm.prank(trader);
        _swap(key, false, -int256(100e6));

        assertGt(reverseToken.balanceOf(trader), 0);
        assertEq(hook.claimableTagAI(reversePoolId), 500_000);
        assertEq(hook.claimableCreator(reversePoolId), 1_000_000);
        assertEq(hook.pendingUSDG(reversePoolId), 3_500_000);
    }

    function test_twapStartsAtListingAndRequiresFourCompletedHours() public {
        (PoolId poolId,) = _fillAndList();
        (uint40 listedAt,,,,, uint8 count) = hook.oracleState(poolId);
        assertEq(listedAt, uint40(block.timestamp));
        assertEq(count, 1);

        vm.expectRevert(NetNetHook.InvalidTWAP.selector);
        hook.validTWAP(poolId);

        uint40 start = uint40(block.timestamp);
        for (uint256 i = 1; i <= 7; ++i) {
            vm.warp(start + i * 30 minutes);
            assertTrue(hook.checkpoint(poolId));
        }
        vm.warp(start + 4 hours + 1);
        vm.expectRevert(NetNetHook.InvalidTWAP.selector);
        hook.validTWAP(poolId);

        vm.warp(start + 4 hours);
        assertTrue(hook.checkpoint(poolId));
        vm.warp(start + 4 hours + 1);
        uint256 price = hook.validTWAP(poolId);
        assertApproxEqRel(price, 60_000_000_000_000, 2e14);
    }

    function test_twapExcludesCurrentTimestampSpotManipulation() public {
        (PoolId poolId,) = _fillAndList();
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 8);
        vm.warp(start + 4 hours + 1);
        uint256 beforeManipulation = hook.validTWAP(poolId);

        vm.warp(start + 4 hours + 30 minutes);
        ListingTestUsdG(USDG).mint(trader, 5_000e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(_poolKey(), _usdgIsCurrency0(), -int256(5_000e6));
        vm.stopPrank();

        uint256 sameTimestampPrice = hook.validTWAP(poolId);
        assertEq(sameTimestampPrice, beforeManipulation);
        (,, int24 latestSpotTick,,,) = hook.oracleState(poolId);
        (, int24 poolTick,,) = manager.getSlot0(poolId);
        assertEq(latestSpotTick, poolTick);
    }

    function test_twapRejectsStaleObservation() public {
        (PoolId poolId,) = _fillAndList();
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 8);

        vm.warp(start + 5 hours + 1);
        vm.expectRevert(NetNetHook.InvalidTWAP.selector);
        hook.validTWAP(poolId);
    }

    function test_twapAfterRequiresAFullPostBoundaryWindow() public {
        (PoolId poolId,) = _fillAndList();
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 8);
        vm.warp(start + 4 hours + 1);
        vm.expectRevert(NetNetHook.InvalidTWAP.selector);
        hook.validTWAPAfter(poolId, start + 30 minutes);

        vm.warp(start + 4 hours + 30 minutes);
        hook.checkpoint(poolId);
        vm.warp(start + 4 hours + 30 minutes + 1);
        assertGt(hook.validTWAPAfter(poolId, start + 30 minutes), 0);
    }

    function test_twapObservationRingRollsAtFixedCapacity() public {
        (PoolId poolId,) = _fillAndList();
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 40);
        vm.warp(start + 20 hours + 1);

        (,,,,, uint8 count) = hook.oracleState(poolId);
        assertEq(count, hook.OBSERVATION_CAPACITY());
        assertGt(hook.validTWAP(poolId), 0);
    }

    function test_burnNetPokeActivatesOnlyItsPoolPendingAndPreservesEligibleRatio() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());
        (,,, address distributorAddress,,,,,) = pump.tokenEmissionModules(address(token));
        Distributor distributor = Distributor(distributorAddress);
        assertFalse(burnNet.mintingAvailable());

        vm.expectRevert(abi.encodeWithSelector(BurnNet.PokeTooEarly.selector, burnNet.nextPokeAt()));
        burnNet.poke();

        ListingTestUsdG(USDG).mint(trader, 200e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 100e6);
        _swap(_poolKey(), _usdgIsCurrency0(), -int256(100e6));
        ListingTestUsdG(USDG).approve(address(hook), 6_500_000);
        hook.addPendingUSDG(poolId, 6_500_000);
        vm.stopPrank();

        assertEq(hook.pendingUSDG(poolId), 10_000_000);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 3_500_000);
        assertEq(distributor.reserveCredit(), 0);
        vm.expectRevert(NetNetHook.OnlyBurnNet.selector);
        hook.pullPendingUSDG(poolId, trader, 0);
        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        assertTrue(burnNet.mintingAvailable());
        uint256 marketPrice = hook.validTWAP(poolId);
        uint256 expectedAnchor = Math.min(marketPrice, burnNet.initialAnchor() * 10_800 / 10_000);

        uint256 keeperBefore = ListingTestUsdG(USDG).balanceOf(trader);
        vm.prank(trader);
        uint256 activated = burnNet.poke();

        assertEq(activated, 9_990_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(trader) - keeperBefore, 10_000);
        assertEq(ListingTestUsdG(USDG).balanceOf(address(burnNet)), burnNet.activeLiquidUSDG());
        assertEq(hook.pendingUSDG(poolId), 0);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), 0);
        assertEq(burnNet.activeReserveUSDG(), activated);
        assertEq(burnNet.activePositionPrincipalUSDG(), activated);
        assertEq(burnNet.totalUnfilledUSDG(), activated);
        assertEq(burnNet.activeEligibleTradeFeeUSDG(), 3_496_500);
        assertEq(burnNet.eligibleUSDGSpentOnKeeper(), 3_500);
        assertEq(burnNet.reserveSnapshotUSDG(), activated);
        assertEq(burnNet.eligibleTradeFeeReserveUSDG(), 3_496_500);
        assertEq(distributor.reserveCredit(), Math.mulDiv(3_496_500, 1e30, burnNet.initialAnchor()));
        assertEq(burnNet.anchorVersion(), 2);
        assertEq(burnNet.generation(), 1);
        assertEq(burnNet.anchor(), expectedAnchor);
        assertFalse(burnNet.mintingAvailable());
        vm.warp(block.timestamp + 1);
        assertTrue(burnNet.mintingAvailable());

        uint256 l1;
        uint256 l2;
        for (uint8 i; i < 7; ++i) {
            BurnNet.Tier memory tier = burnNet.tierState(i);
            if (i < 3) l1 += tier.unfilledUSDG;
            else if (i < 6) l2 += tier.unfilledUSDG;
        }
        assertEq(l1, activated * 8 / 100);
        assertEq(l2, activated * 12 / 100);
        assertEq(burnNet.tierState(6).unfilledUSDG, activated * 80 / 100);
    }

    function test_burnNetDownwardResetRestartsGenerationAndFreezesMinting() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());
        uint256 oldAnchor = burnNet.anchor();

        vm.startPrank(buyer);
        token.approve(address(swapRouter), 250_000_000e18);
        _swap(_poolKey(), !_usdgIsCurrency0(), -int256(250_000_000e18));
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        uint256 marketPrice = hook.validTWAP(poolId);
        assertLt(marketPrice, oldAnchor / 2);

        uint40 resetAt = start + 8 hours + 1;
        burnNet.poke();
        assertEq(burnNet.anchor(), marketPrice);
        assertEq(burnNet.generation(), 2);
        assertEq(burnNet.lastDownwardResetAt(), resetAt);
        assertEq(burnNet.mintFrozenUntil(), resetAt + 24 hours);
        assertFalse(burnNet.mintingAvailable());
        (,,, address distributorAddress, address bondAddress,,,,) = pump.tokenEmissionModules(address(token));
        assertEq(Distributor(distributorAddress).currentRateWad(), 0);

        ListingTestUsdG(USDG).mint(trader, 1e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(bondAddress, 1e6);
        vm.expectRevert(Treasury.MintingFrozen.selector);
        BondDepository(bondAddress).deposit(1e6, type(uint256).max, trader);
        vm.stopPrank();
        assertEq(hook.pendingUSDG(poolId), 0);

        _checkpointFor(poolId, resetAt, 48);
        assertEq(block.timestamp, burnNet.mintFrozenUntil());
        assertTrue(burnNet.mintingAvailable());
    }

    function test_tokenBurnOnlyDestroysCallersOwnInventory() public {
        vm.prank(buyer);
        token.buy(100e6, 0);
        uint256 amount = token.balanceOf(buyer) / 2;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(buyer);
        token.burn(amount);

        assertEq(token.totalSupply(), supplyBefore - amount);
        assertEq(token.balanceOf(buyer), amount);
        vm.expectRevert(Token12.InvalidAmount.selector);
        token.burn(0);
    }

    function test_burnNetHarvestBurnsFullyCrossedPositionsWithoutFreshOracle() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());

        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 100e6);
        hook.addPendingUSDG(poolId, 100e6);
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        burnNet.poke();
        assertGt(burnNet.activePositionPrincipalUSDG(), 0);

        vm.startPrank(buyer);
        token.approve(address(swapRouter), 300_000_000e18);
        _swap(_poolKey(), !_usdgIsCurrency0(), -int256(300_000_000e18));
        vm.stopPrank();
        uint256 supplyBefore = token.totalSupply();

        vm.warp(start + 20 hours);
        vm.expectRevert(NetNetHook.InvalidTWAP.selector);
        hook.validTWAP(poolId);
        vm.prank(address(0xBEEF));
        uint256 burned = burnNet.harvest();

        assertGt(burned, 0);
        assertEq(burnNet.totalBurned(), burned);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertGt(burnNet.consumedActiveUSDG(), 0);
        assertEq(burnNet.activeReserveUSDG(), burnNet.activeLiquidUSDG() + burnNet.activePositionPrincipalUSDG());
        vm.expectRevert(BurnNet.NothingToHarvest.selector);
        burnNet.harvest();
    }

    function test_burnNetResetSettlesOldGenerationBeforeChangingPositionSalt() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());
        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 100e6);
        hook.addPendingUSDG(poolId, 100e6);
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        burnNet.poke();
        assertEq(burnNet.generation(), 1);

        vm.startPrank(buyer);
        token.approve(address(swapRouter), 300_000_000e18);
        _swap(_poolKey(), !_usdgIsCurrency0(), -int256(300_000_000e18));
        vm.stopPrank();
        uint40 dumpAt = start + 8 hours + 1;
        _checkpointFor(poolId, dumpAt, 16);
        vm.warp(dumpAt + 8 hours + 1);

        burnNet.poke();

        assertEq(burnNet.generation(), 2);
        assertGt(burnNet.totalBurned(), 0);
        assertEq(burnNet.activeReserveUSDG(), burnNet.activeLiquidUSDG() + burnNet.activePositionPrincipalUSDG());
        assertEq(
            burnNet.activeEligibleTradeFeeUSDG(),
            burnNet.activeEligibleLiquidUSDG() + burnNet.activeEligiblePositionUSDG()
        );
    }

    function test_burnNetMigratesLiveTiersWhenAnchorRises() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());
        ListingTestUsdG(USDG).mint(trader, 1_200e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 100e6);
        hook.addPendingUSDG(poolId, 100e6);
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        burnNet.poke();
        BurnNet.Tier memory oldTier = burnNet.tierState(0);
        uint256 oldAnchor = burnNet.anchor();

        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(_poolKey(), _usdgIsCurrency0(), -int256(1_000e6));
        vm.stopPrank();
        uint40 riseAt = start + 8 hours + 1;
        _checkpointFor(poolId, riseAt, 16);
        vm.warp(riseAt + 8 hours + 1);

        burnNet.poke();
        BurnNet.Tier memory newTier = burnNet.tierState(0);

        assertGt(burnNet.anchor(), oldAnchor);
        assertEq(burnNet.generation(), 1);
        assertTrue(newTier.tickLower != oldTier.tickLower);
        assertEq(burnNet.activeReserveUSDG(), burnNet.activeLiquidUSDG() + burnNet.activePositionPrincipalUSDG());
        assertEq(
            burnNet.activeEligibleTradeFeeUSDG(),
            burnNet.activeEligibleLiquidUSDG() + burnNet.activeEligiblePositionUSDG()
        );
    }

    function test_burnNetPokeSettlesAndBurnsPartiallyFilledTier() public {
        (PoolId poolId,) = _fillAndList();
        BurnNet burnNet = BurnNet(token.burnNet());
        ListingTestUsdG(USDG).mint(trader, 100e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), 100e6);
        hook.addPendingUSDG(poolId, 100e6);
        vm.stopPrank();

        uint40 start = uint40(block.timestamp);
        _checkpointFor(poolId, start, 16);
        vm.warp(start + 8 hours + 1);
        burnNet.poke();
        BurnNet.Tier memory tier0 = burnNet.tierState(0);
        uint160 middleOfTier = TickMath.getSqrtPriceAtTick((tier0.tickLower + tier0.tickUpper) / 2);

        vm.startPrank(buyer);
        token.approve(address(swapRouter), 100_000_000e18);
        _swapWithLimit(_poolKey(), !_usdgIsCurrency0(), -int256(100_000_000e18), middleOfTier);
        vm.stopPrank();
        uint256 supplyBeforePoke = token.totalSupply();
        uint40 touchAt = start + 8 hours + 1;
        _checkpointFor(poolId, touchAt, 16);
        vm.warp(touchAt + 8 hours + 1);

        burnNet.poke();

        assertGt(burnNet.totalBurned(), 0);
        assertLt(token.totalSupply(), supplyBeforePoke);
        assertGt(burnNet.totalUSDGConvertedToToken(), 0);
        assertEq(burnNet.consumedActiveUSDG(), 0);
        assertEq(burnNet.consumedEligibleTradeFeeUSDG(), 0);
        assertEq(burnNet.activeReserveUSDG(), burnNet.activeLiquidUSDG() + burnNet.activePositionPrincipalUSDG());
    }

    function _fillAndList() internal returns (PoolId poolId, address vault) {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);
        return pump.list(address(token));
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        return _poolKey(address(token));
    }

    function _poolKey(address tokenAddress) internal view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(tokenAddress);
        Currency usdgCurrency = Currency.wrap(USDG);
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    function _usdgIsCurrency0() internal view returns (bool) {
        return USDG < address(token);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swapWithLimit(key, zeroForOne, amountSpecified, limit);
    }

    function _swapWithLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta)
    {
        delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _checkpointFor(PoolId poolId, uint40 start, uint256 count) internal {
        for (uint256 i = 1; i <= count; ++i) {
            vm.warp(start + i * 30 minutes);
            assertTrue(hook.checkpoint(poolId));
        }
    }

    function _deployHook() internal returns (NetNetHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(pump), USDG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NetNetHook).creationCode, constructorArgs);
        deployed = new NetNetHook{salt: salt}(manager, address(pump), USDG);
        assertEq(address(deployed), predicted);
    }

    function _params() internal view returns (Pump12.CreateParams memory p) {
        return _params(bytes32("listing"), "P12L");
    }

    function _params(bytes32 salt, string memory symbol) internal view returns (Pump12.CreateParams memory p) {
        p = Pump12.CreateParams({
            name: "Pump12 Listing",
            symbol: symbol,
            salt: salt,
            totalFeeBps: 500,
            creatorShareBps: 2_000,
            creatorFeeRecipient: creatorFeeRecipient,
            indexToken: indexToken,
            pTeamHolder: pTeamHolder
        });
    }
}
