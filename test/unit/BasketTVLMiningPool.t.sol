// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

contract BasketTVLTestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BasketTVLTestNFT is ERC721 {
    uint256 private _nextId;

    constructor() ERC721("Mining Access", "ACCESS") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++_nextId;
        _mint(to, tokenId);
    }
}

contract BasketTVLTestRegistry {
    mapping(address basket => bool valid) public isBasket;

    function setBasket(address basket, bool valid) external {
        isBasket[basket] = valid;
    }
}

contract BasketTVLTestExecutor is IBasketRebalanceExecutor {
    mapping(address asset => uint256 bps) public quoteBps;

    function setQuoteBps(address asset, uint256 bps) external {
        quoteBps[asset] = bps;
    }

    function quoteAssetToWeth(IBasketToken.LegRoute calldata, address asset, uint256 amount)
        external
        view
        returns (uint256)
    {
        return Math.mulDiv(amount, quoteBps[asset], 10_000);
    }
}

contract BasketTVLTestBasket is ERC20 {
    uint256 private constant ACC_PRECISION = 1e24;

    address public immutable creatorPayout;
    address public immutable rebalanceExecutor;
    address public immutable weth;
    address public immutable constituent;

    uint256 public activeReserve;
    uint256 public accHolderFeePerShare;
    mapping(address holder => uint256 checkpoint) private _holderCheckpoint;
    mapping(address holder => uint256 amount) private _accruedHolderFees;
    bool public revertHolderFeeClaim;
    address public reentryTarget;
    bytes public reentryData;
    bool public lastReentrySucceeded;

    constructor(
        string memory name_,
        string memory symbol_,
        address creator_,
        address executor_,
        address weth_,
        address constituent_,
        uint256 reserve_
    ) ERC20(name_, symbol_) {
        creatorPayout = creator_;
        rebalanceExecutor = executor_;
        weth = weth_;
        constituent = constituent_;
        activeReserve = reserve_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setActiveReserve(uint256 reserve) external {
        activeReserve = reserve;
    }

    function setRevertHolderFeeClaim(bool shouldRevert) external {
        revertHolderFeeClaim = shouldRevert;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
        lastReentrySucceeded = false;
    }

    function assetCount() external pure returns (uint256) {
        return 1;
    }

    function assetAt(uint256 index) external view returns (address asset, uint16 targetWeightBps, uint256 reserve) {
        require(index == 0, "OOB");
        return (constituent, 10_000, activeReserve);
    }

    function assetRouteAt(uint256 index) external pure returns (IBasketToken.LegRoute memory route) {
        require(index == 0, "OOB");
        route.venue = IBasketToken.Venue.WETH;
    }

    function injectHolderFees(uint256 amount) external {
        BasketTVLTestERC20(weth).transferFrom(msg.sender, address(this), amount);
        uint256 supply = totalSupply();
        if (supply != 0) accHolderFeePerShare += Math.mulDiv(amount, ACC_PRECISION, supply);
    }

    function claimableHolderFees(address holder) public view returns (uint256) {
        uint256 pending;
        uint256 checkpoint = _holderCheckpoint[holder];
        if (accHolderFeePerShare > checkpoint) {
            pending = Math.mulDiv(balanceOf(holder), accHolderFeePerShare - checkpoint, ACC_PRECISION);
        }
        return _accruedHolderFees[holder] + pending;
    }

    function claimHolderFeesFor(address holder) external returns (uint256 amount) {
        if (revertHolderFeeClaim) revert("HOLDER_FEE_CLAIM_REVERTED");
        if (reentryTarget != address(0)) {
            (lastReentrySucceeded,) = reentryTarget.call(reentryData);
        }
        _settleHolder(holder);
        amount = _accruedHolderFees[holder];
        if (amount == 0) return 0;
        _accruedHolderFees[holder] = 0;
        BasketTVLTestERC20(weth).transfer(holder, amount);
    }

    function _settleHolder(address holder) private {
        uint256 checkpoint = _holderCheckpoint[holder];
        if (accHolderFeePerShare > checkpoint) {
            uint256 balance = balanceOf(holder);
            if (balance != 0) {
                _accruedHolderFees[holder] += Math.mulDiv(balance, accHolderFeePerShare - checkpoint, ACC_PRECISION);
            }
        }
        _holderCheckpoint[holder] = accHolderFeePerShare;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(0)) _settleHolder(from);
        if (to != address(0)) _settleHolder(to);
        super._beforeTokenTransfer(from, to, amount);
    }
}

