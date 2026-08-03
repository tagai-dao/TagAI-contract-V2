// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {Committee} from "../../src/nutbox/Committee.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {CommunityFactory} from "../../src/nutbox/CommunityFactory.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {NFTMiningPool} from "../../src/nutbox/dapps/nft-mining/NFTMiningPool.sol";
import {NFTMiningPoolFactory} from "../../src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol";
import {BasketStakePool} from "../../src/nutbox/dapps/basket-tvl-mining/BasketStakePool.sol";
import {BasketTVLMiningPool} from "../../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPool.sol";
import {BasketTVLMiningPoolFactory} from "../../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPoolFactory.sol";

interface IBSCBasketRegistry {
    function isBasket(address basket) external view returns (bool);
    function basketCount() external view returns (uint256);
}

interface IBSCBasketRouter {
    enum Venue {
        V4,
        V3,
        WBNB
    }

    struct LegRoute {
        Venue venue;
        PoolKey v4Pool;
        uint24 v3Fee;
    }

    struct CreateParams {
        string name;
        string symbol;
        address creator;
        uint16 basketFeeBps;
        uint16 creatorShareBps;
        address[] constituentAssets;
        LegRoute[] constituentRoutes;
        uint16[] targetWeights;
    }

    struct TradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minSettlementOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 hubSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }

    function createAndBuyExactSettlement(
        bytes32 userSalt,
        CreateParams calldata createParams,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata hookData,
        address recipient
    ) external returns (address basket, uint256 basketOut);
}

interface IBSCLiveBasket {
    function creatorPayout() external view returns (address);
    function wbnb() external view returns (address);
    function assetCount() external view returns (uint256);
    function assetAt(uint256 index) external view returns (address asset, uint16 weight, uint256 activeReserve);
}

/**
 * @notice BSC latest-block integration coverage for the two migrated mining factories.
 * @dev Creates and buys a real Basket through the deployed BSC protocol, then uses that
 * Basket in locally deployed NFT Mining and Basket TVL Mining pools on the fork.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork BSC_RPC_URL=<rpc-url> FOUNDRY_ETH_RPC_URL= \
 *     forge test --match-path test/fork/BSCMiningPools.t.sol -vvv
 *
 * The latest block is used by default. Set BSC_FORK_BLOCK only to reproduce historical state.
 */
