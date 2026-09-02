// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CommunityFactory} from "../../src/nutbox/CommunityFactory.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {NutboxCommunityFeeHook} from "../../src/hook/NutboxCommunityFeeHook.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {IndexBrokerNFTBurn, IndexBrokerNFTStake} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTAMM} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface ILiveBasketSwapRouterForCommunityFeeHook {
    function buyExactSettlement(
        address basket,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);
}

/// @notice Mainnet-fork E2E for the deployed generic community fee hook and an external HBTC community.
/// @dev All state changes remain inside the fork. Nothing in this test is broadcast to RH mainnet.
contract RHDeployedCommunityFeeHookLifecycleTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct BasketTradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minUsdgOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 hubSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }

    address internal constant HBTC = 0x8DB244F6Bf052571F4E0C6065b700E714092d4b6;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant COMMUNITY_FEE_HOOK = 0x58e2Bf5481fB1a21b477A469B278183Bd93140cC;
    address internal constant HOOK_OWNER = 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611;
    address internal constant COMMITTEE = 0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0;
    address internal constant COMMUNITY_FACTORY = 0x24328DccA1bA54EeE82e2993F021802e64290486;
    address internal constant HOURLY_CALCULATOR = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;
    address internal constant INDEX_FACTORY = 0x678871773b07322aA927FE5057870D1356F09676;
    address internal constant BURN_TEMPLATE = 0x1fCB38D03231cCC7D62C45A5Ee5184A2486778d0;
    address internal constant STAKE_TEMPLATE = 0x0971018D38523021333B94088E69fCF1726606b1;
    address internal constant DEFAULT_INDEX = 0x90d2cCA000Dc36fA8401632C67faFDa7D7860C07;
    address internal constant BASKET_ROUTER = 0x9b5e6b7CC3661737e6A118e0D4f0F89fB1034653;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint24 internal constant LP_FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TOKEN_UNIT = 1 ether;

    IPoolManager internal manager;
    NutboxCommunityFeeHook internal feeHook;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    Community internal community;
    HourlyTickCalculator internal calculator;
    Committee internal committee;
    IndexBrokerNFTFactory internal indexFactory;
    PoolKey internal poolKey;

    address internal creator;
    address internal lp;
    address internal memberA;
    address internal memberB;
    address internal memberC;
    address internal keeper;
    bool internal forkReady;

    receive() external payable {}

    modifier onlyFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try this.createFork(rpc) {}
        catch {
            return;
        }
        if (block.chainid != 4_663 || COMMUNITY_FEE_HOOK.code.length == 0 || HBTC.code.length == 0) return;

        creator = makeAddr("hbtc-community-creator");
        lp = makeAddr("hbtc-liquidity-provider");
        memberA = makeAddr("hbtc-member-a");
        memberB = makeAddr("hbtc-member-b");
        memberC = makeAddr("hbtc-member-c");
        keeper = makeAddr("hbtc-keeper");
        vm.deal(creator, 1_000 ether);
        vm.deal(lp, 1_000 ether);
        vm.deal(memberA, 1_000 ether);
        vm.deal(memberB, 1_000 ether);
        vm.deal(memberC, 1_000 ether);
        vm.deal(keeper, 1_000 ether);

        assertEq(IERC20Metadata(HBTC).decimals(), 18);
        assertEq(IERC20Metadata(HBTC).symbol(), "HBTC");
        manager = IPoolManager(POOL_MANAGER);
        feeHook = NutboxCommunityFeeHook(COMMUNITY_FEE_HOOK);
        calculator = HourlyTickCalculator(HOURLY_CALCULATOR);
        committee = Committee(payable(COMMITTEE));
        indexFactory = IndexBrokerNFTFactory(INDEX_FACTORY);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(HBTC),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(COMMUNITY_FEE_HOOK)
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        deal(HBTC, lp, 1_000_000 * TOKEN_UNIT);
        vm.startPrank(lp);
        IERC20(HBTC).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 500 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(400 ether),
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();

        uint256 createFee = committee.getCreateCommunityFee();
        vm.prank(creator);
        community = Community(
            payable(CommunityFactory(COMMUNITY_FACTORY).createCommunity{value: createFee}(
                    false, HBTC, address(0), bytes(""), HOURLY_CALCULATOR, bytes("")
                ))
        );
        assertEq(community.owner(), creator);
        assertEq(community.getCommunityToken(), HBTC);
        assertTrue(calculator.registered(address(community)));

        vm.prank(HOOK_OWNER);
        feeHook.setPoolCommunity(poolKey.toId(), address(community));
        forkReady = true;
    }

    function createFork(string calldata rpc) external {
        vm.createSelectFork(rpc);
    }

    function testFork_HBTCFeeHookPoolAndCommunityDistribution() external onlyFork {
        _assertPoolAndHookConfiguration();
        IndexBrokerNFTBurn burnPool = _createBurnPool();
        _fundMembers();
        vm.startPrank(memberA);
        IERC20(HBTC).approve(address(burnPool), type(uint256).max);
        burnPool.mint(0);
        vm.stopPrank();
        _exerciseFeeFreeBeforeConfigurationProofOnAlternatePool();
        uint256 injected = _exerciseTradesAndAutomaticInjection();
        _exerciseCommunityRewardClaim(burnPool, injected);
    }

    function testFork_HBTCBurnIndexBrokerCompleteLifecycle() external onlyFork {
        IndexBrokerNFTBurn burnPool = _createBurnPool();
        IndexBrokerNFTAMM burnAMM = IndexBrokerNFTAMM(payable(burnPool.ammVault()));
        assertTrue(burnAMM.active());
        assertEq(uint8(burnAMM.priceSourceType()), uint8(INutboxRouter.SourceType.UNISWAP_V4));
        assertEq(burnAMM.priceQuoteToken(), address(0));
        _fundMembers();
        (uint256 burnIdA, uint256 burnIdB) = _exerciseMintReferralRevealAndUpgrade(burnPool);
        _exerciseIndexRewardsAndBurnTransfer(burnPool, burnIdA);
        _exerciseAMMTrade(burnPool, burnAMM, burnIdB);
    }

    function testFork_HBTCStakeIndexBrokerAndAMMCustody() external onlyFork {
        _createBurnPool();
        IndexBrokerNFTStake stakePool = _createStakePool();
        IndexBrokerNFTAMM stakeAMM = IndexBrokerNFTAMM(payable(stakePool.ammVault()));
        assertTrue(stakeAMM.active());
        _fundMembers();
        uint256 stakeId = _exerciseStakeMintAndStake(stakePool);
        _exerciseStakeRewardsAndAMMCustody(stakePool, stakeAMM, stakeId);
    }

    function _assertPoolAndHookConfiguration() private view {
        assertEq(poolKey.fee, 10_000, "LP fee must be 1%");
        assertEq(address(feeHook.poolManager()), POOL_MANAGER);
        assertEq(feeHook.owner(), HOOK_OWNER);
        assertEq(feeHook.pendingOwner(), address(0));
        (address configuredCommunity, address configuredCalculator, address token,, uint256 pending) =
            feeHook.poolConfig(poolKey.toId());
        assertEq(configuredCommunity, address(community));
        assertEq(configuredCalculator, HOURLY_CALCULATOR);
        assertEq(token, HBTC);
        assertEq(pending, 0);
    }

    function _exerciseFeeFreeBeforeConfigurationProofOnAlternatePool() private {
        PoolKey memory unconfiguredKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(HBTC),
            fee: 9_999,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(COMMUNITY_FEE_HOOK)
        });
        manager.initialize(unconfiguredKey, SQRT_PRICE_1_1);
        vm.startPrank(lp);
        liquidityRouter.modifyLiquidity{value: 20 ether}(
            unconfiguredKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(10 ether),
                salt: bytes32(uint256(1))
            }),
            bytes("")
        );
        vm.stopPrank();
        uint256 hookBefore = IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK);
        _buy(unconfiguredKey, memberC, 0.1 ether);
        assertEq(IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK), hookBefore, "unconfigured pool charged fee");
    }

    function _exerciseTradesAndAutomaticInjection() private returns (uint256 injected) {
        uint256 hookBefore = IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK);
        uint256 memberBefore = IERC20(HBTC).balanceOf(memberC);
        BalanceDelta buyDelta = _buy(poolKey, memberC, 1 ether);
        uint256 bought = IERC20(HBTC).balanceOf(memberC) - memberBefore;
        uint256 buyFee = IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK) - hookBefore;
        uint256 grossBuy = bought + buyFee;
        assertEq(buyFee, grossBuy / 100, "buy hook fee != 1%");
        assertGt(buyDelta.amount1(), 0);

        uint256 sellAmount = 2 ether;
        hookBefore = IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK);
        _sell(poolKey, memberC, sellAmount);
        uint256 sellFee = IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK) - hookBefore;
        assertEq(sellFee, sellAmount / 100, "sell hook fee != 1%");

        (,,,, uint256 pendingBefore) = feeHook.poolConfig(poolKey.toId());
        assertEq(pendingBefore, buyFee + sellFee);
        assertEq(calculator.totalInjected(address(community)), 0);

        vm.warp(block.timestamp + 10 minutes);
        _buy(poolKey, memberC, 0.2 ether);
        injected = calculator.totalInjected(address(community));
        assertGt(injected, pendingBefore);
        (,,,, uint256 pendingAfter) = feeHook.poolConfig(poolKey.toId());
        assertEq(pendingAfter, 0);
        assertEq(IERC20(HBTC).balanceOf(COMMUNITY_FEE_HOOK), 0);
        assertEq(IERC20(HBTC).balanceOf(address(community)), injected);
    }

    function _exerciseMintReferralRevealAndUpgrade(IndexBrokerNFTBurn pool)
        private
        returns (uint256 firstId, uint256 secondId)
    {
        vm.startPrank(memberA);
        IERC20(HBTC).approve(address(pool), type(uint256).max);
        firstId = pool.mint(0);
        vm.stopPrank();

        uint256 referralBefore = memberA.balance;
        vm.startPrank(memberB);
        IERC20(HBTC).approve(address(pool), type(uint256).max);
        secondId = pool.mint{value: 0.001 ether}(firstId);
        vm.stopPrank();
        assertEq(pool.getNFTInfo(firstId).referralCount, 1);
        assertEq(pool.getNFTInfo(firstId).level, 2);
        assertGt(memberA.balance, referralBefore);

        vm.roll(uint256(pool.getNFTInfo(firstId).revealBlock) + 1);
        vm.prank(memberA);
        assertGt(pool.reveal(firstId), 0);
        vm.prank(memberA);
        pool.commitReveal(firstId);
        vm.roll(uint256(pool.getNFTInfo(firstId).revealBlock) + 1);
        vm.prank(memberA);
        assertGt(pool.reveal(firstId), 0);

        vm.prank(memberA);
        pool.upgradeIndexMining(firstId, 2 ether);
        assertGt(pool.indexMiningWeightOf(firstId), 0);
    }

    function _exerciseStakeMintAndStake(IndexBrokerNFTStake pool) private returns (uint256 tokenId) {
        vm.startPrank(memberA);
        IERC20(HBTC).approve(address(pool), type(uint256).max);
        tokenId = pool.mint(0);
        pool.stakeIndexMining(tokenId, 5 ether);
        vm.stopPrank();
        assertEq(pool.indexMiningWeightOf(tokenId), 5 ether);
    }

    function _exerciseCommunityRewardClaim(IndexBrokerNFTBurn pool, uint256 injected) private {
        vm.warp(block.timestamp + 2 hours);
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256 pending = community.getPoolPendingRewards(address(pool), memberA);
        assertGt(injected, 0);
        assertGt(pending, 0, "hook-injected community reward did not accrue");
        uint256 beforeBalance = IERC20(HBTC).balanceOf(memberA);
        uint256 operationFee = committee.getPoolOperationFee();
        vm.prank(memberA);
        community.withdrawPoolsRewards{value: operationFee}(pools);
        assertGt(IERC20(HBTC).balanceOf(memberA), beforeBalance);
    }

    function _exerciseIndexRewardsAndBurnTransfer(IndexBrokerNFTBurn pool, uint256 tokenId) private {
        uint256 indexBought = _buyDefaultIndex(500e6);
        IERC20(DEFAULT_INDEX).approve(address(pool), indexBought);
        pool.injectIndexRewards(indexBought);
        uint256 beforeBalance = IERC20(DEFAULT_INDEX).balanceOf(memberA);
        vm.prank(memberA);
        assertGt(pool.claimIndexRewards(tokenId), 0);
        assertGt(IERC20(DEFAULT_INDEX).balanceOf(memberA), beforeBalance);

        vm.prank(memberA);
        pool.transferFrom(memberA, memberC, tokenId);
        assertFalse(pool.getNFTInfo(tokenId).indexMiningActive);
        vm.startPrank(memberC);
        IERC20(HBTC).approve(address(pool), type(uint256).max);
        pool.activateIndexMining(tokenId);
        pool.upgradeIndexMining(tokenId, 1 ether);
        vm.stopPrank();
        assertTrue(pool.getNFTInfo(tokenId).indexMiningActive);
    }

    function _exerciseAMMTrade(IndexBrokerNFTBurn pool, IndexBrokerNFTAMM amm, uint256 tokenId) private {
        uint256 sellFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberB);
        pool.approve(address(amm), tokenId);
        amm.sellNFT{value: sellFee}(tokenId);
        vm.stopPrank();
        assertEq(amm.inventoryCount(), 1);

        uint256 buyFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberC);
        IERC20(HBTC).approve(address(amm), type(uint256).max);
        assertEq(amm.buyNextNFT{value: buyFee}(), tokenId);
        vm.stopPrank();
        assertEq(pool.ownerOf(tokenId), memberC);
        assertEq(amm.inventoryCount(), 0);
    }

    function _exerciseStakeRewardsAndAMMCustody(IndexBrokerNFTStake pool, IndexBrokerNFTAMM amm, uint256 tokenId)
        private
    {
        uint256 indexBought = _buyDefaultIndex(250e6);
        IERC20(DEFAULT_INDEX).approve(address(pool), indexBought);
        pool.injectIndexRewards(indexBought);

        uint256 sellFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberA);
        pool.approve(address(amm), tokenId);
        amm.sellNFT{value: sellFee}(tokenId);
        vm.stopPrank();
        assertEq(pool.ownerOf(tokenId), address(amm));
        assertEq(pool.indexMiningWeightOf(tokenId), 5 ether);

        uint256 buyFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberB);
        IERC20(HBTC).approve(address(amm), type(uint256).max);
        assertEq(amm.buyNextNFT{value: buyFee}(), tokenId);
        uint256 rewardBefore = IERC20(DEFAULT_INDEX).balanceOf(memberB);
        assertGt(pool.claimIndexRewards(tokenId), 0);
        assertGt(IERC20(DEFAULT_INDEX).balanceOf(memberB), rewardBefore);
        uint256 principalBefore = IERC20(HBTC).balanceOf(memberB);
        pool.unstakeIndexMining(tokenId, 5 ether);
        assertEq(IERC20(HBTC).balanceOf(memberB), principalBefore + 5 ether);
        vm.stopPrank();
    }

    function _createBurnPool() private returns (IndexBrokerNFTBurn pool) {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config =
            _poolConfig(BURN_TEMPLATE, bytes(""), 1 ether, whitelist, allowances, "HBTCBURN");
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        uint256 settingsFee = committee.getCommunitySettingsFee();
        vm.prank(creator);
        community.adminAddPool{value: settingsFee}("HBTC Burn Index Broker", ratios, INDEX_FACTORY, abi.encode(config));
        pool = IndexBrokerNFTBurn(payable(community.activedPools(0)));
    }

    function _createStakePool() private returns (IndexBrokerNFTStake pool) {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config =
            _poolConfig(STAKE_TEMPLATE, abi.encode(HBTC), 0, whitelist, allowances, "HBTCSTAKE");
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        uint256 settingsFee = committee.getCommunitySettingsFee();
        vm.prank(creator);
        community.adminAddPool{value: settingsFee}("HBTC Stake Index Broker", ratios, INDEX_FACTORY, abi.encode(config));
        pool = IndexBrokerNFTStake(payable(community.activedPools(1)));
    }

    function _poolConfig(
        address template,
        bytes memory templateConfig,
        uint256 activationAmount,
        address[] memory whitelist,
        uint256[] memory allowances,
        string memory symbol
    ) private pure returns (IndexBrokerNFTFactory.PoolConfig memory config) {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0;
        thresholds[1] = 1;
        thresholds[2] = 2;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 10_000;
        weights[1] = 12_000;
        weights[2] = 15_000;
        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: POOL_MANAGER,
            currency0: address(0),
            currency1: HBTC,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: COMMUNITY_FEE_HOOK
        });
        IndexBrokerNFTFactory.AMMConfig memory ammConfig = IndexBrokerNFTFactory.AMMConfig({
            normalFeeBps: 1_000,
            specificFeeBps: 1_500,
            priceSourceType: INutboxRouter.SourceType.UNISWAP_V4,
            priceSourceData: abi.encode(source),
            indexToken: DEFAULT_INDEX,
            pump: address(0)
        });
        config = IndexBrokerNFTFactory.PoolConfig({
            symbol: symbol,
            fundsReceiver: address(0),
            renderer: address(0),
            nftTemplate: template,
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: 10 ether,
            indexMiningActivationTokenAmount: activationAmount,
            recommitPrice: 0.5 ether,
            nativePrice: 0.001 ether,
            maxSupply: 5,
            referralBps: 1_000,
            ammConfig: abi.encode(ammConfig),
            nftTemplateConfig: templateConfig,
            lockWhitelistSlots: false,
            rerollEnabled: true,
            whitelistAccounts: whitelist,
            whitelistAllowances: allowances
        });
    }

    function _fundMembers() private {
        deal(HBTC, memberA, 1_000 ether);
        deal(HBTC, memberB, 1_000 ether);
        deal(HBTC, memberC, 1_000 ether);
    }

    function _buy(PoolKey memory key, address actor, uint256 ethIn) private returns (BalanceDelta delta) {
        vm.prank(actor);
        delta = swapRouter.swap{value: ethIn}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _sell(PoolKey memory key, address actor, uint256 tokenIn) private returns (BalanceDelta delta) {
        vm.startPrank(actor);
        IERC20(HBTC).approve(address(swapRouter), tokenIn);
        delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();
    }

    function _buyDefaultIndex(uint256 settlementIn) private returns (uint256 indexOut) {
        deal(USDG, address(this), IERC20(USDG).balanceOf(address(this)) + settlementIn);
        IERC20(USDG).approve(BASKET_ROUTER, settlementIn);
        indexOut = ILiveBasketSwapRouterForCommunityFeeHook(BASKET_ROUTER)
            .buyExactSettlement(DEFAULT_INDEX, settlementIn, 1, _indexHookData(), address(this));
        assertGt(indexOut, 0);
    }

    function _indexHookData() private pure returns (bytes memory) {
        uint256[] memory legMins = new uint256[](8);
        for (uint256 i; i < legMins.length; ++i) {
            legMins[i] = 1;
        }
        return abi.encode(
            BasketTradeData({
                frontend: address(0),
                minBasketOut: 1,
                minUsdgOut: 1,
                legMins: legMins,
                legSqrtPriceLimitsX96: new uint160[](0),
                hubSqrtPriceLimitX96: 0,
                allowFailedLegs: new bool[](0)
            })
        );
    }
}
