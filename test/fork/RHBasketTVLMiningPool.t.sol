// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../src/interfaces/IBasketRebalanceExecutor.sol";
import "../../src/interfaces/IBasketTVLMiningPool.sol";
import "../../src/interfaces/IBasketToken.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/basket-tvl-mining/BasketStakePool.sol";
import "../../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPool.sol";
import "../../src/nutbox/dapps/basket-tvl-mining/BasketTVLMiningPoolFactory.sol";

interface IRHLiveBasketRegistry {
    function isBasket(address basket) external view returns (bool);
    function basketCount() external view returns (uint256);
}

interface IRHLiveBasketToken is IBasketToken {
    struct AssetAmount {
        address asset;
        uint256 amount;
    }

    function engine() external view returns (address);
    function quoteProportionalDeposit(uint256 sharesOut) external view returns (AssetAmount[] memory requirements);
    function engineMintFromAcquired(
        address recipient,
        AssetAmount[] calldata deposits,
        uint256 bootstrapShares,
        uint256 feeWeth,
        address frontend
    ) external returns (uint256 sharesOut);
}

contract RHForkRewardToken is ERC20 {
    constructor() ERC20("Fork Community Reward", "FORK-RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RHForkMiningNFT is ERC721 {
    uint256 private _nextId;

    constructor() ERC721("Fork Mining Access", "FORK-NFT") {}

    function mint(address to) external {
        _mint(to, ++_nextId);
    }

    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }
}

/**
 * @notice Integration coverage for Basket TVL mining against RH mainnet state.
 *
 * Deployment constants are sourced from:
 * ../robinhood-basket-contract/deployments/4663/addresses.json
 *
 * Run with:
 * RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_PROFILE=rh_fork forge test \
 *   --match-path test/fork/RHBasketTVLMiningPool.t.sol -vvv
 */
