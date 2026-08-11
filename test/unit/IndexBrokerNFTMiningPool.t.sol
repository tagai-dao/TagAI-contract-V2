// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/index-broker-nft/NFTMiningPool.sol";
import "../../src/nutbox/dapps/index-broker-nft/NFTMiningPoolFactory.sol";

contract IndexBrokerCommunityToken is ERC20 {
    constructor() ERC20("Community", "COM") {
        _mint(msg.sender, 10_000_000 ether);
    }
}

contract IndexBrokerNFTMiningPoolTest is Test {
    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    NFTMiningPoolFactory internal poolFactory;
    Community internal community;
    NFTMiningPool internal pool;
    IndexBrokerCommunityToken internal communityToken;
    uint256 internal activePoolCount;

    address internal fundsReceiver = makeAddr("fundsReceiver");
    address internal platformTreasury = makeAddr("platformTreasury");
    address internal whitelistUser1 = makeAddr("whitelistUser1");
    address internal whitelistUser2 = makeAddr("whitelistUser2");
    address internal paidUser = makeAddr("paidUser");

    uint256 internal constant COMMUNITY_TOKEN_PRICE = 1_000 ether;
    uint256 internal constant NATIVE_PRICE = 1 ether;
    uint256 internal constant MAX_SUPPLY = 6;
    uint16 internal constant PLATFORM_FEE_BPS = 30;
    uint16 internal constant REFERRAL_BPS = 1_000;
    uint256 internal constant BASE_WEIGHT = 10_000;

    function setUp() public {
        vm.warp(3_600);

        committee = new Committee(payable(platformTreasury));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        poolFactory = new NFTMiningPoolFactory(address(communityFactory));
        communityToken = new IndexBrokerCommunityToken();

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(poolFactory));

        community = Community(
            payable(communityFactory.createCommunity(
                    false, address(communityToken), address(0), bytes(""), address(calculator), bytes("")
                ))
        );

        address[] memory accounts = new address[](2);
        accounts[0] = whitelistUser1;
        accounts[1] = whitelistUser2;
        uint256[] memory allowances = new uint256[](2);
        allowances[0] = 2;
        allowances[1] = 1;

        pool = _addPool(NATIVE_PRICE, MAX_SUPPLY, REFERRAL_BPS, true, accounts, allowances);

        _fundAndApprove(whitelistUser1, pool);
        _fundAndApprove(whitelistUser2, pool);
        _fundAndApprove(paidUser, pool);
    }

    function test_InitializationUsesCommunityTokenAndHasNoBatchConfiguration() public view {
        assertEq(pool.communityToken(), address(communityToken));
        assertEq(pool.communityTokenPrice(), COMMUNITY_TOKEN_PRICE);
        assertEq(pool.nativePrice(), NATIVE_PRICE);
        assertEq(pool.maxSupply(), MAX_SUPPLY);
        assertEq(pool.referralBps(), REFERRAL_BPS);
        assertEq(pool.totalWhitelistAllocation(), 3);
        assertEq(pool.whitelistAllowance(whitelistUser1), 2);
        assertEq(pool.whitelistAllowance(whitelistUser2), 1);
        assertEq(pool.remainingPaidMints(), 3);
        assertTrue(pool.lockWhitelistSlots());
        assertEq(pool.fundsReceiver(), fundsReceiver);
        assertEq(pool.getUserStakedAmount(whitelistUser1), 0);
    }

    function test_WhitelistMintTakesPriorityRefundsNativeAndIgnoresReferral() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        uint256 nativeBefore = whitelistUser2.balance;
        uint256 platformBefore = platformTreasury.balance;
        uint256 receiverBefore = fundsReceiver.balance;

        vm.prank(whitelistUser2);
        uint256 tokenId = pool.mint{value: NATIVE_PRICE}(1);

        assertEq(tokenId, 2);
        assertEq(whitelistUser2.balance, nativeBefore);
        assertEq(platformTreasury.balance, platformBefore);
        assertEq(fundsReceiver.balance, receiverBefore);
        assertEq(pool.getNFTInfo(1).referralCount, 0);
        assertEq(pool.getNFTInfo(2).referrerTokenId, 0);
        assertEq(pool.whitelistMintedBy(whitelistUser2), 1);
        assertEq(pool.paidMinted(), 0);
        assertEq(communityToken.balanceOf(address(pool)), COMMUNITY_TOKEN_PRICE * 2);
    }

    function test_PaidMintDepositsCommunityTokenAndSplitsOnlyNativePayment() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        uint256 payerTokenBefore = communityToken.balanceOf(paidUser);
        uint256 poolTokenBefore = communityToken.balanceOf(address(pool));
        uint256 referrerNativeBefore = whitelistUser1.balance;
        uint256 platformBefore = platformTreasury.balance;
        uint256 receiverBefore = fundsReceiver.balance;

        vm.prank(paidUser);
        uint256 childId = pool.mint{value: NATIVE_PRICE}(1);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        uint256 referralCommission = (NATIVE_PRICE - platformFee) * REFERRAL_BPS / 10_000;
        assertEq(payerTokenBefore - communityToken.balanceOf(paidUser), COMMUNITY_TOKEN_PRICE);
        assertEq(communityToken.balanceOf(address(pool)) - poolTokenBefore, COMMUNITY_TOKEN_PRICE);
        assertEq(whitelistUser1.balance - referrerNativeBefore, referralCommission);
        assertEq(platformTreasury.balance - platformBefore, platformFee);
        assertEq(fundsReceiver.balance - receiverBefore, NATIVE_PRICE - platformFee - referralCommission);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
        assertEq(pool.getNFTInfo(childId).referrerTokenId, 1);
        assertEq(pool.paidMinted(), 1);
    }

    function test_PaidReferralsUpgradeWhitelistMintedNFT() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintPaid(paidUser, 1);
        _mintPaid(paidUser, 1);

        NFTMiningPool.NFTInfo memory referrer = pool.getNFTInfo(1);
        assertEq(referrer.referralCount, 2);
        assertEq(referrer.level, 2);
        assertEq(referrer.miningWeight, 12_000);
        assertEq(pool.getUserStakedAmount(whitelistUser1), 12_000);
        assertEq(pool.getUserStakedAmount(paidUser), BASE_WEIGHT * 2);
        assertEq(pool.getTotalStakedAmount(), 32_000);
    }

    function test_WhitelistAccountUsesPaidPathAfterAllowanceIsExhausted() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);

        vm.prank(whitelistUser1);
        uint256 paidTokenId = pool.mint{value: NATIVE_PRICE}(1);

        assertEq(pool.whitelistMintedBy(whitelistUser1), 2);
        assertEq(pool.paidMinted(), 1);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
        assertEq(pool.getNFTInfo(paidTokenId).referrerTokenId, 1);
        assertEq(communityToken.balanceOf(address(pool)), COMMUNITY_TOKEN_PRICE * 3);
    }

    function test_LockedWhitelistSlotsCannotBeConsumedByPaidMints() public {
        for (uint256 i; i < 3; ++i) {
            _mintPaid(paidUser, 0);
        }

        vm.expectRevert(NFTMiningPool.PaidSupplyReached.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE}(0);

        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser2, 0, 0);

        assertEq(pool.totalSupply(), MAX_SUPPLY);
        assertEq(pool.paidMinted(), 3);
        assertEq(pool.whitelistMinted(), 3);
        assertEq(communityToken.balanceOf(address(pool)), COMMUNITY_TOKEN_PRICE * MAX_SUPPLY);
    }

    function test_UnlockedWhitelistSlotsCanBeConsumedByPaidMints() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        NFTMiningPool unlockedPool = _addPool(NATIVE_PRICE, 3, REFERRAL_BPS, false, accounts, allowances);
        _fundAndApprove(whitelistUser1, unlockedPool);
        _fundAndApprove(paidUser, unlockedPool);

        for (uint256 i; i < 3; ++i) {
            vm.prank(paidUser);
            unlockedPool.mint{value: NATIVE_PRICE}(0);
        }

        vm.expectRevert(NFTMiningPool.MaxSupplyReached.selector);
        vm.prank(whitelistUser1);
        unlockedPool.mint(0);
        assertEq(unlockedPool.paidMinted(), 3);
        assertEq(unlockedPool.whitelistMinted(), 0);
    }

    function test_PureWhitelistRequiresAllocationEqualToSupply() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 2;

        vm.expectRevert(NFTMiningPool.InvalidWhitelistConfig.selector);
        this.addPoolForRevertTest(0, 3, 0, false, accounts, allowances);
    }

    function test_PureWhitelistMintsEqualBaseWeightWithoutReferralUpgrade() public {
        address[] memory accounts = new address[](2);
        accounts[0] = whitelistUser1;
        accounts[1] = whitelistUser2;
        uint256[] memory allowances = new uint256[](2);
        allowances[0] = 2;
        allowances[1] = 1;
        NFTMiningPool whitelistPool = _addPool(0, 3, 0, false, accounts, allowances);
        _fundAndApprove(whitelistUser1, whitelistPool);
        _fundAndApprove(whitelistUser2, whitelistPool);

        vm.prank(whitelistUser1);
        whitelistPool.mint(0);
        vm.prank(whitelistUser2);
        whitelistPool.mint(1);

        assertTrue(whitelistPool.lockWhitelistSlots());
        assertEq(whitelistPool.getNFTInfo(1).referralCount, 0);
        assertEq(whitelistPool.getNFTInfo(2).referrerTokenId, 0);
        assertEq(whitelistPool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(whitelistPool.miningWeightOf(2), BASE_WEIGHT);
        assertEq(whitelistPool.getUserStakedAmount(whitelistUser1), BASE_WEIGHT);
        assertEq(whitelistPool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);

        vm.expectRevert(NFTMiningPool.WhitelistOnly.selector);
        vm.prank(paidUser);
        whitelistPool.mint(0);
    }

    function test_FundsReceiverCanChangeAndOnlyReceivesNativeProceeds() public {
        address newReceiver = makeAddr("newReceiver");
        pool.setFundsReceiver(newReceiver);
        uint256 communityBalanceBefore = communityToken.balanceOf(address(pool));

        _mintPaid(paidUser, 0);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        assertEq(newReceiver.balance, NATIVE_PRICE - platformFee);
        assertEq(fundsReceiver.balance, 0);
        assertEq(communityToken.balanceOf(address(pool)) - communityBalanceBefore, COMMUNITY_TOKEN_PRICE);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(paidUser);
        pool.setFundsReceiver(paidUser);
    }

    function test_PaidMintRequiresExactNativePayment() public {
        vm.expectRevert(NFTMiningPool.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE - 1}(0);

        vm.expectRevert(NFTMiningPool.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE + 1}(0);

        assertEq(pool.totalSupply(), 0);
        assertEq(communityToken.balanceOf(address(pool)), 0);
    }

    function test_CommunityTokensRemainInPoolAcrossWhitelistAndPaidMints() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintPaid(paidUser, 1);

        assertEq(communityToken.balanceOf(address(pool)), COMMUNITY_TOKEN_PRICE * 2);
        assertEq(communityToken.balanceOf(fundsReceiver), 0);
        assertEq(communityToken.balanceOf(platformTreasury), 0);
        assertEq(communityToken.balanceOf(whitelistUser1), 100_000 ether - COMMUNITY_TOKEN_PRICE);
    }

    function _addPool(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) internal returns (NFTMiningPool createdPool) {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0;
        thresholds[1] = 2;
        thresholds[2] = 4;
        uint256[] memory weights = new uint256[](3);
        weights[0] = BASE_WEIGHT;
        weights[1] = 12_000;
        weights[2] = 15_000;

        NFTMiningPoolFactory.PoolConfig memory config = NFTMiningPoolFactory.PoolConfig({
            symbol: "IDXNFT",
            fundsReceiver: fundsReceiver,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            nativePrice: nativePrice,
            maxSupply: supply,
            referralBps: referralRate,
            lockWhitelistSlots: lockSlots,
            whitelistAccounts: accounts,
            whitelistAllowances: allowances
        });

        uint256 existingPools = activePoolCount;
        uint16[] memory ratios = new uint16[](existingPools + 1);
        uint16 ratio = uint16(10_000 / (existingPools + 1));
        uint256 assigned;
        for (uint256 i; i < existingPools; ++i) {
            ratios[i] = ratio;
            assigned += ratio;
        }
        ratios[existingPools] = uint16(10_000 - assigned);

        community.adminAddPool("Index Broker NFT", ratios, address(poolFactory), abi.encode(config));
        createdPool = NFTMiningPool(payable(community.activedPools(existingPools)));
        activePoolCount = existingPools + 1;
    }

    function addPoolForRevertTest(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) external returns (NFTMiningPool) {
        require(msg.sender == address(this), "test only");
        return _addPool(nativePrice, supply, referralRate, lockSlots, accounts, allowances);
    }

    function _fundAndApprove(address user, NFTMiningPool targetPool) internal {
        if (communityToken.balanceOf(user) < 100_000 ether) {
            assertTrue(communityToken.transfer(user, 100_000 ether));
        }
        vm.deal(user, 100 ether);
        vm.prank(user);
        communityToken.approve(address(targetPool), type(uint256).max);
    }

    function _mintWhitelist(address user, uint256 referrerTokenId, uint256 value) internal returns (uint256) {
        vm.prank(user);
        return pool.mint{value: value}(referrerTokenId);
    }

    function _mintPaid(address user, uint256 referrerTokenId) internal returns (uint256) {
        vm.prank(user);
        return pool.mint{value: NATIVE_PRICE}(referrerTokenId);
    }
}
