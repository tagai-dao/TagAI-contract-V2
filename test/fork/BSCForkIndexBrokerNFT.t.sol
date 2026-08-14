// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";

import {Community} from "../../src/nutbox/Community.sol";
import {IIndexBrokerNFTPriceOracle} from "../../src/nutbox/dapps/index-broker-nft/IIndexBrokerNFTPriceOracle.sol";
import {IndexBrokerNFT} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {
    IndexBrokerNFTAMM,
    IIndexBrokerBasketSwapRouter
} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {IndexBrokerNFTPriceOracle} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTPriceOracle.sol";
import {IndexBrokerNFTRenderer} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTRenderer.sol";
import {IBasketToken} from "../../src/interfaces/IBasketToken.sol";

/**
 * @title BSCForkIndexBrokerNFT
 * @notice End-to-end BSC mainnet-fork coverage for the Index Broker NFT AMM.
 * @dev The Pump, Token, Hook and NFT contracts are deployed from this branch. BasketRegistry,
 *      BasketSwapRouter, Pancake SmartRouter, BNB/USDT V3 liquidity and the index Basket are
 *      the live BSC contracts at the fork block.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --rpc-url bsc \
 *     --match-contract BSCForkIndexBrokerNFT -vvv
 */
contract BSCForkIndexBrokerNFT is BSCForkBase {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant BASKET_REGISTRY = 0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe;
    address internal constant BASKET_SWAP_ROUTER = 0x4c3a94f166d3046F10D002FDDe426E9C0b6C703e;
    address internal constant PANCAKE_V3_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant INDEX_TOKEN = 0xcF99DeC9439630ccf7Efe392F0fc2aF98EF99a61;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint24 internal constant BNB_USDT_V3_FEE = 100;
    uint256 internal constant COMMUNITY_TOKEN_PRICE = 1_000_000 ether;
    uint256 internal constant INDEX_WEIGHT_PER_NFT = 10 ether;
    uint16 internal constant NORMAL_AMM_FEE_BPS = 1_000;
    uint16 internal constant SPECIFIC_AMM_FEE_BPS = 1_500;

    function test_fork_realBasketBuybackDistributesAndClaimsIndexRewards() public onlyBscFork {
        Token token = _createAndListToken("FORKINDEXNFT");

        _collectAndAssertListingFees(token);

        (IndexBrokerNFT nft, IndexBrokerNFTAMM amm) = _createIndexBrokerPool(token);
        _mintAndWeightTwoNFTs(token, nft);

        uint256 platformBefore = FEE_RECEIVER.balance;
        uint256 totalNativeFee = amm.quoteNormalNativeFee();
        uint256 tradingFee = amm.quoteNormalTradingNativeFee();
        uint256 platformFee = amm.quotePlatformNativeFee();
        assertGt(tradingFee, 0, "NFT AMM trading fee is zero");
        assertEq(totalNativeFee, tradingFee + platformFee, "NFT AMM fee quote mismatch");

        vm.prank(buyer);
        nft.approve(address(amm), 1);
        vm.prank(buyer);
        amm.sellNFT{value: totalNativeFee}(1);

        assertEq(FEE_RECEIVER.balance - platformBefore, platformFee, "NFT AMM platform fee");
        assertEq(address(amm).balance, tradingFee, "NFT AMM retained trading fee");
        assertEq(nft.ownerOf(1), address(amm), "sold NFT not held by AMM");
        assertFalse(nft.indexMiningActiveOf(1), "AMM NFT must be inactive");
        assertEq(nft.activeIndexMiningWeightOf(2), INDEX_WEIGHT_PER_NFT, "active NFT weight");

        address executor = makeAddr("forkIndexBuybackExecutor");
        uint256 nativeReserve = address(amm).balance;
        uint256 expectedCallerReward = nativeReserve * 100 / 10_000;
        uint256 executorBefore = executor.balance;
        uint256 poolIndexBefore = IERC20(INDEX_TOKEN).balanceOf(address(nft));
        uint256 buyerIndexBefore = IERC20(INDEX_TOKEN).balanceOf(buyer);
        uint256 totalInjectedBefore = nft.totalIndexRewardsInjected();

        vm.prank(executor);
        (uint256 callerReward, uint256 settlementOut, uint256 indexOut) = amm.buyIndexWithNativeReserve(1, 1, bytes(""));

        assertEq(callerReward, expectedCallerReward, "buyback caller reward");
        assertEq(executor.balance - executorBefore, expectedCallerReward, "executor BNB compensation");
        assertGt(settlementOut, 0, "Pancake V3 returned no USDT");
        assertGt(indexOut, 0, "Basket Router returned no index token");
        assertEq(address(amm).balance, 0, "AMM native reserve not exhausted");
        assertEq(IERC20(INDEX_TOKEN).balanceOf(address(amm)), 0, "AMM retained index token");
        assertEq(IERC20(INDEX_TOKEN).balanceOf(address(nft)) - poolIndexBefore, indexOut, "index injection");
        assertEq(nft.totalIndexRewardsInjected() - totalInjectedBefore, indexOut, "injected accounting");

        uint256 recycledIndexOut = _accrueHarvestAndRecycleIndexHolderFees(nft, amm);

        uint256 pending = nft.pendingIndexRewardsOf(2);
        assertGt(pending, 0, "active NFT received no index rewards");
        assertLe(pending, indexOut + recycledIndexOut, "pending rewards exceed buybacks");
        assertEq(nft.pendingIndexRewardsOf(1), 0, "inactive AMM NFT received rewards");

        vm.prank(buyer);
        uint256 claimed = nft.claimIndexRewards(2);
        assertEq(claimed, pending, "claim differs from pending reward");
        assertEq(IERC20(INDEX_TOKEN).balanceOf(buyer) - buyerIndexBefore, claimed, "index reward payout");
        assertEq(nft.totalIndexRewardsClaimed(), claimed, "claimed accounting");
    }

    function _accrueHarvestAndRecycleIndexHolderFees(IndexBrokerNFT nft, IndexBrokerNFTAMM amm)
        internal
        returns (uint256 recycledIndexOut)
    {
        uint256 settlementIn = 100 ether;
        deal(USDT, buyer2, settlementIn);
        vm.startPrank(buyer2);
        assertTrue(IERC20(USDT).approve(BASKET_SWAP_ROUTER, settlementIn));
        uint256 externalIndexOut = IIndexBrokerBasketSwapRouter(BASKET_SWAP_ROUTER)
            .buyExactSettlement(INDEX_TOKEN, settlementIn, 1, bytes(""), buyer2);
        vm.stopPrank();
        assertGt(externalIndexOut, 0, "external Basket trade failed");

        uint256 claimable = IBasketToken(INDEX_TOKEN).claimableHolderFees(address(nft));
        assertGt(claimable, 0, "NFT pool accrued no Index holder fees");
        uint256 ammNativeBefore = address(amm).balance;
        address keeper = makeAddr("forkIndexHolderFeeKeeper");
        vm.prank(keeper);
        uint256 harvested = nft.harvestIndexHolderFees();

        assertEq(harvested, claimable, "holder fee harvest mismatch");
        assertEq(address(amm).balance - ammNativeBefore, harvested, "holder fees not added to AMM reserve");
        assertEq(IERC20(WBNB).balanceOf(address(nft)), 0, "NFT retained WBNB");
        assertEq(IERC20(WBNB).balanceOf(address(amm)), 0, "AMM retained WBNB");

        uint256 reserve = address(amm).balance;
        uint256 expectedReward = reserve * amm.INDEX_PURCHASE_CALLER_BPS() / 10_000;
        uint256 injectedBefore = nft.totalIndexRewardsInjected();
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        (uint256 callerReward,, uint256 indexOut) = amm.buyIndexWithNativeReserve(1, 1, bytes(""));

        assertEq(callerReward, expectedReward, "recycled reserve caller reward");
        assertEq(keeper.balance - keeperBefore, expectedReward, "recycle keeper compensation");
        assertGt(indexOut, 0, "holder fee reserve bought no Index");
        assertEq(nft.totalIndexRewardsInjected() - injectedBefore, indexOut, "holder fee buyback not injected");
        assertEq(address(amm).balance, 0, "holder fee reserve not exhausted");
        recycledIndexOut = indexOut;
    }

    function _collectAndAssertListingFees(Token token) internal {
        PoolKey memory poolKey = _buildPoolKey(address(token));
        uint256 bought = _swapBuyExactIn(poolKey, buyer2, 20 ether);
        assertGt(bought, 0, "PCS V4 buy failed");
        assertGt(_swapSellExactIn(poolKey, buyer2, bought / 2), 0, "PCS V4 sell failed");

        address collector = makeAddr("forkListingFeeCollector");
        uint256 collectorBefore = collector.balance;
        uint256 platformBefore = FEE_RECEIVER.balance;
        uint256 hookTokenBefore = IERC20(address(token)).balanceOf(address(hook));

        vm.prank(collector);
        (uint256 bnbAmount, uint256 tokenAmount) = token.collectFees();

        assertGt(bnbAmount, 0, "no BNB LP fee collected");
        assertGt(tokenAmount, 0, "no token LP fee collected");
        uint256 callerReward = bnbAmount * token.COLLECT_CALLER_REWARD_BPS() / 10_000;
        assertEq(collector.balance - collectorBefore, callerReward, "LP fee caller reward");
        assertEq(FEE_RECEIVER.balance - platformBefore, bnbAmount - callerReward, "LP platform fee");
        assertEq(
            IERC20(address(token)).balanceOf(address(hook)) - hookTokenBefore, tokenAmount, "LP token fee destination"
        );
    }

    function _createIndexBrokerPool(Token token) internal returns (IndexBrokerNFT nft, IndexBrokerNFTAMM amm) {
        address[] memory pancakeManagers = new address[](1);
        pancakeManagers[0] = CL_POOL_MANAGER;
        IndexBrokerNFTPriceOracle oracle =
            new IndexBrokerNFTPriceOracle(WBNB, new address[](0), new address[](0), new address[](0), pancakeManagers);
        IndexBrokerNFTFactory factory = new IndexBrokerNFTFactory(
            COMMUNITY_FACTORY,
            address(pump),
            address(new IndexBrokerNFTRenderer()),
            address(new IndexBrokerNFTAMM()),
            address(oracle),
            BASKET_REGISTRY,
            BASKET_SWAP_ROUTER,
            PANCAKE_V3_SMART_ROUTER,
            BNB_USDT_V3_FEE,
            INDEX_TOKEN
        );

        address committeeOwner = Ownable(COMMITTEE).owner();
        vm.prank(committeeOwner);
        ICommittee(COMMITTEE).adminAddContract(address(factory));

        address[] memory whitelist = new address[](1);
        whitelist[0] = buyer;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 2;
        uint256[] memory thresholds = new uint256[](1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;

        IndexBrokerNFTFactory.AMMConfig memory ammConfig = IndexBrokerNFTFactory.AMMConfig({
            normalFeeBps: NORMAL_AMM_FEE_BPS,
            specificFeeBps: SPECIFIC_AMM_FEE_BPS,
            priceSourceType: IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL,
            priceSourceData: bytes(""),
            indexToken: INDEX_TOKEN
        });
        IndexBrokerNFTFactory.PoolConfig memory config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "FIDX",
            fundsReceiver: creator,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            indexMiningActivationTokenAmount: 100 ether,
            recommitPrice: 0,
            nativePrice: 0,
            maxSupply: 2,
            referralBps: 0,
            ammConfig: abi.encode(ammConfig),
            lockWhitelistSlots: true,
            rerollEnabled: false,
            whitelistAccounts: whitelist,
            whitelistAllowances: allowances
        });

        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        Community community = Community(payable(token.nutboxCommunity()));
        uint256 settingsFee = ICommittee(COMMITTEE).getCommunitySettingsFee();
        vm.deal(creator, creator.balance + settingsFee);
        vm.prank(creator);
        community.adminAddPool{value: settingsFee}(
            "Fork Index Broker NFT", ratios, address(factory), abi.encode(config)
        );

        nft = IndexBrokerNFT(payable(community.activedPools(1)));
        amm = IndexBrokerNFTAMM(payable(nft.ammVault()));
        assertTrue(amm.active(), "official-token AMM not activated");
        assertEq(amm.indexToken(), INDEX_TOKEN, "wrong index token");
        assertEq(amm.INDEX_PURCHASE_CALLER_BPS(), 100, "wrong buyback caller BPS");
    }

    function _mintAndWeightTwoNFTs(Token token, IndexBrokerNFT nft) internal {
        uint256 required = COMMUNITY_TOKEN_PRICE * 2 + INDEX_WEIGHT_PER_NFT * 2;
        assertGe(IERC20(address(token)).balanceOf(buyer), required, "buyer lacks community tokens");

        vm.startPrank(buyer);
        token.approve(address(nft), required);
        assertEq(nft.mint(0), 1, "first NFT id");
        assertEq(nft.mint(0), 2, "second NFT id");
        nft.upgradeIndexMining(1, INDEX_WEIGHT_PER_NFT);
        nft.upgradeIndexMining(2, INDEX_WEIGHT_PER_NFT);
        vm.stopPrank();

        assertEq(nft.indexMiningWeightOf(1), INDEX_WEIGHT_PER_NFT, "first NFT weight");
        assertEq(nft.indexMiningWeightOf(2), INDEX_WEIGHT_PER_NFT, "second NFT weight");
    }
}