contract RHBasketTVLMiningPoolForkTest is Test {
    using Math for uint256;

    uint256 internal constant RH_CHAIN_ID = 4663;
    uint256 internal constant VERIFIED_FORK_BLOCK = 20_676_768;
    uint256 internal constant LOCK_DURATION = 7 days;
    uint256 internal constant REWARD_INJECTION = 168_000 ether;
    uint256 internal constant ONE_HOUR_REWARD = 1_000 ether;
    uint16 internal constant NFT_REWARD_BPS = 500;
    uint256 internal constant NFT_A = 1;
    uint256 internal constant NFT_B = 2;

    address internal constant RH_BASKET_REGISTRY = 0x1f997dEb6C8Ac7Bb4134Bc7c6bF23F623Cda25C6;
    address internal constant RH_REBALANCE_EXECUTOR = 0x773c71be8b5E3c0c49d9576211d06E2f316AaF4a;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address internal constant LIVE_BASKET_A = 0x9b5d2707bdFf85d6b721802F50D6A82581201E03;
    address internal constant LIVE_BASKET_B = 0xFC0Ae4cb07E0A237b87e637f414541d526dAC237;

    bool internal forkReady;

    RHForkRewardToken internal rewardToken;
    RHForkMiningNFT internal miningNFT;
    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    Community internal community;
    BasketTVLMiningPoolFactory internal factory;
    BasketTVLMiningPool internal pool;

    address internal keeper;
    address internal feeRecipient;

    modifier onlyRhFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        // Pin the known-good live snapshot by default so holder balances and TWAP
        // observations cannot make CI nondeterministic. Override to validate newer state.
        uint256 forkBlock = vm.envOr("RH_FORK_BLOCK", VERIFIED_FORK_BLOCK);
        vm.createSelectFork(rpc, forkBlock);
        if (block.chainid != RH_CHAIN_ID || RH_BASKET_REGISTRY.code.length == 0) return;
        forkReady = true;

        keeper = makeAddr("rhForkKeeper");
        feeRecipient = makeAddr("rhForkFeeRecipient");

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        rewardToken = new RHForkRewardToken();
        miningNFT = new RHForkMiningNFT();

        // The eligibility NFT is local because the NFT mining contract is independent
        // from Basket. The Basket, Registry, Executor, routes, reserves and WETH are live.
        miningNFT.mint(IBasketToken(LIVE_BASKET_A).creatorPayout());
        miningNFT.mint(IBasketToken(LIVE_BASKET_B).creatorPayout());

        factory = new BasketTVLMiningPoolFactory(
            address(communityFactory), RH_BASKET_REGISTRY, address(miningNFT), LOCK_DURATION
        );
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        community = Community(
            payable(communityFactory.createCommunity(
                    false, address(rewardToken), address(0), bytes(""), address(calculator), bytes("")
                ))
        );

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("RH Live Basket TVL Mining", ratios, address(factory), abi.encode(NFT_REWARD_BPS));
        pool = BasketTVLMiningPool(community.activedPools(0));
    }

    function testFork_ManifestContractsAndProvidedBasketsMatchLiveState() public onlyRhFork {
        IRHLiveBasketRegistry registry = IRHLiveBasketRegistry(RH_BASKET_REGISTRY);

        assertEq(block.chainid, RH_CHAIN_ID);
        assertGt(RH_BASKET_REGISTRY.code.length, 0);
        assertGt(RH_REBALANCE_EXECUTOR.code.length, 0);
        assertGt(RH_WETH.code.length, 0);
        assertGe(registry.basketCount(), 2);

        _assertLiveBasketConfiguration(registry, LIVE_BASKET_A);
        _assertLiveBasketConfiguration(registry, LIVE_BASKET_B);
    }

    function testFork_ParentNavMatchesRealExecutorForEveryConstituent() public onlyRhFork {
        uint256 navA = _assertNavMatchesManualLiveQuote(LIVE_BASKET_A);
        uint256 navB = _assertNavMatchesManualLiveQuote(LIVE_BASKET_B);

        assertGt(navA, 0, "live Basket A must have non-zero NAV");
        assertGt(navB, 0, "live Basket B must have non-zero NAV");
    }

    function testFork_CreateBothStakesUsesLiveNavAndConfiguresChildren() public onlyRhFork {
        uint256 expectedNavA = pool.basketNavWeth(LIVE_BASKET_A);
        uint256 expectedNavB = pool.basketNavWeth(LIVE_BASKET_B);

        BasketStakePool childA = _createLiveStake(LIVE_BASKET_A);
        BasketStakePool childB = _createLiveStake(LIVE_BASKET_B);

        _assertCreatedStake(LIVE_BASKET_A, childA, expectedNavA);
        _assertCreatedStake(LIVE_BASKET_B, childB, expectedNavB);
        assertEq(pool.getTotalStakedAmount(), expectedNavA + expectedNavB);
    }

    function testFork_PermissionlessUpdateRequotesAllLiveAssets() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_A);

        vm.prank(keeper);
        pool.updateBasketStake(LIVE_BASKET_A);

        uint256 currentLiveNav = _manualLiveNav(LIVE_BASKET_A);
        IBasketTVLMiningPool.BasketStake memory stake = pool.getBasketStake(LIVE_BASKET_A);
        assertEq(stake.miningAmount, currentLiveNav);
        assertEq(pool.getUserStakedAmount(address(child)), currentLiveNav);
        assertEq(pool.getTotalStakedAmount(), currentLiveNav);
    }

    function testFork_RealBasketHolderCanDepositWithdrawAndRedeem() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address liveHolder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        uint256 liveBalance = IERC20(LIVE_BASKET_B).balanceOf(liveHolder);
        assertGt(liveBalance, 1, "configured live creator no longer holds Basket B");

        uint256 depositAmount = liveBalance / 2;
        vm.startPrank(liveHolder);
        IERC20(LIVE_BASKET_B).approve(address(child), depositAmount);
        child.deposit(depositAmount);
        vm.stopPrank();

        assertEq(child.getUserStakedAmount(liveHolder), depositAmount);
        assertEq(child.getTotalStakedAmount(), depositAmount);
        assertEq(IERC20(LIVE_BASKET_B).balanceOf(address(child)), depositAmount);

        uint256 withdrawAmount = depositAmount / 2;
        vm.prank(liveHolder);
        child.withdraw(withdrawAmount);

        assertEq(child.getUserStakedAmount(liveHolder), depositAmount - withdrawAmount);
        assertEq(child.redeemRequestCount(liveHolder), 1);
        assertEq(child.claimableAmount(liveHolder), 0);

        vm.warp(block.timestamp + LOCK_DURATION);
        uint256 beforeRedeem = IERC20(LIVE_BASKET_B).balanceOf(liveHolder);
        vm.prank(liveHolder);
        child.redeem();

        assertEq(IERC20(LIVE_BASKET_B).balanceOf(liveHolder), beforeRedeem + withdrawAmount);
        assertEq(child.redeemRequestCount(liveHolder), 0);
        assertEq(IERC20(LIVE_BASKET_B).balanceOf(address(child)), depositAmount - withdrawAmount);
    }

    function testFork_RejectsInvalidAndDuplicateLiveBasketRegistration() public onlyRhFork {
        vm.expectRevert(BasketTVLMiningPool.InvalidBasket.selector);
        pool.createBasketStake(makeAddr("notARegisteredBasket"), NFT_A);

        _createLiveStake(LIVE_BASKET_A);
        vm.expectRevert(BasketTVLMiningPool.BasketStakeAlreadyExists.selector);
        pool.createBasketStake(LIVE_BASKET_A, NFT_A);
    }

    function testFork_RealBasketOwnerMustStillHoldEligibilityNft() public onlyRhFork {
        miningNFT.burn(1);
        assertEq(miningNFT.balanceOf(IBasketToken(LIVE_BASKET_A).creatorPayout()), 0);

        vm.expectRevert(BasketTVLMiningPool.OwnerDoesNotOwnMiningNFT.selector);
        vm.prank(IBasketToken(LIVE_BASKET_A).creatorPayout());
        pool.createBasketStake(LIVE_BASKET_A, NFT_A);
    }

    function testFork_ClosedParentBlocksNewBasketAndChildDeposits() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_A);
        address holder = IBasketToken(LIVE_BASKET_A).creatorPayout();
        uint256 amount = IERC20(LIVE_BASKET_A).balanceOf(holder) / 10;
        assertGt(amount, 0);

        community.adminClosePool(0, new uint16[](0));

        vm.expectRevert(BasketTVLMiningPool.PoolIsInactive.selector);
        pool.createBasketStake(LIVE_BASKET_B, NFT_B);

        vm.expectRevert(BasketStakePool.PoolIsInactive.selector);
        vm.prank(holder);
        child.deposit(amount);
    }

    function testFork_TwoRealBasketHoldersSplitCommunityRewardsByStake() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address sourceHolder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        address alice = makeAddr("rhForkAlice");
        address bob = makeAddr("rhForkBob");
        uint256 sourceBalance = IERC20(LIVE_BASKET_B).balanceOf(sourceHolder);
        uint256 aliceAmount = sourceBalance / 5;
        uint256 bobAmount = sourceBalance * 2 / 5;
        assertGt(aliceAmount, 0);

        vm.startPrank(sourceHolder);
        IERC20(LIVE_BASKET_B).transfer(alice, aliceAmount);
        IERC20(LIVE_BASKET_B).transfer(bob, bobAmount);
        vm.stopPrank();
        _deposit(child, LIVE_BASKET_B, alice, aliceAmount);
        _deposit(child, LIVE_BASKET_B, bob, bobAmount);

        _injectRewardsAndWarpOneHour();

        vm.prank(alice);
        (uint256 aliceReward, uint256 aliceHolderFee) = child.claimRewards();
        vm.prank(bob);
        (uint256 bobReward, uint256 bobHolderFee) = child.claimRewards();

        uint256 stakerReward = _stakerShare(ONE_HOUR_REWARD);
        uint256 expectedAlice = Math.mulDiv(stakerReward, aliceAmount, aliceAmount + bobAmount);
        uint256 expectedBob = stakerReward - expectedAlice;
        assertApproxEqAbs(aliceReward, expectedAlice, 1e8);
        assertApproxEqAbs(bobReward, expectedBob, 1e8);
        assertApproxEqAbs(aliceReward + bobReward, stakerReward, 1e8);
        assertEq(aliceHolderFee, 0);
        assertEq(bobHolderFee, 0);
    }

    function testFork_CommunityRewardsSplitAcrossBothLiveBasketNavs() public onlyRhFork {
        BasketStakePool childA = _createLiveStake(LIVE_BASKET_A);
        BasketStakePool childB = _createLiveStake(LIVE_BASKET_B);
        address holderA = IBasketToken(LIVE_BASKET_A).creatorPayout();
        address holderB = IBasketToken(LIVE_BASKET_B).creatorPayout();

        _deposit(childA, LIVE_BASKET_A, holderA, IERC20(LIVE_BASKET_A).balanceOf(holderA) / 2);
        _deposit(childB, LIVE_BASKET_B, holderB, IERC20(LIVE_BASKET_B).balanceOf(holderB) / 2);
        _injectRewardsAndWarpOneHour();

        vm.prank(holderA);
        (uint256 rewardA,) = childA.claimRewards();
        vm.prank(holderB);
        (uint256 rewardB,) = childB.claimRewards();

        uint256 navA = pool.getBasketStake(LIVE_BASKET_A).miningAmount;
        uint256 navB = pool.getBasketStake(LIVE_BASKET_B).miningAmount;
        uint256 parentRewardA = Math.mulDiv(ONE_HOUR_REWARD, navA, navA + navB);
        uint256 parentRewardB = ONE_HOUR_REWARD - parentRewardA;
        uint256 expectedA = _stakerShare(parentRewardA);
        uint256 expectedB = _stakerShare(parentRewardB);
        assertApproxEqAbs(rewardA, expectedA, 1e8);
        assertApproxEqAbs(rewardB, expectedB, 1e8);
        assertApproxEqAbs(rewardA + rewardB, expectedA + expectedB, 1e8);
    }

    function testFork_RealBasketSupportsMultipleLinearFifoRedeems() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address holder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        uint256 depositAmount = IERC20(LIVE_BASKET_B).balanceOf(holder) / 2;
        _deposit(child, LIVE_BASKET_B, holder, depositAmount);

        uint256 first = depositAmount * 2 / 5;
        uint256 second = depositAmount - first;
        vm.prank(holder);
        child.withdraw(first);
        vm.warp(block.timestamp + LOCK_DURATION / 4);
        vm.prank(holder);
        child.withdraw(second);

        vm.warp(block.timestamp + LOCK_DURATION / 4);
        uint256 firstClaim = first / 2 + second / 4;
        assertApproxEqAbs(child.claimableAmount(holder), firstClaim, 2);
        vm.prank(holder);
        child.redeem();
        assertEq(child.redeemRequestCount(holder), 2);

        vm.warp(block.timestamp + LOCK_DURATION / 2);
        uint256 beforeSecondRedeem = IERC20(LIVE_BASKET_B).balanceOf(holder);
        uint256 secondClaimable = child.claimableAmount(holder);
        vm.prank(holder);
        child.redeem();

        assertEq(IERC20(LIVE_BASKET_B).balanceOf(holder), beforeSecondRedeem + secondClaimable);
        assertEq(child.redeemRequestCount(holder), 1);

        vm.warp(block.timestamp + LOCK_DURATION / 4);
        uint256 beforeFinalRedeem = IERC20(LIVE_BASKET_B).balanceOf(holder);
        uint256 finalClaimable = child.claimableAmount(holder);
        vm.prank(holder);
        child.redeem();

        assertEq(IERC20(LIVE_BASKET_B).balanceOf(holder), beforeFinalRedeem + finalClaimable);
        assertEq(child.redeemRequestCount(holder), 0);
        assertEq(child.getTotalStakedAmount(), 0);
        assertEq(IERC20(LIVE_BASKET_B).balanceOf(address(child)), 0);
    }

    function testFork_RealBasketFeeAccrualExternalClaimAndNavRefresh() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address holder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        uint256 depositAmount = IERC20(LIVE_BASKET_B).balanceOf(holder) / 2;
        _deposit(child, LIVE_BASKET_B, holder, depositAmount);
        uint256 oldNav = pool.getBasketStake(LIVE_BASKET_B).miningAmount;
        _injectRewardsAndWarpOneHour();

        _mintThroughRealBasketEngine(LIVE_BASKET_B, 0.1 ether, 0.05 ether);

        uint256 basketClaimable = IBasketToken(LIVE_BASKET_B).claimableHolderFees(address(child));
        assertGt(basketClaimable, 0, "real Basket did not accrue holder fees");
        uint256 childWethBefore = IERC20(RH_WETH).balanceOf(address(child));

        // Reproduce the production case where an arbitrary third party claims for the pool.
        vm.prank(keeper);
        uint256 externallyClaimed = IBasketToken(LIVE_BASKET_B).claimHolderFeesFor(address(child));
        assertEq(externallyClaimed, basketClaimable);
        assertEq(IERC20(RH_WETH).balanceOf(address(child)) - childWethBefore, basketClaimable);

        vm.prank(holder);
        (uint256 communityReward, uint256 holderFee) = child.claimRewards();
        assertApproxEqAbs(communityReward, _stakerShare(ONE_HOUR_REWARD), 1e8);
        assertApproxEqAbs(holderFee, basketClaimable, 2);
        assertEq(IERC20(RH_WETH).balanceOf(holder), holderFee);

        vm.prank(keeper);
        pool.updateBasketStake(LIVE_BASKET_B);
        uint256 refreshedNav = pool.getBasketStake(LIVE_BASKET_B).miningAmount;
        assertEq(refreshedNav, _manualLiveNav(LIVE_BASKET_B));
        assertGt(refreshedNav, oldNav, "proportional mint should increase live reserves and NAV");
        assertEq(pool.getTotalStakedAmount(), refreshedNav);
    }

    function testFork_RealBasketHolderFeesSplitAcrossTwoStakers() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address sourceHolder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        address alice = makeAddr("rhForkFeeAlice");
        address bob = makeAddr("rhForkFeeBob");
        uint256 sourceBalance = IERC20(LIVE_BASKET_B).balanceOf(sourceHolder);
        uint256 aliceAmount = sourceBalance / 5;
        uint256 bobAmount = sourceBalance * 2 / 5;

        vm.startPrank(sourceHolder);
        IERC20(LIVE_BASKET_B).transfer(alice, aliceAmount);
        IERC20(LIVE_BASKET_B).transfer(bob, bobAmount);
        vm.stopPrank();
        _deposit(child, LIVE_BASKET_B, alice, aliceAmount);
        _deposit(child, LIVE_BASKET_B, bob, bobAmount);

        _mintThroughRealBasketEngine(LIVE_BASKET_B, 0.1 ether, 0.05 ether);
        uint256 totalChildFee = IBasketToken(LIVE_BASKET_B).claimableHolderFees(address(child));
        assertGt(totalChildFee, 0);

        vm.prank(alice);
        (, uint256 aliceFee) = child.claimRewards();
        vm.prank(bob);
        (, uint256 bobFee) = child.claimRewards();

        uint256 expectedAlice = Math.mulDiv(totalChildFee, aliceAmount, aliceAmount + bobAmount);
        uint256 expectedBob = totalChildFee - expectedAlice;
        assertApproxEqAbs(aliceFee, expectedAlice, 4);
        assertApproxEqAbs(bobFee, expectedBob, 4);
        assertApproxEqAbs(aliceFee + bobFee, totalChildFee, 4);
        assertEq(IERC20(RH_WETH).balanceOf(alice), aliceFee);
        assertEq(IERC20(RH_WETH).balanceOf(bob), bobFee);
    }

    function testFork_OperationFeeUnderpaymentAndExcessRefundWithRealBasket() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address holder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        _deposit(child, LIVE_BASKET_B, holder, IERC20(LIVE_BASKET_B).balanceOf(holder) / 2);
        _injectRewardsAndWarpOneHour();

        uint256 operationFee = 0.01 ether;
        uint256 supplied = 0.04 ether;
        committee.adminSetPoolOperationFee(operationFee);
        vm.deal(holder, 1 ether);

        vm.expectRevert(BasketStakePool.InvalidAmount.selector);
        vm.prank(holder);
        child.claimRewards();

        uint256 holderNativeBefore = holder.balance;
        uint256 recipientBefore = feeRecipient.balance;
        vm.prank(holder);
        (uint256 reward,) = child.claimRewards{value: supplied}();

        assertApproxEqAbs(reward, _stakerShare(ONE_HOUR_REWARD), 1e8);
        assertEq(holderNativeBefore - holder.balance, operationFee);
        assertEq(feeRecipient.balance - recipientBefore, operationFee);
        assertEq(address(child).balance, 0);
    }

    function testFork_ClosedParentAllowsExactlyOneFinalRealBasketHarvest() public onlyRhFork {
        BasketStakePool child = _createLiveStake(LIVE_BASKET_B);
        address holder = IBasketToken(LIVE_BASKET_B).creatorPayout();
        _deposit(child, LIVE_BASKET_B, holder, IERC20(LIVE_BASKET_B).balanceOf(holder) / 2);
        _injectRewardsAndWarpOneHour();

        community.adminClosePool(0, new uint16[](0));
        vm.prank(holder);
        (uint256 finalReward,) = child.claimRewards();

        assertApproxEqAbs(finalReward, _stakerShare(ONE_HOUR_REWARD), 1e8);
        assertTrue(child.closedParentRewardsHarvested());
        assertEq(child.pendingRewards(holder), 0);

        vm.expectRevert(BasketStakePool.NothingToClaim.selector);
        vm.prank(holder);
        child.claimRewards();
    }

    function _assertLiveBasketConfiguration(IRHLiveBasketRegistry registry, address basket) internal view {
        assertTrue(registry.isBasket(basket), "provided address is not a registered Basket");
        assertGt(basket.code.length, 0);
        assertEq(IBasketToken(basket).rebalanceExecutor(), RH_REBALANCE_EXECUTOR);
        assertEq(IBasketToken(basket).weth(), RH_WETH);
        assertNotEq(IBasketToken(basket).creatorPayout(), address(0));
        assertGt(IBasketToken(basket).assetCount(), 0);
        assertGt(IERC20(basket).totalSupply(), 0);
    }

    function _assertNavMatchesManualLiveQuote(address basket) internal view returns (uint256 nav) {
        nav = _manualLiveNav(basket);
        assertEq(pool.basketNavWeth(basket), nav);
    }

    function _manualLiveNav(address basket) internal view returns (uint256 nav) {
        IBasketToken token = IBasketToken(basket);
        IBasketRebalanceExecutor executor = IBasketRebalanceExecutor(token.rebalanceExecutor());
        uint256 count = token.assetCount();

        for (uint256 i; i < count; ++i) {
            (address asset,, uint256 activeReserve) = token.assetAt(i);
            nav += executor.quoteAssetToWeth(token.assetRouteAt(i), asset, activeReserve);
        }
    }

    function _assertCreatedStake(address basket, BasketStakePool child, uint256 expectedNav) internal view {
        IBasketTVLMiningPool.BasketStake memory stake = pool.getBasketStake(basket);
        assertTrue(stake.exists);
        assertEq(stake.basketCreator, IBasketToken(basket).creatorPayout());
        assertEq(stake.childPool, address(child));
        assertEq(stake.nftTokenId, basket == LIVE_BASKET_A ? NFT_A : NFT_B);
        assertEq(stake.miningAmount, expectedNav);
        assertEq(child.parentMiningPool(), address(pool));
        assertEq(child.community(), address(community));
        assertEq(child.stakeToken(), basket);
        assertEq(child.rewardToken(), address(rewardToken));
        assertEq(child.holderFeeToken(), RH_WETH);
        assertEq(child.nftMiningPool(), address(miningNFT));
        assertEq(child.nftTokenId(), stake.nftTokenId);
        assertEq(child.nftRewardBps(), NFT_REWARD_BPS);
        assertEq(child.lockDuration(), LOCK_DURATION);
        assertEq(pool.getUserStakedAmount(address(child)), expectedNav);
    }

    function _deposit(BasketStakePool child, address basket, address holder, uint256 amount) internal {
        assertGt(amount, 0);
        vm.startPrank(holder);
        IERC20(basket).approve(address(child), amount);
        child.deposit(amount);
        vm.stopPrank();
    }

    function _createLiveStake(address basket) internal returns (BasketStakePool child) {
        uint256 tokenId = basket == LIVE_BASKET_A ? NFT_A : NFT_B;
        vm.prank(IBasketToken(basket).creatorPayout());
        child = BasketStakePool(pool.createBasketStake(basket, tokenId));
    }

    function _injectRewardsAndWarpOneHour() internal {
        rewardToken.mint(address(this), REWARD_INJECTION);
        rewardToken.approve(address(calculator), REWARD_INJECTION);
        calculator.inject(address(community), REWARD_INJECTION);
        vm.warp(block.timestamp + 1 hours);
    }

    function _stakerShare(uint256 amount) internal pure returns (uint256) {
        return amount - Math.mulDiv(amount, NFT_REWARD_BPS, 10_000);
    }

    function _mintThroughRealBasketEngine(address basket, uint256 sharesOut, uint256 feeWeth) internal {
        IRHLiveBasketToken token = IRHLiveBasketToken(basket);
        IRHLiveBasketToken.AssetAmount[] memory requirements = token.quoteProportionalDeposit(sharesOut);
        address engine = token.engine();

        for (uint256 i; i < requirements.length; ++i) {
            address asset = requirements[i].asset;
            uint256 fundedBalance = IERC20(asset).balanceOf(engine) + requirements[i].amount;
            deal(asset, engine, fundedBalance, false);
            vm.prank(engine);
            IERC20(asset).approve(basket, type(uint256).max);
        }

        deal(RH_WETH, engine, IERC20(RH_WETH).balanceOf(engine) + feeWeth, false);
        vm.prank(engine);
        IERC20(RH_WETH).approve(basket, type(uint256).max);

        vm.prank(engine);
        uint256 minted = token.engineMintFromAcquired(keeper, requirements, 0, feeWeth, address(0));
        assertGt(minted, 0);
    }
}
