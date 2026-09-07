// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {Token12} from "../../../src/pump12/Token12.sol";
import {NetNetHook} from "../../../src/pump12/NetNetHook.sol";
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
import {HookMiner} from "../../../src/utils/HookMiner.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

interface IRHBasketSwapRouter {
    function poolManager() external view returns (address);
    function basketHook() external view returns (address);
    function usdg() external view returns (address);

    function buyExactUsdg(
        address basket,
        uint256 usdgIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);
}

interface IRHBasketHookV3 {
    function poolManager() external view returns (address);
    function basketRegistry() external view returns (address);
    function routeRegistry() external view returns (address);
    function usdg() external view returns (address);
    function weth() external view returns (address);
}

interface IRHBasketRegistryV3 {
    function isBasket(address basket) external view returns (bool);
    function basketVersion(address basket) external view returns (uint32);
}

interface IRHBasketTokenV3 {
    function protocolVersion() external pure returns (uint32);
    function registry() external view returns (address);
    function settlementToken() external view returns (address);
    function weth() external view returns (address);
    function engine() external view returns (address);
    function rebalanceExecutor() external view returns (address);
    function assetCount() external view returns (uint256);
}

/// @notice Pump12 在 Robinhood mainnet canonical USDG / PoolManager 上的最小闭环验收。
contract Pump12RHListingForkTest is Test {
    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant BASKET_REGISTRY = 0x1f997dEb6C8Ac7Bb4134Bc7c6bF23F623Cda25C6;
    address internal constant BASKET_ROUTE_REGISTRY = 0x1aE3E64F51CCDC87Ff05E8E8242890e7964FF297;
    address internal constant BASKET_SWAP_ROUTER = 0x9b5e6b7CC3661737e6A118e0D4f0F89fB1034653;
    address internal constant BASKET_HOOK_V3 = 0x7103AA53a7de0Af737d1dC1A257838f6f488aA88;
    address internal constant BASKET_REBALANCE_EXECUTOR = 0x1bca8A39021f6C65b62bbe79A59e41215cF19264;
    address internal constant DEFAULT_INDEX = 0x90d2cCA000Dc36fA8401632C67faFDa7D7860C07;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");

    bool internal forkReady;
    Pump12 internal pump;
    Token12 internal token;
    NetNetHook internal hook;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        // Foundry default profile pins local chain_id=31337 even after selecting an RPC fork.
        vm.chainId(RH_CHAIN_ID);
        require(block.chainid == RH_CHAIN_ID, "unexpected RH chain id");
        require(USDG.code.length > 0, "canonical USDG missing");
        require(POOL_MANAGER.code.length > 0, "canonical PoolManager missing");

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
            WETH,
            BASKET_REGISTRY,
            BASKET_SWAP_ROUTER,
            BASKET_ROUTE_REGISTRY,
            address(indexFundImplementation)
        );
        PTeam pTeamImplementation = new PTeam();
        IndexBondDesk indexBondDeskImplementation = new IndexBondDesk();
        vm.prank(tagAI);
        pump.setPTeamImplementations(
            address(pTeamImplementation), address(indexBondDeskImplementation), address(indexFundFactory)
        );

        vm.prank(creator);
        token = Token12(
            pump.createToken(
                Pump12.CreateParams({
                    name: "Pump12 RH Fork",
                    symbol: "P12RHF",
                    salt: bytes32("rh-fork"),
                    totalFeeBps: 500,
                    creatorShareBps: 2_000,
                    creatorFeeRecipient: creator,
                    indexToken: DEFAULT_INDEX,
                    pTeamHolder: makeAddr("pTeamHolder")
                })
            )
        );
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        forkReady = true;
    }

    modifier onlyFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function test_fork_indexV3DeploymentMatchesPump12Assumptions() public onlyFork {
        IRHBasketSwapRouter router = IRHBasketSwapRouter(BASKET_SWAP_ROUTER);
        IRHBasketHookV3 basketHook = IRHBasketHookV3(BASKET_HOOK_V3);
        IRHBasketRegistryV3 registry = IRHBasketRegistryV3(BASKET_REGISTRY);
        IRHBasketTokenV3 index = IRHBasketTokenV3(DEFAULT_INDEX);

        assertEq(router.poolManager(), POOL_MANAGER);
        assertEq(router.basketHook(), BASKET_HOOK_V3);
        assertEq(router.usdg(), USDG);
        assertEq(basketHook.poolManager(), POOL_MANAGER);
        assertEq(basketHook.basketRegistry(), BASKET_REGISTRY);
        assertEq(basketHook.routeRegistry(), BASKET_ROUTE_REGISTRY);
        assertEq(basketHook.usdg(), USDG);
        assertEq(basketHook.weth(), WETH);

        assertTrue(registry.isBasket(DEFAULT_INDEX));
        assertEq(registry.basketVersion(DEFAULT_INDEX), 3);
        assertEq(index.protocolVersion(), 3);
        assertEq(index.registry(), BASKET_REGISTRY);
        assertEq(index.settlementToken(), USDG);
        assertEq(index.weth(), WETH);
        assertEq(index.engine(), BASKET_HOOK_V3);
        assertEq(index.rebalanceExecutor(), BASKET_REBALANCE_EXECUTOR);
        assertGt(index.assetCount(), 0);
    }

    function test_fork_createListAndSwapBothDirections() public onlyFork {
        deal(USDG, buyer, 30_000e6, true);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(token), type(uint256).max);
        token.buy(20_000e6, 750_000_000e18);
        vm.stopPrank();

        (PoolId poolId,) = pump.list(address(token));
        PoolKey memory key = _poolKey();
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
        assertEq(token.treasury(), treasuryAddress);
        assertGt(treasuryAddress.code.length, 0);
        assertGt(sTokenAddress.code.length, 0);
        assertGt(stakingAddress.code.length, 0);
        assertGt(distributorAddress.code.length, 0);
        assertGt(bondAddress.code.length, 0);
        assertGt(premiumAddress.code.length, 0);
        assertGt(pTeamAddress.code.length, 0);
        assertGt(indexBondDeskAddress.code.length, 0);
        assertGt(indexFundAddress.code.length, 0);

        deal(USDG, trader, 100e6, true);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(key, USDG < address(token), -int256(100e6));
        uint256 bought = token.balanceOf(trader);
        assertGt(bought, 0);

        token.approve(address(swapRouter), bought / 2);
        _swap(key, USDG >= address(token), -int256(bought / 2));
        vm.stopPrank();

        assertGt(IERC20(USDG).balanceOf(trader), 0);
        assertGt(hook.pendingUSDG(poolId), 0);
        assertEq(
            hook.claimableTagAI(poolId) + hook.claimableCreator(poolId) + hook.pendingUSDG(poolId),
            IERC20(USDG).balanceOf(address(hook))
        );
    }

    function test_fork_feePendingPokeSevenRangesHarvestAndBurn() public onlyFork {
        deal(USDG, buyer, 30_000e6, true);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(token), type(uint256).max);
        token.buy(20_000e6, 750_000_000e18);
        vm.stopPrank();
        (PoolId poolId,) = pump.list(address(token));

        PoolKey memory key = _poolKey();
        deal(USDG, trader, 200e6, true);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapRouter), 100e6);
        _swap(key, USDG < address(token), -int256(100e6));
        assertGt(hook.pendingEligibleTradeFeeUSDG(poolId), 0);
        IERC20(USDG).approve(address(hook), 100e6);
        hook.addPendingUSDG(poolId, 100e6);
        vm.stopPrank();

        uint40 listedAt = uint40(block.timestamp);
        vm.warp(listedAt + 8 hours);
        hook.checkpoint(poolId);
        vm.warp(listedAt + 8 hours + 1);
        BurnNet burnNet = BurnNet(token.burnNet());
        burnNet.poke();

        assertGt(burnNet.totalUnfilledUSDG(), 99e6);
        assertEq(burnNet.activeReserveUSDG(), burnNet.activeLiquidUSDG() + burnNet.activePositionPrincipalUSDG());
        for (uint8 i; i < 7; ++i) {
            assertGt(burnNet.tierState(i).liquidity, 0);
        }

        vm.startPrank(buyer);
        token.approve(address(swapRouter), 300_000_000e18);
        _swap(key, USDG >= address(token), -int256(300_000_000e18));
        vm.stopPrank();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(makeAddr("permissionlessHarvester"));
        uint256 burned = burnNet.harvest();

        assertGt(burned, 0);
        assertEq(burnNet.totalBurned(), burned);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertGt(burnNet.consumedEligibleTradeFeeUSDG(), 0);
    }

    function test_fork_pTeamDeskBuysOfficialIndexThroughCanonicalRouter() public onlyFork {
        deal(USDG, buyer, 30_000e6, true);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(token), type(uint256).max);
        token.buy(20_000e6, 750_000_000e18);
        vm.stopPrank();
        (PoolId poolId,) = pump.list(address(token));
        (,,,,,, address pTeamAddress, address deskAddress, address fundAddress) =
            pump.tokenEmissionModules(address(token));

        PoolKey memory key = _poolKey();
        deal(USDG, trader, 3_000e6, true);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(key, USDG < address(token), -int256(2_000e6));
        vm.stopPrank();

        uint40 listedAt = uint40(token.listTime());
        for (uint256 i; i <= 8; ++i) {
            vm.warp(listedAt + 20 hours + i * 30 minutes);
            hook.checkpoint(poolId);
        }
        vm.warp(listedAt + 24 hours + 1);

        vm.prank(makeAddr("pTeamHolder"));
        PTeam(pTeamAddress).exercise(1_000_000e18);
        assertEq(token.balanceOf(makeAddr("pTeamHolder")), 0);
        assertEq(IndexBondDesk(deskAddress).unsoldInventory(), 1_000_000e18);

        uint256 pendingBefore = hook.pendingUSDG(poolId);
        uint256 eligibleBefore = hook.pendingEligibleTradeFeeUSDG(poolId);
        deal(USDG, buyer, 1_000e6, true);
        vm.startPrank(buyer);
        IERC20(USDG).approve(deskAddress, type(uint256).max);
        IndexBondDesk(deskAddress).subscribe(100_000e18, type(uint256).max, buyer);
        vm.stopPrank();

        assertGt(hook.pendingUSDG(poolId), pendingBefore);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), eligibleBefore);
        assertGt(IERC20(DEFAULT_INDEX).balanceOf(fundAddress), 0);

        // A later real Basket purchase accrues holder fees to the Fund's existing Index position.
        address indexBuyer = makeAddr("indexBuyer");
        deal(USDG, indexBuyer, 1_000e6, true);
        vm.startPrank(indexBuyer);
        IERC20(USDG).approve(BASKET_SWAP_ROUTER, type(uint256).max);
        IRHBasketSwapRouter(BASKET_SWAP_ROUTER).buyExactUsdg(DEFAULT_INDEX, 500e6, 0, bytes(""), indexBuyer);
        vm.stopPrank();

        uint256 pendingBeforeClaim = hook.pendingUSDG(poolId);
        uint256 eligibleBeforeClaim = hook.pendingEligibleTradeFeeUSDG(poolId);
        uint256 creatorBefore = IERC20(USDG).balanceOf(creator);
        vm.prank(creator);
        (uint256 wethClaimed, uint256 usdgOut) = IndexFundV1(payable(fundAddress)).claimHolderFees(1);

        uint256 creatorShare = usdgOut / 100;
        assertGt(wethClaimed, 0);
        assertGt(usdgOut, 0);
        assertEq(IERC20(USDG).balanceOf(creator) - creatorBefore, creatorShare);
        assertEq(hook.pendingUSDG(poolId) - pendingBeforeClaim, usdgOut - creatorShare);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), eligibleBeforeClaim);
        assertEq(IERC20(WETH).balanceOf(fundAddress), 0);
        assertEq(fundAddress.balance, 0);
        assertEq(IERC20(USDG).balanceOf(fundAddress), 0);

        uint256 indexBeforeSell = IERC20(DEFAULT_INDEX).balanceOf(fundAddress);
        uint256 indexToSell = indexBeforeSell / 10;
        uint256 pendingBeforeSell = hook.pendingUSDG(poolId);
        uint256 eligibleBeforeSell = hook.pendingEligibleTradeFeeUSDG(poolId);
        uint256 creatorBeforeSell = IERC20(USDG).balanceOf(creator);
        vm.prank(creator);
        uint256 sellUsdGOut = IndexFundV1(payable(fundAddress)).sellIndex(indexToSell, 1);

        uint256 sellCreatorShare = sellUsdGOut / 100;
        assertGt(sellUsdGOut, 0);
        assertEq(IERC20(DEFAULT_INDEX).balanceOf(fundAddress), indexBeforeSell - indexToSell);
        assertEq(IERC20(USDG).balanceOf(creator) - creatorBeforeSell, sellCreatorShare);
        assertEq(hook.pendingUSDG(poolId) - pendingBeforeSell, sellUsdGOut - sellCreatorShare);
        assertEq(hook.pendingEligibleTradeFeeUSDG(poolId), eligibleBeforeSell);
        assertEq(IERC20(USDG).balanceOf(fundAddress), 0);
    }

    function _deployHook() internal returns (NetNetHook deployed) {
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(pump), USDG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NetNetHook).creationCode, constructorArgs);
        deployed = new NetNetHook{salt: salt}(IPoolManager(POOL_MANAGER), address(pump), USDG);
        assertEq(address(deployed), predicted);
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(address(token));
        Currency usdgCurrency = Currency.wrap(USDG);
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }
}
