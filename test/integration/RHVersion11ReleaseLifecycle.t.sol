// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "../../src/pump/Token.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {IndexBrokerNFTFactory} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import {
    IndexBrokerNFTBurn,
    IndexBrokerNFTStake
} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import {IndexBrokerNFTAMM} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import {IndexBrokerNFTRenderer} from "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTRenderer.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";
import {
    IndexBrokerCommunityToken,
    IndexBrokerIndexTokenMock,
    IndexBrokerBasketRegistryMock,
    IndexBrokerBasketHookMock,
    IndexBrokerIndexV3FactoryMock,
    IndexBrokerIndexV3RouterMock,
    IndexBrokerBasketSwapRouterMock,
    IndexBrokerPancakeV4VaultMock
} from "../unit/IndexBrokerNFT.t.sol";

/// @notice Release-gate lifecycle spanning the real RH Pump/Token/V4 listing and IndexBroker stack.
/// @dev Only the not-yet-deployed index Basket and its V3 settlement leg are deterministic mocks.
contract RHVersion11ReleaseLifecycleTest is V4PumpTestBase {
    uint32 internal constant BASKET_VERSION = 3;
    uint24 internal constant INDEX_V3_FEE = 100;
    uint256 internal constant COMMUNITY_TOKEN_PRICE = 1_000 ether;
    uint256 internal constant ACTIVATION_AMOUNT = 100 ether;
    uint256 internal constant NATIVE_MINT_PRICE = 0.1 ether;

    address internal memberA;
    address internal memberB;
    address internal memberC;
    address internal keeper;

    IndexBrokerCommunityToken internal wrappedNative;
    IndexBrokerCommunityToken internal indexSettlement;
    IndexBrokerIndexTokenMock internal indexToken;
    IndexBrokerBasketRegistryMock internal basketRegistry;
    IndexBrokerBasketHookMock internal basketHook;
    IndexBrokerBasketSwapRouterMock internal basketSwapRouter;
    IndexBrokerIndexV3FactoryMock internal indexV3Factory;
    IndexBrokerIndexV3RouterMock internal indexV3Router;
    NutboxRouter internal nutboxRouter;
    IndexBrokerNFTFactory internal indexBrokerFactory;
    IndexBrokerNFTBurn internal burnTemplate;
    IndexBrokerNFTStake internal stakeTemplate;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        if (!envReady) return;

        memberA = makeAddr("release-member-a");
        memberB = makeAddr("release-member-b");
        memberC = makeAddr("release-member-c");
        keeper = makeAddr("release-keeper");
        vm.deal(memberA, 100 ether);
        vm.deal(memberB, 100 ether);
        vm.deal(memberC, 100 ether);
        vm.deal(keeper, 100 ether);

        wrappedNative = new IndexBrokerCommunityToken();
        indexSettlement = new IndexBrokerCommunityToken();
        indexV3Factory = new IndexBrokerIndexV3FactoryMock();
        indexV3Router = new IndexBrokerIndexV3RouterMock(address(indexV3Factory), address(wrappedNative));
        indexV3Factory.setPool(
            address(wrappedNative),
            address(indexSettlement),
            INDEX_V3_FEE,
            address(new IndexBrokerPancakeV4VaultMock())
        );
        assertTrue(indexSettlement.transfer(address(indexV3Router), 1_000_000 ether));

        address[] memory v3Factories = new address[](1);
        v3Factories[0] = address(indexV3Factory);
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = address(manager);
        nutboxRouter = new NutboxRouter(
            address(wrappedNative),
            address(indexV3Router),
            new address[](0),
            new address[](0),
            v3Factories,
            uniswapV4Managers,
            new address[](0),
            bytes("")
        );

        basketRegistry = new IndexBrokerBasketRegistryMock();
        basketHook = new IndexBrokerBasketHookMock(address(basketRegistry), address(indexSettlement), BASKET_VERSION);
        basketSwapRouter = new IndexBrokerBasketSwapRouterMock(address(indexSettlement), address(basketHook));
        indexToken = new IndexBrokerIndexTokenMock("RH-V11-INDEX");
        indexToken.setWbnb(address(wrappedNative));
        indexToken.configureBasket(
            address(basketRegistry), address(basketHook), address(indexSettlement), BASKET_VERSION
        );
        basketRegistry.setIndexToken(address(indexToken), true, BASKET_VERSION);

        uint32[] memory versions = new uint32[](1);
        versions[0] = BASKET_VERSION;
        address[] memory basketRouters = new address[](1);
        basketRouters[0] = address(basketSwapRouter);
        burnTemplate = new IndexBrokerNFTBurn();
        stakeTemplate = new IndexBrokerNFTStake();
        indexBrokerFactory = new IndexBrokerNFTFactory(
            communityFactory,
            address(pump),
            address(new IndexBrokerNFTRenderer()),
            address(new IndexBrokerNFTAMM()),
            address(nutboxRouter),
            address(basketRegistry),
            versions,
            basketRouters,
            address(indexV3Router),
            INDEX_V3_FEE,
            address(indexToken)
        );
        indexBrokerFactory.addNFTTemplate(address(burnTemplate));
        indexBrokerFactory.addNFTTemplate(address(stakeTemplate));
        committee.adminAddContract(address(indexBrokerFactory));
    }

    function test_releaseLifecycle_tokenMarketAndBurnIndexBroker() external onlyReady {
        Token token = _createToken("RH-V11-RELEASE");

        // Token inner market: buy and sell against the bonding curve before listing.
        vm.warp(block.timestamp + 16);
        vm.prank(memberA);
        uint256 innerBought = token.buyToken{value: 1 ether}(0, creator, 0);
        assertGt(innerBought, 0);
        uint256 innerSupply = token.bondingCurveSupply();
        vm.prank(memberA);
        token.sellToken(innerBought / 4, 0, creator, 0);
        assertLt(token.bondingCurveSupply(), innerSupply);

        // Fill the curve, create the real hooked Uniswap V4 listing pool, then trade both directions.
        _fillBondingCurveUntilListed(token, buyer);
        assertTrue(token.listed());
        uint256 externalBalanceBefore = token.balanceOf(address(this));
        _simulateHookBuy(token, 0.25 ether);
        uint256 externalBought = token.balanceOf(address(this)) - externalBalanceBefore;
        assertGt(externalBought, 0);
        PoolKey memory listingPool = _buildPoolKey(address(token));
        assertGt(_swapSell(listingPool, address(this), externalBought / 4), 0);

        Community community = Community(payable(token.nutboxCommunity()));
        IndexBrokerNFTBurn pool = _createBurnPool(community);
        IndexBrokerNFTAMM amm = IndexBrokerNFTAMM(payable(pool.ammVault()));
        assertTrue(amm.active(), "listed official Token must activate its AMM during creation");
        assertEq(amm.pump(), address(pump));
        assertEq(uint8(amm.priceSourceType()), uint8(INutboxRouter.SourceType.UNISWAP_V4));

        _fundMember(token, memberA, 10_000 ether);
        _fundMember(token, memberB, 10_000 ether);
        _fundMember(token, memberC, 10_000 ether);

        // Whitelist mint, paid mint, referral accounting and referral level upgrade.
        vm.startPrank(memberA);
        token.approve(address(pool), type(uint256).max);
        uint256 firstId = pool.mint(0);
        vm.stopPrank();
        uint256 referrerNativeBefore = memberA.balance;
        vm.startPrank(memberB);
        token.approve(address(pool), type(uint256).max);
        uint256 secondId = pool.mint{value: NATIVE_MINT_PRICE}(firstId);
        vm.stopPrank();
        assertEq(firstId, 1);
        assertEq(secondId, 2);
        assertGt(memberA.balance, referrerNativeBefore);
        assertEq(pool.getNFTInfo(firstId).referralCount, 1);
        assertEq(pool.getNFTInfo(firstId).level, 2);

        // Reveal, paid recommit and the second reveal use the same real community token.
        vm.roll(uint256(pool.getNFTInfo(firstId).revealBlock) + 1);
        vm.prank(memberA);
        assertGt(pool.reveal(firstId), 0);
        uint256 recommitBalanceBefore = token.balanceOf(memberA);
        vm.prank(memberA);
        pool.commitReveal(firstId);
        assertEq(recommitBalanceBefore - token.balanceOf(memberA), 2 ether);
        vm.roll(uint256(pool.getNFTInfo(firstId).revealBlock) + 1);
        vm.prank(memberA);
        assertGt(pool.reveal(firstId), 0);

        // Burn-backed mining upgrade, transfer deactivation, reactivation and index reward claim.
        vm.startPrank(memberA);
        pool.upgradeIndexMining(firstId, 10 ether);
        pool.transferFrom(memberA, memberC, firstId);
        vm.stopPrank();
        assertFalse(pool.getNFTInfo(firstId).indexMiningActive);
        vm.startPrank(memberC);
        token.approve(address(pool), type(uint256).max);
        pool.activateIndexMining(firstId);
        pool.upgradeIndexMining(firstId, 5 ether);
        vm.stopPrank();
        indexToken.mint(address(this), 1_000 ether);
        indexToken.approve(address(pool), type(uint256).max);
        pool.injectIndexRewards(1_000 ether);
        uint256 rewardBefore = indexToken.balanceOf(memberC);
        vm.prank(memberC);
        assertGt(pool.claimIndexRewards(firstId), 0);
        assertGt(indexToken.balanceOf(memberC), rewardBefore);

        // Community mining rewards also accrue through Calculator -> Community -> IndexBroker weight.
        vm.startPrank(buyer);
        token.approve(address(calculator), 10_000 ether);
        calculator.inject(address(community), 10_000 ether);
        vm.stopPrank();
        uint16[] memory currentRatios = new uint16[](2);
        currentRatios[0] = 5_000;
        currentRatios[1] = 5_000;
        vm.prank(creator);
        community.adminSetPoolRatios(currentRatios);
        vm.warp(block.timestamp + 1 hours);
        address[] memory rewardPools = new address[](1);
        rewardPools[0] = address(pool);
        uint256 communityRewardBefore = token.balanceOf(memberC);
        vm.prank(memberC);
        community.withdrawPoolsRewards(rewardPools);
        assertGt(token.balanceOf(memberC), communityRewardBefore);

        // AMM secondary trade: sell an NFT into FIFO inventory and buy it back as another member.
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
        assertEq(amm.inventoryCount(), 0);

        // Index holder fees are permissionlessly harvested into the same AMM buyback reserve.
        uint256 holderFees = 1 ether;
        vm.deal(address(wrappedNative), holderFees);
        wrappedNative.approve(address(indexToken), holderFees);
        indexToken.fundHolderFees(address(pool), holderFees);
        uint256 reserveBeforeHarvest = address(amm).balance;
        vm.prank(keeper);
        assertEq(pool.harvestIndexHolderFees(), holderFees);
        assertEq(address(amm).balance, reserveBeforeHarvest + holderFees);

        // Native AMM reserve -> settlement -> index Basket -> NFT mining reward injection.
        uint256 injectedBefore = pool.totalIndexRewardsInjected();
        vm.prank(keeper);
        (uint256 callerReward, uint256 settlementOut, uint256 indexOut) =
            amm.buyIndexWithNativeReserve(1, 1, bytes(""));
        assertGt(callerReward, 0);
        assertGt(settlementOut, 0);
        assertGt(indexOut, 0);
        assertEq(pool.totalIndexRewardsInjected(), injectedBefore + indexOut);
    }

    function test_releaseLifecycle_stakeIndexBrokerAndAMMCustody() external onlyReady {
        Token token = _createAndListToken("RH-V11-STAKE");
        Community community = Community(payable(token.nutboxCommunity()));
        IndexBrokerNFTBurn burnPool = _createBurnPool(community);
        burnPool; // The first IndexBroker pool establishes the real community's multi-pool ratios.
        IndexBrokerNFTStake stakePool = _createStakePool(community, address(token));
        IndexBrokerNFTAMM stakeAMM = IndexBrokerNFTAMM(payable(stakePool.ammVault()));
        assertTrue(stakeAMM.active());

        _fundMember(token, memberA, 10_000 ether);
        _fundMember(token, memberB, 10_000 ether);
        vm.startPrank(memberA);
        token.approve(address(stakePool), type(uint256).max);
        uint256 tokenId = stakePool.mint(0);
        stakePool.stakeIndexMining(tokenId, 25 ether);
        vm.stopPrank();
        assertEq(stakePool.indexMiningWeightOf(tokenId), 25 ether);

        indexToken.mint(address(this), 500 ether);
        indexToken.approve(address(stakePool), type(uint256).max);
        stakePool.injectIndexRewards(500 ether);

        // Stake principal and reward rights remain attached to tokenId while the AMM holds it.
        uint256 sellFee = stakeAMM.quoteNormalNativeFee();
        vm.startPrank(memberA);
        stakePool.approve(address(stakeAMM), tokenId);
        stakeAMM.sellNFT{value: sellFee}(tokenId);
        vm.stopPrank();
        assertEq(stakePool.ownerOf(tokenId), address(stakeAMM));
        assertEq(stakePool.indexMiningWeightOf(tokenId), 25 ether);

        uint256 buyFee = stakeAMM.quoteNormalNativeFee();
        vm.startPrank(memberB);
        token.approve(address(stakeAMM), type(uint256).max);
        assertEq(stakeAMM.buyNextNFT{value: buyFee}(), tokenId);
        uint256 rewardBefore = indexToken.balanceOf(memberB);
        assertGt(stakePool.claimIndexRewards(tokenId), 0);
        assertGt(indexToken.balanceOf(memberB), rewardBefore);
        uint256 principalBefore = token.balanceOf(memberB);
        stakePool.unstakeIndexMining(tokenId, 25 ether);
        assertEq(token.balanceOf(memberB), principalBefore + 25 ether);
        vm.stopPrank();
        assertEq(stakePool.indexMiningWeightOf(tokenId), 0);
    }

    function _createBurnPool(Community community) internal returns (IndexBrokerNFTBurn pool) {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config = _basePoolConfig(
            address(burnTemplate), bytes(""), ACTIVATION_AMOUNT, whitelist, allowances
        );
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        vm.prank(creator);
        community.adminAddPool("RH V11 Burn Index Broker", ratios, address(indexBrokerFactory), abi.encode(config));
        pool = IndexBrokerNFTBurn(payable(community.activedPools(1)));
    }

    function _createStakePool(Community community, address stakingToken)
        internal
        returns (IndexBrokerNFTStake pool)
    {
        address[] memory whitelist = new address[](1);
        whitelist[0] = memberA;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFTFactory.PoolConfig memory config =
            _basePoolConfig(address(stakeTemplate), abi.encode(stakingToken), 0, whitelist, allowances);
        uint16[] memory ratios = new uint16[](3);
        ratios[0] = 3_333;
        ratios[1] = 3_333;
        ratios[2] = 3_334;
        vm.prank(creator);
        community.adminAddPool("RH V11 Stake Index Broker", ratios, address(indexBrokerFactory), abi.encode(config));
        pool = IndexBrokerNFTStake(payable(community.activedPools(2)));
    }

    function _basePoolConfig(
        address template,
        bytes memory templateConfig,
        uint256 activationAmount,
        address[] memory whitelist,
        uint256[] memory allowances
    ) internal view returns (IndexBrokerNFTFactory.PoolConfig memory config) {
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
            indexToken: address(indexToken),
            pump: address(0)
        });
        config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "RHIDX",
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

    function _fundMember(Token token, address member, uint256 amount) internal {
        vm.prank(buyer);
        assertTrue(token.transfer(member, amount));
    }
}
