// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "../../src/pump/Token.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {IndexBrokerNFTBurn, IndexBrokerNFTStake} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTAMM} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {RHForkBase} from "./RHForkBase.t.sol";

interface ILiveBasketSwapRouter {
    function buyExactSettlement(
        address basket,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 basketOut);

    function sellExactBasket(
        address basket,
        uint256 basketIn,
        uint256 minSettlementOut,
        bytes calldata hookData,
        address recipient
    ) external returns (uint256 settlementOut);
}

/// @notice Release gate that exercises the exact RH v11 contracts already deployed on mainnet.
/// @dev Every mutation is isolated inside the fork; this test never broadcasts a transaction.
contract RHDeployedV11LifecycleTest is RHForkBase {
    struct BasketTradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minUsdgOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 hubSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }

    address internal constant LIVE_PUMP = 0x7686CbaF2dFc7000eb9b0D6DE81E48c1211d2655;
    address internal constant LIVE_HOOK = 0x841dcAD307A4444dC9E65F5709B2DC5e054C20cC;
    address internal constant LIVE_IPSHARE = 0x8A7b0d80FA92699CE3e5bB2c8fE404D6733796d1;
    address internal constant LIVE_COMMITTEE = 0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0;
    address internal constant LIVE_COMMUNITY_FACTORY = 0x24328DccA1bA54EeE82e2993F021802e64290486;
    address internal constant LIVE_CALCULATOR = 0x3DC52C69C3C8be568372E16d50E9F3FEc796610c;
    address internal constant LIVE_SCF = 0xddbAba530728b5B8939d7fdDC334432490916e90;

    address internal constant LIVE_INDEX_FACTORY = 0x678871773b07322aA927FE5057870D1356F09676;
    address internal constant LIVE_BURN_TEMPLATE = 0x1fCB38D03231cCC7D62C45A5Ee5184A2486778d0;
    address internal constant LIVE_STAKE_TEMPLATE = 0x0971018D38523021333B94088E69fCF1726606b1;
    address internal constant LIVE_AMM_TEMPLATE = 0x70978301e27fb2Aa931035EFB5d78542a0AAB898;
    address internal constant LIVE_RENDERER = 0x3cAf852BF1F5A3781f7D809376D82e7ba0037C81;
    address internal constant LIVE_DEFAULT_INDEX = 0x90d2cCA000Dc36fA8401632C67faFDa7D7860C07;
    address internal constant LIVE_BASKET_ROUTER = 0x9b5e6b7CC3661737e6A118e0D4f0F89fB1034653;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant SAFE = 0x871fb7006C5964B21695Ba20006021777A26146C;

    uint256 internal constant COMMUNITY_TOKEN_PRICE = 1_000 ether;
    uint256 internal constant ACTIVATION_AMOUNT = 100 ether;
    uint256 internal constant NATIVE_MINT_PRICE = 0.01 ether;

    address internal memberA;
    address internal memberB;
    address internal memberC;
    address internal keeper;

    IndexBrokerNFTFactory internal liveFactory;

    receive() external payable {}

    function setUp() public override {
        creator = makeAddr("deployed-v11-creator");
        buyer = makeAddr("deployed-v11-buyer");
        buyer2 = makeAddr("deployed-v11-buyer2");
        feeRecipient = makeAddr("deployed-v11-fee-recipient");
        memberA = makeAddr("deployed-v11-member-a");
        memberB = makeAddr("deployed-v11-member-b");
        memberC = makeAddr("deployed-v11-member-c");
        keeper = makeAddr("deployed-v11-keeper");

        if (!_bootstrapPoolManager()) return;
        if (block.chainid != 4_663) return;

        pump = Pump(payable(LIVE_PUMP));
        hook = TagAISwapHook(payable(LIVE_HOOK));
        ipshare = IPShare(payable(LIVE_IPSHARE));
        committee = Committee(payable(LIVE_COMMITTEE));
        communityFactory = LIVE_COMMUNITY_FACTORY;
        calculator = HourlyTickCalculator(LIVE_CALCULATOR);
        scf = LIVE_SCF;
        liveFactory = IndexBrokerNFTFactory(LIVE_INDEX_FACTORY);

        assertGt(LIVE_PUMP.code.length, 0);
        assertGt(LIVE_HOOK.code.length, 0);
        assertGt(LIVE_INDEX_FACTORY.code.length, 0);
        assertEq(address(hook.poolManager()), RH_POOL_MANAGER);
        assertEq(pump.getHookAddress(), LIVE_HOOK);
        assertEq(liveFactory.owner(), SAFE);
        assertEq(liveFactory.pendingOwner(), address(0));
        assertTrue(committee.verifyContract(LIVE_INDEX_FACTORY));
        assertEq(liveFactory.defaultRenderer(), LIVE_RENDERER);
        assertEq(liveFactory.ammTemplate(), LIVE_AMM_TEMPLATE);
        assertEq(liveFactory.defaultIndexToken(), LIVE_DEFAULT_INDEX);
        assertEq(liveFactory.basketSwapRouterForVersion(3), LIVE_BASKET_ROUTER);
        assertTrue(liveFactory.supportedPump(LIVE_PUMP));
        assertTrue(liveFactory.supportedNFTTemplate(LIVE_BURN_TEMPLATE));
        assertTrue(liveFactory.supportedNFTTemplate(LIVE_STAKE_TEMPLATE));

        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(memberA, 100 ether);
        vm.deal(memberB, 100 ether);
        vm.deal(memberC, 100 ether);
        vm.deal(keeper, 100 ether);
        vm.warp(block.timestamp + 16);
        envReady = true;
    }

    function testFork_liveTokenInnerOuterAndBurnBrokerLifecycle() external onlyRhFork {
        Token token = _createLiveToken("RHV11LIVEBURN");

        vm.prank(memberA, memberA);
        uint256 innerBought = token.buyToken{value: 0.25 ether}(0, creator, 0);
        assertGt(innerBought, 0, "inner buy");
        uint256 curveSupplyBeforeSell = token.bondingCurveSupply();
        vm.prank(memberA, memberA);
        token.sellToken(innerBought / 4, 0, creator, 0);
        assertLt(token.bondingCurveSupply(), curveSupplyBeforeSell, "inner sell");

        _fillBondingCurveUntilListed(token, buyer);
        assertTrue(token.listed(), "live Pump listing");
        PoolKey memory listingPool = _buildPoolKey(address(token));
        uint256 externalBought = _swapBuyExactIn(listingPool, memberA, 0.05 ether);
        assertGt(externalBought, 0, "outer buy");
        assertGt(_swapSellExactIn(listingPool, memberA, externalBought / 4), 0, "outer sell");

        Community community = Community(payable(token.nutboxCommunity()));
        IndexBrokerNFTBurn pool = _createBurnPool(community);
        IndexBrokerNFTAMM amm = IndexBrokerNFTAMM(payable(pool.ammVault()));
        assertTrue(amm.active(), "live AMM active");
        assertEq(amm.indexToken(), LIVE_DEFAULT_INDEX);
        assertEq(amm.pump(), LIVE_PUMP);

        _fundMember(token, memberA, 10_000 ether);
        _fundMember(token, memberB, 10_000 ether);
        _fundMember(token, memberC, 10_000 ether);

        vm.startPrank(memberA);
        token.approve(address(pool), type(uint256).max);
        uint256 firstId = pool.mint(0);
        vm.stopPrank();

        uint256 referralNativeBefore = memberA.balance;
        vm.startPrank(memberB);
        token.approve(address(pool), type(uint256).max);
        uint256 secondId = pool.mint{value: NATIVE_MINT_PRICE}(firstId);
        vm.stopPrank();
        assertEq(pool.getNFTInfo(firstId).referralCount, 1);
        assertEq(pool.getNFTInfo(firstId).level, 2);
        assertGt(memberA.balance, referralNativeBefore, "referral reward");

        vm.startPrank(memberA);
        pool.upgradeIndexMining(firstId, 10 ether);
        pool.transferFrom(memberA, memberC, firstId);
        vm.stopPrank();
        assertFalse(pool.getNFTInfo(firstId).indexMiningActive, "transfer deactivates mining");
        vm.startPrank(memberC);
        token.approve(address(pool), type(uint256).max);
        pool.activateIndexMining(firstId);
        pool.upgradeIndexMining(firstId, 5 ether);
        vm.stopPrank();

        uint256 boughtIndex = _buyLiveIndex(address(this), 500e6);
        IERC20(LIVE_DEFAULT_INDEX).approve(address(pool), boughtIndex);
        pool.injectIndexRewards(boughtIndex);
        uint256 indexBefore = IERC20(LIVE_DEFAULT_INDEX).balanceOf(memberC);
        vm.prank(memberC);
        uint256 claimed = pool.claimIndexRewards(firstId);
        assertGt(claimed, 0, "index reward claim");
        assertEq(IERC20(LIVE_DEFAULT_INDEX).balanceOf(memberC), indexBefore + claimed);

        uint256 sellFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberB);
        pool.approve(address(amm), secondId);
        amm.sellNFT{value: sellFee}(secondId);
        vm.stopPrank();
        assertEq(amm.inventoryCount(), 1);
        uint256 buyFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberC);
        token.approve(address(amm), type(uint256).max);
        assertEq(amm.buyNextNFT{value: buyFee}(), secondId);
        vm.stopPrank();
        assertEq(pool.ownerOf(secondId), memberC);

        uint256 settlementBefore = IERC20(USDG).balanceOf(memberC);
        vm.startPrank(memberC);
        IERC20(LIVE_DEFAULT_INDEX).approve(LIVE_BASKET_ROUTER, claimed / 4);
        uint256 settlementOut = ILiveBasketSwapRouter(LIVE_BASKET_ROUTER)
            .sellExactBasket(LIVE_DEFAULT_INDEX, claimed / 4, 1, bytes(""), memberC);
        vm.stopPrank();
        assertGt(settlementOut, 0, "index sell");
        assertEq(IERC20(USDG).balanceOf(memberC), settlementBefore + settlementOut);

        uint256 injectedBefore = pool.totalIndexRewardsInjected();
        vm.prank(keeper);
        (uint256 callerReward, uint256 settlementBought, uint256 indexBought) =
            amm.buyIndexWithNativeReserve(1, 1, _indexHookData());
        assertGt(callerReward, 0, "keeper reward");
        assertGt(settlementBought, 0, "native to USDG");
        assertGt(indexBought, 0, "AMM index buy");
        assertEq(pool.totalIndexRewardsInjected(), injectedBefore + indexBought);
    }

    function testFork_liveStakeBrokerCustodyAndRewards() external onlyRhFork {
        Token token = _createLiveToken("RHV11LIVESTAKE");
        _fillBondingCurveUntilListed(token, buyer);
        Community community = Community(payable(token.nutboxCommunity()));
        _createBurnPool(community);
        IndexBrokerNFTStake stakePool = _createStakePool(community, address(token));
        IndexBrokerNFTAMM amm = IndexBrokerNFTAMM(payable(stakePool.ammVault()));
        assertTrue(amm.active());

        _fundMember(token, memberA, 10_000 ether);
        _fundMember(token, memberB, 10_000 ether);
        vm.startPrank(memberA);
        token.approve(address(stakePool), type(uint256).max);
        uint256 tokenId = stakePool.mint(0);
        stakePool.stakeIndexMining(tokenId, 25 ether);
        vm.stopPrank();
        assertEq(stakePool.indexMiningWeightOf(tokenId), 25 ether);

        uint256 boughtIndex = _buyLiveIndex(address(this), 250e6);
        IERC20(LIVE_DEFAULT_INDEX).approve(address(stakePool), boughtIndex);
        stakePool.injectIndexRewards(boughtIndex);

        uint256 sellFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberA);
        stakePool.approve(address(amm), tokenId);
        amm.sellNFT{value: sellFee}(tokenId);
        vm.stopPrank();
        assertEq(stakePool.ownerOf(tokenId), address(amm));
        assertEq(stakePool.indexMiningWeightOf(tokenId), 25 ether);

        uint256 buyFee = amm.quoteNormalNativeFee();
        vm.startPrank(memberB);
        token.approve(address(amm), type(uint256).max);
        assertEq(amm.buyNextNFT{value: buyFee}(), tokenId);
        uint256 rewardBefore = IERC20(LIVE_DEFAULT_INDEX).balanceOf(memberB);
        assertGt(stakePool.claimIndexRewards(tokenId), 0);
        assertGt(IERC20(LIVE_DEFAULT_INDEX).balanceOf(memberB), rewardBefore);
        uint256 principalBefore = token.balanceOf(memberB);
        stakePool.unstakeIndexMining(tokenId, 25 ether);
        assertEq(token.balanceOf(memberB), principalBefore + 25 ether);
        vm.stopPrank();
    }

    function _createLiveToken(string memory tick) private returns (Token token) {
        _ensureCreatorIPShare();
        uint256 value = pump.createFee() + 1 ether;
        vm.prank(creator, creator);
        token = Token(payable(pump.createToken{value: value}(tick, keccak256(abi.encode(tick, block.number)))));
        assertTrue(pump.createdTokens(address(token)));
        assertNotEq(token.nutboxCommunity(), address(0));
    }

    function _createBurnPool(Community community) private returns (IndexBrokerNFTBurn pool) {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config =
            _basePoolConfig(LIVE_BURN_TEMPLATE, bytes(""), ACTIVATION_AMOUNT, whitelist, allowances);
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        uint256 settingsFee = committee.getCommunitySettingsFee();
        vm.prank(creator);
        community.adminAddPool{value: settingsFee}(
            "RH Live Burn Index Broker", ratios, LIVE_INDEX_FACTORY, abi.encode(config)
        );
        pool = IndexBrokerNFTBurn(payable(community.activedPools(1)));
        assertGt(address(pool).code.length, 0);
    }

    function _createStakePool(Community community, address stakingToken) private returns (IndexBrokerNFTStake pool) {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config =
            _basePoolConfig(LIVE_STAKE_TEMPLATE, abi.encode(stakingToken), 0, whitelist, allowances);
        uint16[] memory ratios = new uint16[](3);
        ratios[0] = 3_333;
        ratios[1] = 3_333;
        ratios[2] = 3_334;
        uint256 settingsFee = committee.getCommunitySettingsFee();
        vm.prank(creator);
        community.adminAddPool{value: settingsFee}(
            "RH Live Stake Index Broker", ratios, LIVE_INDEX_FACTORY, abi.encode(config)
        );
        pool = IndexBrokerNFTStake(payable(community.activedPools(2)));
        assertGt(address(pool).code.length, 0);
    }

    function _basePoolConfig(
        address template,
        bytes memory templateConfig,
        uint256 activationAmount,
        address[] memory whitelist,
        uint256[] memory allowances
    ) private view returns (IndexBrokerNFTFactory.PoolConfig memory config) {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0;
        thresholds[1] = 1;
        thresholds[2] = 2;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 10_000;
        weights[1] = 12_000;
        weights[2] = 15_000;
        IndexBrokerNFTFactory.AMMConfig memory ammConfig = IndexBrokerNFTFactory.AMMConfig({
            normalFeeBps: 1_000,
            specificFeeBps: 1_500,
            priceSourceType: INutboxRouter.SourceType.UNISWAP_V4,
            priceSourceData: bytes(""),
            indexToken: LIVE_DEFAULT_INDEX,
            pump: address(0)
        });
        config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "RHLIVE",
            fundsReceiver: address(0),
            renderer: address(0),
            nftTemplate: template,
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            indexMiningActivationTokenAmount: activationAmount,
            recommitPrice: 2 ether,
            nativePrice: NATIVE_MINT_PRICE,
            maxSupply: 4,
            referralBps: 1_000,
            ammConfig: abi.encode(ammConfig),
            nftTemplateConfig: templateConfig,
            lockWhitelistSlots: false,
            rerollEnabled: true,
            whitelistAccounts: whitelist,
            whitelistAllowances: allowances
        });
    }

    function _buyLiveIndex(address recipient, uint256 settlementIn) private returns (uint256 indexOut) {
        deal(USDG, address(this), IERC20(USDG).balanceOf(address(this)) + settlementIn);
        IERC20(USDG).approve(LIVE_BASKET_ROUTER, settlementIn);
        indexOut = ILiveBasketSwapRouter(LIVE_BASKET_ROUTER)
            .buyExactSettlement(LIVE_DEFAULT_INDEX, settlementIn, 1, _indexHookData(), recipient);
        assertGt(indexOut, 0, "live index buy");
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

    function _fundMember(Token token, address member, uint256 amount) private {
        vm.prank(buyer);
        assertTrue(token.transfer(member, amount));
    }
}