contract BSCMiningPoolsForkTest is Test, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 internal constant BSC_CHAIN_ID = 56;
    uint256 internal constant LOCK_DURATION = 7 days;
    uint16 internal constant NFT_REWARD_BPS = 500;
    uint24 internal constant V3_FEE = 500;

    address internal constant BSC_COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address internal constant BSC_BASKET_REGISTRY = 0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe;
    address internal constant BSC_BASKET_ROUTER = 0x8749B6073A7c8fE8BB5a3e56AD9fc239E1967244;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    bool internal forkReady;
    address internal liveBasket;
    uint256 internal basketShares;

    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    NFTMiningPoolFactory internal nftFactory;
    BasketTVLMiningPoolFactory internal basketFactory;
    Community internal community;
    NFTMiningPool internal nftPool;
    BasketTVLMiningPool internal basketPool;

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function setUp() external {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }

        assertEq(block.chainid, BSC_CHAIN_ID, "BSC fork chain id mismatch");
        assertGt(BSC_COMMUNITY_FACTORY.code.length, 0, "BSC CommunityFactory missing");
        assertGt(BSC_BASKET_REGISTRY.code.length, 0, "BSC BasketRegistry missing");
        assertGt(BSC_BASKET_ROUTER.code.length, 0, "BSC Basket router missing");
        forkReady = true;

        (liveBasket, basketShares) = _createLiveUsdcBasket();
        _deployMiningPools();
    }

    function testFork_LiveBscDependenciesAndFactoryConfiguration() external onlyBscFork {
        assertEq(nftFactory.communityFactory(), address(communityFactory));
        assertGt(nftFactory.poolTemplate().code.length, 0);
        assertGt(nftFactory.defaultRenderer().code.length, 0);

        assertEq(basketFactory.communityFactory(), address(communityFactory));
        assertEq(basketFactory.basketRegistry(), BSC_BASKET_REGISTRY);
        assertEq(basketFactory.nftMiningPoolFactory(), address(nftFactory));
        assertGt(basketFactory.poolTemplate().code.length, 0);
        assertGt(basketFactory.childPoolTemplate().code.length, 0);
    }

    function testFork_RealBscBasketUsesWbnbAndCompletesStakeLifecycle() external onlyBscFork {
        IBSCBasketRegistry registry = IBSCBasketRegistry(BSC_BASKET_REGISTRY);
        assertTrue(registry.isBasket(liveBasket));
        assertEq(IBSCLiveBasket(liveBasket).creatorPayout(), address(this));
        assertEq(IBSCLiveBasket(liveBasket).wbnb(), WBNB);
        assertEq(IBSCLiveBasket(liveBasket).assetCount(), 1);

        (address asset, uint16 weight, uint256 activeReserve) = IBSCLiveBasket(liveBasket).assetAt(0);
        assertEq(asset, USDC);
        assertEq(weight, 10_000);
        assertGt(activeReserve, 0);
        assertEq(basketPool.basketCommunityTokenBalance(liveBasket), IERC20(USDC).balanceOf(liveBasket));

        address childAddress = basketPool.createBasketStake(liveBasket, 1);
        BasketStakePool child = BasketStakePool(payable(childAddress));
        assertEq(child.stakeToken(), liveBasket);
        assertEq(child.rewardToken(), USDC);
        assertEq(child.holderFeeToken(), WBNB);
        assertEq(child.lockDuration(), LOCK_DURATION);

        uint256 depositAmount = basketShares / 2;
        assertGt(depositAmount, 0);
        IERC20(liveBasket).approve(childAddress, depositAmount);
        child.deposit(depositAmount);
        assertEq(child.getUserStakedAmount(address(this)), depositAmount);

        child.withdraw(depositAmount);
        vm.warp(block.timestamp + LOCK_DURATION);
        uint256 balanceBefore = IERC20(liveBasket).balanceOf(address(this));
        child.redeem();
        assertEq(IERC20(liveBasket).balanceOf(address(this)), balanceBefore + depositAmount);
    }

    function _createLiveUsdcBasket() private returns (address basket, uint256 shares) {
        uint256 countBefore = IBSCBasketRegistry(BSC_BASKET_REGISTRY).basketCount();
        deal(USDT, address(this), 1_000 ether);
        IERC20(USDT).forceApprove(BSC_BASKET_ROUTER, type(uint256).max);

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        IBSCBasketRouter.LegRoute[] memory routes = new IBSCBasketRouter.LegRoute[](1);
        routes[0] = IBSCBasketRouter.LegRoute({venue: IBSCBasketRouter.Venue.V3, v4Pool: _emptyPool(), v3Fee: V3_FEE});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        IBSCBasketRouter.CreateParams memory params = IBSCBasketRouter.CreateParams({
            name: "TagAI BSC Mining Fork Basket",
            symbol: "tbmBSC",
            creator: address(this),
            basketFeeBps: 200,
            creatorShareBps: 2_000,
            constituentAssets: assets,
            constituentRoutes: routes,
            targetWeights: weights
        });

        uint256[] memory legMins = new uint256[](1);
        legMins[0] = 1;
        IBSCBasketRouter.TradeData memory tradeData = IBSCBasketRouter.TradeData({
            frontend: address(0),
            minBasketOut: 0,
            minSettlementOut: 0,
            legMins: legMins,
            legSqrtPriceLimitsX96: new uint160[](0),
            hubSqrtPriceLimitX96: 0,
            allowFailedLegs: new bool[](1)
        });

        (basket, shares) = IBSCBasketRouter(BSC_BASKET_ROUTER)
            .createAndBuyExactSettlement(
                keccak256(abi.encode(block.number, address(this))),
                params,
                100 ether,
                1,
                abi.encode(tradeData),
                address(this)
            );
        assertEq(IBSCBasketRegistry(BSC_BASKET_REGISTRY).basketCount(), countBefore + 1);
        assertGt(shares, 0);
    }

    function _deployMiningPools() private {
        committee = new Committee(payable(address(this)));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        nftFactory = new NFTMiningPoolFactory(address(communityFactory));
        basketFactory =
            new BasketTVLMiningPoolFactory(address(communityFactory), BSC_BASKET_REGISTRY, address(nftFactory));

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(nftFactory));
        committee.adminAddContract(address(basketFactory));

        community = Community(
            payable(communityFactory.createCommunity(
                    false, USDC, address(0), bytes(""), address(calculator), bytes("")
                ))
        );

        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        NFTMiningPoolFactory.PoolConfig memory nftConfig = NFTMiningPoolFactory.PoolConfig({
            symbol: "BSCNFT",
            fundsReceiver: address(this),
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            firstPaymentAsset: address(0),
            firstMintPrice: 1,
            firstBatchSupply: 10,
            firstReferralBps: 0
        });

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("BSC NFT Mining", ratios, address(nftFactory), abi.encode(nftConfig));
        nftPool = NFTMiningPool(payable(community.activedPools(0)));

        vm.deal(address(this), 1 ether);
        uint256 nftTokenId = nftPool.mint{value: 1}(0);
        assertEq(nftTokenId, 1);

        ratios = new uint16[](2);
        ratios[0] = 0;
        ratios[1] = 10_000;
        community.adminAddPool(
            "BSC Basket TVL Mining",
            ratios,
            address(basketFactory),
            abi.encode(address(nftPool), NFT_REWARD_BPS, LOCK_DURATION)
        );
        basketPool = BasketTVLMiningPool(community.activedPools(1));
    }

    function _emptyPool() private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0)),
            fee: 0,
            parameters: bytes32(0)
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