contract BasketTVLTestMultiAssetBasket is ERC20 {
    address public immutable creatorPayout;
    address public immutable rebalanceExecutor;
    address public immutable weth;

    address[] private _assets;
    uint256[] private _reserves;

    constructor(
        address creator_,
        address executor_,
        address weth_,
        address[] memory assets_,
        uint256[] memory reserves_
    ) ERC20("Multi Asset Basket", "MAB") {
        require(assets_.length == reserves_.length, "LENGTH");
        creatorPayout = creator_;
        rebalanceExecutor = executor_;
        weth = weth_;
        _assets = assets_;
        _reserves = reserves_;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (address, uint16, uint256) {
        return (_assets[index], uint16(10_000 / _assets.length), _reserves[index]);
    }

    function assetRouteAt(uint256 index) external view returns (IBasketToken.LegRoute memory route) {
        _assets[index];
        route.venue = IBasketToken.Venue.WETH;
    }

    function setReserve(uint256 index, uint256 reserve) external {
        _reserves[index] = reserve;
    }

    function claimableHolderFees(address) external pure returns (uint256) {
        return 0;
    }

    function claimHolderFeesFor(address) external pure returns (uint256) {
        return 0;
    }
}

contract BasketTVLInitCommunity {
    address private immutable _rewardToken;

    constructor(address rewardToken_) {
        _rewardToken = rewardToken_;
    }

    function getCommunityToken() external view returns (address) {
        return _rewardToken;
    }
}

contract BasketTVLRejectNative {
    receive() external payable {
        revert("NO_NATIVE");
    }
}

contract BasketTVLMiningPoolTest is Test {
    uint256 internal constant LOCK_DURATION = 7 days;
    uint256 internal constant REWARD_INJECTION = 168_000 ether;
    uint256 internal constant HOURLY_REWARD = 1_000 ether;

    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    Community internal community;
    BasketTVLMiningPoolFactory internal factory;
    BasketTVLMiningPool internal pool;

    BasketTVLTestERC20 internal rewardToken;
    BasketTVLTestERC20 internal weth;
    BasketTVLTestERC20 internal assetA;
    BasketTVLTestERC20 internal assetB;
    BasketTVLTestNFT internal miningNFT;
    BasketTVLTestRegistry internal registry;
    BasketTVLTestExecutor internal executor;
    BasketTVLTestBasket internal basketA;
    BasketTVLTestBasket internal basketB;

    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal feeRecipient = makeAddr("feeRecipient");

    event BasketStakeCreated(address indexed basket, address indexed owner, uint256 miningAmount, uint256 updatedAt);
    event BasketChildPoolCreated(
        address indexed basket, address indexed childPool, address indexed owner, uint256 lockDuration
    );
    event BasketStakeUpdated(
        address indexed basket,
        address indexed owner,
        uint256 previousMiningAmount,
        uint256 newMiningAmount,
        uint256 updatedAt
    );
    event Deposited(address indexed user, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 amount, uint256 startTime, uint256 endTime);
    event Redeemed(address indexed user, uint256 amount);
    event RewardsHarvested(uint256 amount);
    event HolderFeesHarvested(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 communityAmount, uint256 holderFeeAmount);

    function setUp() public {
        vm.warp(3_600);

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        rewardToken = new BasketTVLTestERC20("Community Reward", "RWD");
        weth = new BasketTVLTestERC20("Wrapped Ether", "WETH");
        assetA = new BasketTVLTestERC20("Asset A", "A");
        assetB = new BasketTVLTestERC20("Asset B", "B");
        miningNFT = new BasketTVLTestNFT();
        registry = new BasketTVLTestRegistry();
        executor = new BasketTVLTestExecutor();

        executor.setQuoteBps(address(assetA), 10_000);
        executor.setQuoteBps(address(assetB), 10_000);

        basketA = new BasketTVLTestBasket(
            "Basket A", "BA", ownerA, address(executor), address(weth), address(assetA), 10 ether
        );
        basketB = new BasketTVLTestBasket(
            "Basket B", "BB", ownerB, address(executor), address(weth), address(assetB), 30 ether
        );
        registry.setBasket(address(basketA), true);
        registry.setBasket(address(basketB), true);
        miningNFT.mint(ownerA);
        miningNFT.mint(ownerB);

        factory = new BasketTVLMiningPoolFactory(
            address(communityFactory), address(registry), address(miningNFT), LOCK_DURATION
        );
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(factory));

        address communityAddress = communityFactory.createCommunity(
            false, address(rewardToken), address(0), bytes(""), address(calculator), bytes("")
        );
        community = Community(payable(communityAddress));

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("Basket TVL Mining", ratios, address(factory), bytes(""));
        pool = BasketTVLMiningPool(community.activedPools(0));

        rewardToken.mint(address(this), 10_000_000 ether);
        rewardToken.approve(address(calculator), type(uint256).max);
        weth.mint(address(this), 10_000_000 ether);
        weth.approve(address(basketA), type(uint256).max);
        weth.approve(address(basketB), type(uint256).max);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(keeper, 100 ether);
    }

    function test_FactoryAndParentInitialization() public view {
        assertEq(factory.poolOfCommunity(address(community)), address(pool));
        assertEq(pool.getFactory(), address(factory));
        assertEq(pool.getCommunity(), address(community));
        assertEq(pool.basketRegistry(), address(registry));
        assertEq(pool.nftMiningPool(), address(miningNFT));
        assertEq(pool.childPoolTemplate(), factory.childPoolTemplate());
        assertEq(pool.lockDuration(), LOCK_DURATION);
        assertEq(pool.name(), "Basket TVL Mining");
        assertEq(pool.getTotalStakedAmount(), 0);
    }

    function test_RevertFactoryCreatePoolWhenCallerIsNotCommunity() public {
        vm.expectRevert(bytes("Permission denied: caller is not community"));
        vm.prank(keeper);
        factory.createPool(address(community), "Unauthorized", bytes(""));
    }

    function test_RevertFactoryCreatePoolForUnknownCommunity() public {
        address unknownCommunity = makeAddr("unknownCommunity");
        vm.expectRevert(bytes("Invalid community"));
        vm.prank(unknownCommunity);
        factory.createPool(unknownCommunity, "Unknown", bytes(""));
    }

    function test_RevertFactoryCreatePoolTwiceForSameCommunity() public {
        vm.expectRevert(BasketTVLMiningPoolFactory.PoolAlreadyExists.selector);
        vm.prank(address(community));
        factory.createPool(address(community), "Duplicate", bytes(""));
    }

    function test_ImplementationTemplatesCannotBeInitialized() public {
        address parentTemplate = factory.poolTemplate();
        address childTemplate = factory.childPoolTemplate();

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        BasketTVLMiningPool(parentTemplate)
            .initialize(
                address(community),
                "Hijacked Parent",
                address(registry),
                address(miningNFT),
                childTemplate,
                LOCK_DURATION
            );

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        BasketStakePool(childTemplate).initialize(address(pool), address(community), address(basketA), LOCK_DURATION);
    }

    function test_InitializedClonesCannotBeReinitialized() public {
        BasketStakePool child = _createStake(basketA);
        address childTemplate = factory.childPoolTemplate();

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        pool.initialize(
            address(community), "Hijacked Parent", address(registry), address(miningNFT), childTemplate, LOCK_DURATION
        );

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        child.initialize(address(pool), address(community), address(basketA), LOCK_DURATION);
    }

    function test_ParentInitializeRejectsInvalidConfiguration() public {
        _expectInvalidParentInitialize(
            address(0), address(registry), address(miningNFT), factory.childPoolTemplate(), LOCK_DURATION
        );
        _expectInvalidParentInitialize(
            address(community), address(0), address(miningNFT), factory.childPoolTemplate(), LOCK_DURATION
        );
        _expectInvalidParentInitialize(
            address(community), address(registry), address(0), factory.childPoolTemplate(), LOCK_DURATION
        );
        _expectInvalidParentInitialize(
            address(community), address(registry), address(miningNFT), address(0), LOCK_DURATION
        );
        _expectInvalidParentInitialize(
            address(community), address(registry), address(miningNFT), factory.childPoolTemplate(), 0
        );
    }

    function test_ChildInitializeRejectsInvalidConfigurationAndIdenticalRewardTokens() public {
        _expectInvalidChildInitialize(address(0), address(community), address(basketA), LOCK_DURATION);
        _expectInvalidChildInitialize(address(pool), address(0), address(basketA), LOCK_DURATION);
        _expectInvalidChildInitialize(address(pool), address(community), address(0), LOCK_DURATION);
        _expectInvalidChildInitialize(address(pool), address(community), address(basketA), 0);

        BasketTVLInitCommunity sameTokenCommunity = new BasketTVLInitCommunity(address(weth));
        address childClone = Clones.clone(factory.childPoolTemplate());
        vm.expectRevert(BasketStakePool.InvalidAddress.selector);
        BasketStakePool(childClone)
            .initialize(address(pool), address(sameTokenCommunity), address(basketA), LOCK_DURATION);
    }

    function test_CreateBasketStakeIsPermissionlessAndCreatesConfiguredChild() public {
        vm.prank(keeper);
        address childAddress = pool.createBasketStake(address(basketA));
        BasketStakePool child = BasketStakePool(childAddress);

        IBasketTVLMiningPool.BasketStake memory stake = pool.getBasketStake(address(basketA));
        assertEq(stake.owner, ownerA);
        assertEq(stake.childPool, childAddress);
        assertEq(stake.miningAmount, 10 ether);
        assertTrue(stake.exists);
        assertEq(child.parentMiningPool(), address(pool));
        assertEq(child.community(), address(community));
        assertEq(child.stakeToken(), address(basketA));
        assertEq(child.rewardToken(), address(rewardToken));
        assertEq(child.holderFeeToken(), address(weth));
        assertEq(child.lockDuration(), LOCK_DURATION);
        assertEq(pool.getUserStakedAmount(childAddress), 10 ether);
        assertEq(pool.getUserStakedAmount(ownerA), 0);
        assertEq(pool.getTotalStakedAmount(), 10 ether);
    }

    function test_CreateAndUpdateEmitIndexerCriticalParameters() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit BasketStakeCreated(address(basketA), ownerA, 10 ether, block.timestamp);
        vm.expectEmit(true, false, true, true, address(pool));
        emit BasketChildPoolCreated(address(basketA), address(0), ownerA, LOCK_DURATION);
        pool.createBasketStake(address(basketA));

        basketA.setActiveReserve(25 ether);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BasketStakeUpdated(address(basketA), ownerA, 10 ether, 25 ether, block.timestamp);
        pool.updateBasketStake(address(basketA));
    }

    function test_RevertCreateBasketStakeWhenParentPoolIsClosed() public {
        community.adminClosePool(0, new uint16[](0));

        vm.expectRevert(BasketTVLMiningPool.PoolIsInactive.selector);
        pool.createBasketStake(address(basketA));
    }

    function test_CreateTwoBasketsAggregatesTvlByChildAddress() public {
        BasketStakePool childA = _createStake(basketA);
        BasketStakePool childB = _createStake(basketB);

        assertEq(pool.getUserStakedAmount(address(childA)), 10 ether);
        assertEq(pool.getUserStakedAmount(address(childB)), 30 ether);
        assertEq(pool.getTotalStakedAmount(), 40 ether);
    }

    function test_RevertCreateForUnregisteredBasket() public {
        BasketTVLTestBasket invalidBasket = _newBasket(makeAddr("invalidOwner"), 1 ether);
        vm.expectRevert(BasketTVLMiningPool.InvalidBasket.selector);
        pool.createBasketStake(address(invalidBasket));
    }

    function test_RevertCreateWhenBasketOwnerHasNoNFT() public {
        address ownerWithoutNFT = makeAddr("ownerWithoutNFT");
        BasketTVLTestBasket noNFTBasket = _newBasket(ownerWithoutNFT, 1 ether);
        registry.setBasket(address(noNFTBasket), true);

        vm.expectRevert(BasketTVLMiningPool.OwnerHasNoMiningNFT.selector);
        pool.createBasketStake(address(noNFTBasket));
    }

    function test_RevertDuplicateBasketStake() public {
        _createStake(basketA);
        vm.expectRevert(BasketTVLMiningPool.BasketStakeAlreadyExists.selector);
        pool.createBasketStake(address(basketA));
    }

    function test_RevertUpdateUnknownBasket() public {
        vm.expectRevert(BasketTVLMiningPool.BasketStakeNotFound.selector);
        pool.updateBasketStake(address(basketA));
    }

    function test_UpdateBasketStakeRefreshesNavPermissionlessly() public {
        BasketStakePool child = _createStake(basketA);
        basketA.setActiveReserve(25 ether);

        vm.prank(keeper);
        pool.updateBasketStake(address(basketA));

        assertEq(pool.getBasketStake(address(basketA)).miningAmount, 25 ether);
        assertEq(pool.getUserStakedAmount(address(child)), 25 ether);
        assertEq(pool.getTotalStakedAmount(), 25 ether);
    }

    function test_MultiAssetNavSumsNonOneToOneQuotes() public {
        executor.setQuoteBps(address(assetA), 5_000);
        executor.setQuoteBps(address(assetB), 20_000);
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory reserves = new uint256[](2);
        reserves[0] = 10 ether;
        reserves[1] = 20 ether;
        BasketTVLTestMultiAssetBasket basket =
            new BasketTVLTestMultiAssetBasket(ownerA, address(executor), address(weth), assets, reserves);
        registry.setBasket(address(basket), true);

        BasketStakePool child = BasketStakePool(pool.createBasketStake(address(basket)));

        assertEq(pool.basketNavWeth(address(basket)), 45 ether);
        assertEq(pool.getBasketStake(address(basket)).miningAmount, 45 ether);
        assertEq(pool.getUserStakedAmount(address(child)), 45 ether);
        assertEq(pool.getTotalStakedAmount(), 45 ether);
    }

    function test_ZeroNavBasketCanRegisterAndLaterUpdateAboveZero() public {
        basketA.setActiveReserve(0);
        BasketStakePool child = _createStake(basketA);

        assertEq(pool.getBasketStake(address(basketA)).miningAmount, 0);
        assertEq(pool.getUserStakedAmount(address(child)), 0);
        assertEq(pool.getTotalStakedAmount(), 0);

        basketA.setActiveReserve(7 ether);
        pool.updateBasketStake(address(basketA));
        assertEq(pool.getUserStakedAmount(address(child)), 7 ether);
        assertEq(pool.getTotalStakedAmount(), 7 ether);
    }

    function test_UpdateBasketNavToZeroRemovesItsMiningWeight() public {
        BasketStakePool childA = _createStake(basketA);
        BasketStakePool childB = _createStake(basketB);
        basketA.setActiveReserve(0);

        pool.updateBasketStake(address(basketA));

        assertEq(pool.getBasketStake(address(basketA)).miningAmount, 0);
        assertEq(pool.getUserStakedAmount(address(childA)), 0);
        assertEq(pool.getUserStakedAmount(address(childB)), 30 ether);
        assertEq(pool.getTotalStakedAmount(), 30 ether);
    }

    function test_CommunitySplitsRewardsAcrossChildrenByBasketTvl() public {
        BasketStakePool childA = _createStake(basketA);
        BasketStakePool childB = _createStake(basketB);
        _mintAndDeposit(basketA, childA, alice, 100 ether);
        _mintAndDeposit(basketB, childB, bob, 100 ether);

        _injectRewardsAndWarp(1 hours);

        (uint256 rewardA,) = _claim(childA, alice);
        (uint256 rewardB,) = _claim(childB, bob);
        assertApproxEqAbs(rewardA, 250 ether, 1e8);
        assertApproxEqAbs(rewardB, 750 ether, 1e8);
        assertApproxEqAbs(rewardA + rewardB, HOURLY_REWARD, 1e8);
    }

    function test_TvlUpdateSettlesOldRatioBeforeUsingNewRatio() public {
        BasketStakePool childA = _createStake(basketA);
        BasketStakePool childB = _createStake(basketB);
        _mintAndDeposit(basketA, childA, alice, 100 ether);
        _mintAndDeposit(basketB, childB, bob, 100 ether);

        _injectRewardsAndWarp(1 hours);
        basketA.setActiveReserve(30 ether);
        pool.updateBasketStake(address(basketA));
        vm.warp(block.timestamp + 1 hours);

        (uint256 rewardA,) = _claim(childA, alice);
        (uint256 rewardB,) = _claim(childB, bob);
        assertApproxEqAbs(rewardA, 750 ether, 1e8);
        assertApproxEqAbs(rewardB, 1_250 ether, 1e8);
        assertApproxEqAbs(rewardA + rewardB, 2 * HOURLY_REWARD, 1e8);
    }

    function test_ChildSplitsCommunityRewardsByActiveStake() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _mintAndDeposit(basketA, child, bob, 300 ether);
        _injectRewardsAndWarp(1 hours);

        (uint256 aliceReward,) = _claim(child, alice);
        (uint256 bobReward,) = _claim(child, bob);
        assertApproxEqAbs(aliceReward, 250 ether, 1e8);
        assertApproxEqAbs(bobReward, 750 ether, 1e8);
    }

    function test_DepositSettlesPastRewardsBeforeAddingNewStake() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _injectRewardsAndWarp(1 hours);
        _mintAndDeposit(basketA, child, bob, 300 ether);
        vm.warp(block.timestamp + 1 hours);

        (uint256 aliceReward,) = _claim(child, alice);
        (uint256 bobReward,) = _claim(child, bob);
        assertApproxEqAbs(aliceReward, 1_250 ether, 1e8);
        assertApproxEqAbs(bobReward, 750 ether, 1e8);
    }

    function test_WithdrawSettlesRewardsBeforeRemovingStake() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _mintAndDeposit(basketA, child, bob, 100 ether);
        _injectRewardsAndWarp(1 hours);

        vm.prank(alice);
        child.withdraw(100 ether);
        vm.warp(block.timestamp + 1 hours);

        (uint256 aliceReward,) = _claim(child, alice);
        (uint256 bobReward,) = _claim(child, bob);
        assertApproxEqAbs(aliceReward, 500 ether, 1e8);
        assertApproxEqAbs(bobReward, 1_500 ether, 1e8);
    }

    function test_HolderFeesAreTransferredAndSplitByActiveStake() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _mintAndDeposit(basketA, child, bob, 300 ether);
        basketA.injectHolderFees(400 ether);

        (, uint256 aliceFees) = _claim(child, alice);
        (, uint256 bobFees) = _claim(child, bob);
        assertApproxEqAbs(aliceFees, 100 ether, 1);
        assertApproxEqAbs(bobFees, 300 ether, 1);
        assertEq(weth.balanceOf(alice), aliceFees);
        assertEq(weth.balanceOf(bob), bobFees);
    }

    function test_NewDepositorCannotCapturePastHolderFees() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        basketA.injectHolderFees(100 ether);
        _mintAndDeposit(basketA, child, bob, 300 ether);

        (, uint256 aliceFees) = _claim(child, alice);
        assertApproxEqAbs(aliceFees, 100 ether, 1);
        assertEq(child.pendingHolderFees(bob), 0);
    }

    function test_ExternalBasketFeeClaimIsStillAccountedByChild() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        basketA.injectHolderFees(100 ether);

        vm.prank(keeper);
        basketA.claimHolderFeesFor(address(child));
        assertEq(weth.balanceOf(address(child)), 100 ether);

        (, uint256 claimedFees) = _claim(child, alice);
        assertApproxEqAbs(claimedFees, 100 ether, 1);
        assertEq(weth.balanceOf(address(child)), 0);
    }

    function test_HolderFeesAccruedWithNoActiveStakeGoToNextDepositor() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        vm.prank(alice);
        child.withdraw(100 ether);
        assertEq(child.getTotalStakedAmount(), 0);

        basketA.injectHolderFees(100 ether);
        _mintAndDeposit(basketA, child, bob, 25 ether);

        assertApproxEqAbs(child.undistributedHolderFees(), 100 ether, 1);
        assertApproxEqAbs(child.pendingHolderFees(bob), 100 ether, 1);
        assertEq(child.pendingHolderFees(alice), 0);

        (, uint256 bobFees) = _claim(child, bob);
        assertApproxEqAbs(bobFees, 100 ether, 1);
    }

    function test_RevertingBasketHolderFeeClaimBlocksDepositWithdrawAndClaim() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        basketA.mint(bob, 10 ether);
        vm.prank(bob);
        basketA.approve(address(child), type(uint256).max);
        basketA.setRevertHolderFeeClaim(true);

        vm.expectRevert(bytes("HOLDER_FEE_CLAIM_REVERTED"));
        vm.prank(bob);
        child.deposit(10 ether);

        vm.expectRevert(bytes("HOLDER_FEE_CLAIM_REVERTED"));
        vm.prank(alice);
        child.withdraw(1 ether);

        vm.expectRevert(bytes("HOLDER_FEE_CLAIM_REVERTED"));
        vm.prank(alice);
        child.claimRewards();

        assertEq(child.getUserStakedAmount(alice), 100 ether);
        assertEq(child.getUserStakedAmount(bob), 0);
        assertEq(child.getTotalStakedAmount(), 100 ether);
    }

    function test_ReentrantBasketCallbackCannotEnterChildAgain() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        basketA.injectHolderFees(20 ether);
        basketA.setReentry(address(child), abi.encodeCall(BasketStakePool.claimRewards, ()));

        (, uint256 holderFees) = _claim(child, alice);

        assertFalse(basketA.lastReentrySucceeded());
        assertApproxEqAbs(holderFees, 20 ether, 1);
        assertEq(child.pendingHolderFees(alice), 0);
        assertEq(weth.balanceOf(alice), holderFees);
    }

    function test_ClaimPaysCommunityAndHolderRewardsTogether() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        basketA.injectHolderFees(80 ether);
        _injectRewardsAndWarp(1 hours);

        (uint256 communityAmount, uint256 holderFeeAmount) = _claim(child, alice);
        assertApproxEqAbs(communityAmount, HOURLY_REWARD, 1e8);
        assertApproxEqAbs(holderFeeAmount, 80 ether, 1);
        assertEq(rewardToken.balanceOf(alice), communityAmount);
        assertEq(weth.balanceOf(alice), holderFeeAmount);
        assertEq(child.pendingRewards(alice), 0);
        assertEq(child.pendingHolderFees(alice), 0);
    }

    function test_RevertClaimWhenBothRewardStreamsAreEmpty() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);

        vm.expectRevert(BasketStakePool.NothingToClaim.selector);
        vm.prank(alice);
        child.claimRewards();
    }

    function test_RewardsAccruedBeforeFirstDepositBecomeUndistributed() public {
        BasketStakePool child = _createStake(basketA);
        _injectRewardsAndWarp(1 hours);
        _mintAndDeposit(basketA, child, alice, 100 ether);

        assertApproxEqAbs(child.undistributedRewards(), HOURLY_REWARD, 1e8);
        assertApproxEqAbs(child.pendingRewards(alice), HOURLY_REWARD, 1e8);

        (uint256 claimed,) = _claim(child, alice);
        assertApproxEqAbs(claimed, HOURLY_REWARD, 1e8);
    }

    function test_ChildRejectsZeroAndExcessAmountsAndEmptyRedeem() public {
        BasketStakePool child = _createStake(basketA);

        vm.expectRevert(BasketStakePool.InvalidAmount.selector);
        vm.prank(alice);
        child.deposit(0);

        _mintAndDeposit(basketA, child, alice, 10 ether);

        vm.expectRevert(BasketStakePool.InvalidAmount.selector);
        vm.prank(alice);
        child.withdraw(0);

        vm.expectRevert(BasketStakePool.InvalidAmount.selector);
        vm.prank(alice);
        child.withdraw(10 ether + 1);

        vm.expectRevert(BasketStakePool.NothingToRedeem.selector);
        vm.prank(alice);
        child.redeem();
    }

    function test_ChildLifecycleAndRewardEventsContainExactAmounts() public {
        BasketStakePool child = _createStake(basketA);
        basketA.mint(alice, 100 ether);
        vm.prank(alice);
        basketA.approve(address(child), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(child));
        emit Deposited(alice, 100 ether);
        vm.prank(alice);
        child.deposit(100 ether);

        basketA.injectHolderFees(50 ether);
        vm.expectEmit(false, false, false, true, address(child));
        emit RewardsHarvested(0);
        vm.expectEmit(false, false, false, true, address(child));
        emit HolderFeesHarvested(50 ether);
        vm.expectEmit(true, false, false, true, address(child));
        emit RewardsClaimed(alice, 0, 50 ether);
        vm.prank(alice);
        child.claimRewards();

        vm.expectEmit(true, false, false, true, address(child));
        emit WithdrawRequested(alice, 100 ether, block.timestamp, block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        child.withdraw(100 ether);

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.expectEmit(true, false, false, true, address(child));
        emit Redeemed(alice, 100 ether);
        vm.prank(alice);
        child.redeem();
    }

    function test_WithdrawUsesLinearTimeLockedRedeemQueue() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        uint256 balanceBefore = basketA.balanceOf(alice);

        vm.prank(alice);
        child.withdraw(100 ether);
        assertEq(child.getUserStakedAmount(alice), 0);
        assertEq(child.getTotalStakedAmount(), 0);
        assertEq(basketA.balanceOf(alice), balanceBefore);
        assertEq(child.redeemRequestCount(alice), 1);

        vm.warp(block.timestamp + LOCK_DURATION / 2);
        assertEq(child.claimableAmount(alice), 50 ether);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), balanceBefore + 50 ether);

        vm.warp(block.timestamp + LOCK_DURATION / 2);
        assertEq(child.claimableAmount(alice), 50 ether);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), balanceBefore + 100 ether);
        assertEq(child.redeemRequestCount(alice), 0);
    }

    function test_RedeemMultipleRequestsAdvancesFifoIndexWithoutDoubleClaim() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        uint256 initialBalance = basketA.balanceOf(alice);

        vm.prank(alice);
        child.withdraw(40 ether);
        vm.warp(block.timestamp + LOCK_DURATION / 4);
        vm.prank(alice);
        child.withdraw(60 ether);

        vm.warp(block.timestamp + LOCK_DURATION / 4);
        assertEq(child.claimableAmount(alice), 35 ether);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), initialBalance + 35 ether);
        assertEq(child.redeemRequestCount(alice), 2);

        IBasketStakePool.RedeemRequest[] memory requests = child.redeemRequests(alice);
        assertEq(requests.length, 2);
        assertEq(requests[0].tokenAmount, 40 ether);
        assertEq(requests[0].claimed, 20 ether);
        assertEq(requests[1].tokenAmount, 60 ether);
        assertEq(requests[1].claimed, 15 ether);

        vm.warp(block.timestamp + LOCK_DURATION / 2);
        assertEq(child.claimableAmount(alice), 50 ether);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), initialBalance + 85 ether);
        assertEq(child.redeemRequestCount(alice), 1);

        requests = child.redeemRequests(alice);
        assertEq(requests.length, 1);
        assertEq(requests[0].tokenAmount, 60 ether);
        assertEq(requests[0].claimed, 45 ether);

        vm.warp(block.timestamp + LOCK_DURATION / 4);
        assertEq(child.claimableAmount(alice), 15 ether);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), initialBalance + 100 ether);
        assertEq(child.redeemRequestCount(alice), 0);

        vm.expectRevert(BasketStakePool.NothingToRedeem.selector);
        vm.prank(alice);
        child.redeem();
        assertEq(basketA.balanceOf(alice), initialBalance + 100 ether);
    }

    function test_QueuedTokensHolderFeesGoToRemainingActiveStakers() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _mintAndDeposit(basketA, child, bob, 100 ether);

        vm.prank(alice);
        child.withdraw(100 ether);
        basketA.injectHolderFees(200 ether);

        (, uint256 bobFees) = _claim(child, bob);
        assertApproxEqAbs(bobFees, 200 ether, 1);
        assertEq(child.pendingHolderFees(alice), 0);
    }

    function test_CommunityOperationFeeIsForwardedOnlyWhenRewardsArePending() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        uint256 operationFee = 0.01 ether;
        committee.adminSetPoolOperationFee(operationFee);
        _injectRewardsAndWarp(1 hours);

        vm.expectRevert(BasketStakePool.InvalidAmount.selector);
        vm.prank(alice);
        child.claimRewards();

        uint256 recipientBefore = feeRecipient.balance;
        vm.prank(alice);
        child.claimRewards{value: operationFee}();
        assertEq(feeRecipient.balance - recipientBefore, operationFee);
    }

    function test_ExcessNativeOperationFeeIsRefundedExactly() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        uint256 operationFee = 0.01 ether;
        uint256 supplied = 0.04 ether;
        committee.adminSetPoolOperationFee(operationFee);
        _injectRewardsAndWarp(1 hours);

        uint256 aliceBefore = alice.balance;
        uint256 recipientBefore = feeRecipient.balance;
        vm.prank(alice);
        child.claimRewards{value: supplied}();

        assertEq(aliceBefore - alice.balance, operationFee);
        assertEq(feeRecipient.balance - recipientBefore, operationFee);
        assertEq(address(child).balance, 0);
    }

    function test_RevertAndRollbackWhenNativeRefundReceiverRejects() public {
        BasketStakePool child = _createStake(basketA);
        BasketTVLRejectNative rejector = new BasketTVLRejectNative();
        basketA.mint(address(rejector), 100 ether);
        vm.startPrank(address(rejector));
        basketA.approve(address(child), type(uint256).max);
        child.deposit(100 ether);
        vm.stopPrank();
        vm.deal(address(rejector), 1 ether);

        uint256 operationFee = 0.01 ether;
        committee.adminSetPoolOperationFee(operationFee);
        _injectRewardsAndWarp(1 hours);
        uint256 recipientBefore = feeRecipient.balance;
        uint256 rejectorBefore = address(rejector).balance;

        vm.expectRevert(BasketStakePool.NativeTransferFailed.selector);
        vm.prank(address(rejector));
        child.claimRewards{value: operationFee + 1 wei}();

        assertEq(feeRecipient.balance, recipientBefore);
        assertEq(address(rejector).balance, rejectorBefore);
        assertEq(rewardToken.balanceOf(address(rejector)), 0);
        assertApproxEqAbs(child.pendingRewards(address(rejector)), HOURLY_REWARD, 1e8);
    }

    function test_DepositRevertsAfterParentPoolIsClosed() public {
        BasketStakePool child = _createStake(basketA);
        basketA.mint(alice, 100 ether);
        vm.prank(alice);
        basketA.approve(address(child), type(uint256).max);

        community.adminClosePool(0, new uint16[](0));
        vm.expectRevert(BasketStakePool.PoolIsInactive.selector);
        vm.prank(alice);
        child.deposit(100 ether);
    }

    function test_ClosedParentAllowsOneFinalHistoricalRewardHarvest() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        _injectRewardsAndWarp(1 hours);

        community.adminClosePool(0, new uint16[](0));
        uint256 operationFee = 0.01 ether;
        committee.adminSetPoolOperationFee(operationFee);

        vm.prank(alice);
        (uint256 communityAmount, uint256 holderFeeAmount) = child.claimRewards{value: operationFee}();
        assertApproxEqAbs(communityAmount, HOURLY_REWARD, 1e8);
        assertEq(holderFeeAmount, 0);
        assertTrue(child.closedParentRewardsHarvested());

        vm.warp(block.timestamp + 1 hours);
        basketA.injectHolderFees(10 ether);

        vm.prank(alice);
        (communityAmount, holderFeeAmount) = child.claimRewards();
        assertEq(communityAmount, 0);
        assertApproxEqAbs(holderFeeAmount, 10 ether, 1);
        assertEq(child.pendingRewards(alice), 0);
    }

    function test_ClosedParentWithoutHistoricalRewardsIsFinalizedWithoutFee() public {
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, 100 ether);
        community.adminClosePool(0, new uint16[](0));
        committee.adminSetPoolOperationFee(1 ether);

        vm.prank(alice);
        child.withdraw(100 ether);

        assertTrue(child.closedParentRewardsHarvested());
        assertEq(child.getUserStakedAmount(alice), 0);
    }

    function testFuzz_HolderFeesRemainProportional(uint96 aliceAmountRaw, uint96 bobAmountRaw, uint96 feeRaw) public {
        uint256 aliceAmount = bound(uint256(aliceAmountRaw), 1 ether, 1_000_000 ether);
        uint256 bobAmount = bound(uint256(bobAmountRaw), 1 ether, 1_000_000 ether);
        uint256 fee = bound(uint256(feeRaw), 1 ether, 1_000_000 ether);

        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, aliceAmount);
        _mintAndDeposit(basketA, child, bob, bobAmount);
        basketA.injectHolderFees(fee);

        (, uint256 aliceFees) = _claim(child, alice);
        (, uint256 bobFees) = _claim(child, bob);
        uint256 expectedAlice = Math.mulDiv(fee, aliceAmount, aliceAmount + bobAmount);
        uint256 expectedBob = fee - expectedAlice;
        // Basket and child pool each use an acc-per-share division, so a few wei
        // can remain as deterministic rounding dust after both distribution layers.
        assertApproxEqAbs(aliceFees, expectedAlice, 8);
        assertApproxEqAbs(bobFees, expectedBob, 8);
        assertApproxEqAbs(aliceFees + bobFees, fee, 8);
    }

    function testFuzz_CommunityRewardClaimsConserveDistributedAmount(
        uint96 aliceAmountRaw,
        uint96 bobAmountRaw,
        uint96 keeperAmountRaw
    ) public {
        uint256 aliceAmount = bound(uint256(aliceAmountRaw), 1 ether, 1_000_000 ether);
        uint256 bobAmount = bound(uint256(bobAmountRaw), 1 ether, 1_000_000 ether);
        uint256 keeperAmount = bound(uint256(keeperAmountRaw), 1 ether, 1_000_000 ether);
        BasketStakePool child = _createStake(basketA);
        _mintAndDeposit(basketA, child, alice, aliceAmount);
        _mintAndDeposit(basketA, child, bob, bobAmount);
        _mintAndDeposit(basketA, child, keeper, keeperAmount);
        _injectRewardsAndWarp(1 hours);

        (uint256 aliceReward,) = _claim(child, alice);
        (uint256 bobReward,) = _claim(child, bob);
        (uint256 keeperReward,) = _claim(child, keeper);
        uint256 totalClaimed = aliceReward + bobReward + keeperReward;

        assertApproxEqAbs(totalClaimed, HOURLY_REWARD, 16);
        assertEq(rewardToken.balanceOf(alice), aliceReward);
        assertEq(rewardToken.balanceOf(bob), bobReward);
        assertEq(rewardToken.balanceOf(keeper), keeperReward);
        assertLe(rewardToken.balanceOf(address(child)), 16);
    }

    function testFuzz_TotalStakedAlwaysEqualsSumOfUserAmounts(
        uint96 aliceAmountRaw,
        uint96 bobAmountRaw,
        uint96 aliceWithdrawRaw,
        uint96 bobWithdrawRaw,
        uint96 aliceSecondDepositRaw
    ) public {
        uint256 aliceAmount = bound(uint256(aliceAmountRaw), 1, 1_000_000 ether);
        uint256 bobAmount = bound(uint256(bobAmountRaw), 1, 1_000_000 ether);
        uint256 aliceWithdraw = bound(uint256(aliceWithdrawRaw), 1, aliceAmount);
        uint256 bobWithdraw = bound(uint256(bobWithdrawRaw), 1, bobAmount);
        uint256 aliceSecondDeposit = bound(uint256(aliceSecondDepositRaw), 1, 1_000_000 ether);
        BasketStakePool child = _createStake(basketA);

        _mintAndDeposit(basketA, child, alice, aliceAmount);
        _mintAndDeposit(basketA, child, bob, bobAmount);
        _assertChildStakeInvariant(child);

        vm.prank(alice);
        child.withdraw(aliceWithdraw);
        _assertChildStakeInvariant(child);

        vm.prank(bob);
        child.withdraw(bobWithdraw);
        _assertChildStakeInvariant(child);

        _mintAndDeposit(basketA, child, alice, aliceSecondDeposit);
        _assertChildStakeInvariant(child);
    }

    function _createStake(BasketTVLTestBasket basket) internal returns (BasketStakePool child) {
        address childAddress = pool.createBasketStake(address(basket));
        child = BasketStakePool(childAddress);
    }

    function _mintAndDeposit(BasketTVLTestBasket basket, BasketStakePool child, address user, uint256 amount) internal {
        basket.mint(user, amount);
        vm.startPrank(user);
        basket.approve(address(child), type(uint256).max);
        child.deposit(amount);
        vm.stopPrank();
    }

    function _injectRewardsAndWarp(uint256 elapsed) internal {
        calculator.inject(address(community), REWARD_INJECTION);
        vm.warp(block.timestamp + elapsed);
    }

    function _claim(BasketStakePool child, address user)
        internal
        returns (uint256 communityAmount, uint256 holderFeeAmount)
    {
        vm.prank(user);
        return child.claimRewards();
    }

    function _newBasket(address owner, uint256 reserve) internal returns (BasketTVLTestBasket basket) {
        basket = new BasketTVLTestBasket(
            "Extra Basket", "XB", owner, address(executor), address(weth), address(assetA), reserve
        );
    }

    function _expectInvalidParentInitialize(
        address community_,
        address registry_,
        address nft_,
        address childTemplate_,
        uint256 lockDuration_
    ) internal {
        address parentClone = Clones.clone(factory.poolTemplate());
        vm.expectRevert(BasketTVLMiningPool.InvalidAddress.selector);
        BasketTVLMiningPool(parentClone)
            .initialize(community_, "Invalid", registry_, nft_, childTemplate_, lockDuration_);
    }

    function _expectInvalidChildInitialize(
        address parent_,
        address community_,
        address stakeToken_,
        uint256 lockDuration_
    ) internal {
        address childClone = Clones.clone(factory.childPoolTemplate());
        vm.expectRevert(BasketStakePool.InvalidAddress.selector);
        BasketStakePool(childClone).initialize(parent_, community_, stakeToken_, lockDuration_);
    }

    function _assertChildStakeInvariant(BasketStakePool child) internal view {
        uint256 userSum =
            child.getUserStakedAmount(alice) + child.getUserStakedAmount(bob) + child.getUserStakedAmount(keeper);
        assertEq(child.getTotalStakedAmount(), userSum);
    }
}
