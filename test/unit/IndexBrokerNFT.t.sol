// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTRenderer.sol";

contract IndexBrokerCommunityToken is ERC20 {
    constructor() ERC20("Community", "COM") {
        _mint(msg.sender, 10_000_000 ether);
    }
}

contract IndexBrokerNFTTest is Test {
    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    IndexBrokerNFTFactory internal poolFactory;
    Community internal community;
    IndexBrokerNFT internal pool;
    IndexBrokerNFTAMM internal amm;
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
    uint16 internal constant AMM_NORMAL_FEE_BPS = 1_000;
    uint16 internal constant AMM_SPECIFIC_FEE_BPS = 1_500;
    uint256 internal constant BASE_WEIGHT = 10_000;

    function setUp() public {
        vm.warp(3_600);

        committee = new Committee(payable(platformTreasury));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        poolFactory = new IndexBrokerNFTFactory(
            address(communityFactory), address(new IndexBrokerNFTRenderer()), address(new IndexBrokerNFTAMM())
        );
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
        amm = IndexBrokerNFTAMM(payable(pool.ammVault()));

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
        assertEq(amm.collection(), address(pool));
        assertEq(amm.communityToken(), address(communityToken));
        assertEq(amm.tokensPerNFT(), COMMUNITY_TOKEN_PRICE);
        assertEq(amm.normalFeeBps(), AMM_NORMAL_FEE_BPS);
        assertEq(amm.specificFeeBps(), AMM_SPECIFIC_FEE_BPS);
        assertFalse(amm.nativeFeeConfigured());
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
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 2);
    }

    function test_PaidMintDepositsCommunityTokenAndSplitsOnlyNativePayment() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        uint256 payerTokenBefore = communityToken.balanceOf(paidUser);
        uint256 poolTokenBefore = communityToken.balanceOf(address(amm));
        uint256 referrerNativeBefore = whitelistUser1.balance;
        uint256 platformBefore = platformTreasury.balance;
        uint256 receiverBefore = fundsReceiver.balance;

        vm.prank(paidUser);
        uint256 childId = pool.mint{value: NATIVE_PRICE}(1);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        uint256 referralCommission = (NATIVE_PRICE - platformFee) * REFERRAL_BPS / 10_000;
        assertEq(payerTokenBefore - communityToken.balanceOf(paidUser), COMMUNITY_TOKEN_PRICE);
        assertEq(communityToken.balanceOf(address(amm)) - poolTokenBefore, COMMUNITY_TOKEN_PRICE);
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

        IndexBrokerNFT.NFTInfo memory referrer = pool.getNFTInfo(1);
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
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 3);
    }

    function test_LockedWhitelistSlotsCannotBeConsumedByPaidMints() public {
        for (uint256 i; i < 3; ++i) {
            _mintPaid(paidUser, 0);
        }

        vm.expectRevert(IndexBrokerNFT.PaidSupplyReached.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE}(0);

        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser2, 0, 0);

        assertEq(pool.totalSupply(), MAX_SUPPLY);
        assertEq(pool.paidMinted(), 3);
        assertEq(pool.whitelistMinted(), 3);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * MAX_SUPPLY);
    }

    function test_UnlockedWhitelistSlotsCanBeConsumedByPaidMints() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFT unlockedPool = _addPool(NATIVE_PRICE, 3, REFERRAL_BPS, false, accounts, allowances);
        _fundAndApprove(whitelistUser1, unlockedPool);
        _fundAndApprove(paidUser, unlockedPool);

        for (uint256 i; i < 3; ++i) {
            vm.prank(paidUser);
            unlockedPool.mint{value: NATIVE_PRICE}(0);
        }

        vm.expectRevert(IndexBrokerNFT.MaxSupplyReached.selector);
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

        vm.expectRevert(IndexBrokerNFT.InvalidWhitelistConfig.selector);
        this.addPoolForRevertTest(0, 3, 0, false, accounts, allowances);
    }

    function test_PureWhitelistMintsEqualBaseWeightWithoutReferralUpgrade() public {
        address[] memory accounts = new address[](2);
        accounts[0] = whitelistUser1;
        accounts[1] = whitelistUser2;
        uint256[] memory allowances = new uint256[](2);
        allowances[0] = 2;
        allowances[1] = 1;
        IndexBrokerNFT whitelistPool = _addPool(0, 3, 0, false, accounts, allowances);
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

        vm.expectRevert(IndexBrokerNFT.WhitelistOnly.selector);
        vm.prank(paidUser);
        whitelistPool.mint(0);
    }

    function test_FundsReceiverCanChangeAndOnlyReceivesNativeProceeds() public {
        address newReceiver = makeAddr("newReceiver");
        pool.setFundsReceiver(newReceiver);
        uint256 communityBalanceBefore = communityToken.balanceOf(address(amm));

        _mintPaid(paidUser, 0);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        assertEq(newReceiver.balance, NATIVE_PRICE - platformFee);
        assertEq(fundsReceiver.balance, 0);
        assertEq(communityToken.balanceOf(address(amm)) - communityBalanceBefore, COMMUNITY_TOKEN_PRICE);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(paidUser);
        pool.setFundsReceiver(paidUser);
    }

    function test_PaidMintRequiresExactNativePayment() public {
        vm.expectRevert(IndexBrokerNFT.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE - 1}(0);

        vm.expectRevert(IndexBrokerNFT.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE + 1}(0);

        assertEq(pool.totalSupply(), 0);
        assertEq(communityToken.balanceOf(address(amm)), 0);
    }

    function test_CommunityTokensRemainInAMMReserveAcrossWhitelistAndPaidMints() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintPaid(paidUser, 1);

        assertEq(communityToken.balanceOf(address(pool)), 0);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 2);
        assertEq(communityToken.balanceOf(fundsReceiver), 0);
        assertEq(communityToken.balanceOf(platformTreasury), 0);
        assertEq(communityToken.balanceOf(whitelistUser1), 100_000 ether - COMMUNITY_TOKEN_PRICE);
    }

    function test_DirectNFTTransferToAMMIsRejected() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        vm.expectRevert(IndexBrokerNFT.InvalidAMMTransfer.selector);
        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, address(amm), 1);

        assertEq(pool.ownerOf(1), whitelistUser1);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMCustodyStopsMiningAndPreventsReferralUntilNFTLeaves() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        bytes memory acceptanceCall = abi.encodeCall(IndexBrokerNFTAMM.isAcceptingNFT, (whitelistUser1, 1));
        vm.mockCall(address(amm), acceptanceCall, abi.encode(true));

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, address(amm), 1);

        assertEq(pool.ownerOf(1), address(amm));
        assertEq(pool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.activeMiningWeightOf(1), 0);
        assertEq(pool.getNFTInfo(1).miningWeight, BASE_WEIGHT);
        assertFalse(pool.getNFTInfo(1).miningActive);
        assertFalse(pool.miningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser1), 0);
        assertEq(pool.getTotalStakedAmount(), 0);

        vm.expectRevert(IndexBrokerNFT.ReferrerInAMM.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE}(1);

        vm.prank(address(amm));
        pool.safeTransferFrom(address(amm), whitelistUser2, 1);

        assertEq(pool.ownerOf(1), whitelistUser2);
        assertEq(pool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.activeMiningWeightOf(1), BASE_WEIGHT);
        assertTrue(pool.getNFTInfo(1).miningActive);
        assertTrue(pool.miningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMTradingWaitsForNativeFeePricingAndKeepsNativeBalance() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);

        vm.expectRevert(IndexBrokerNFTAMM.NativeFeeNotConfigured.selector);
        vm.prank(whitelistUser1);
        amm.sellNFT(1, COMMUNITY_TOKEN_PRICE);

        vm.expectRevert(IndexBrokerNFTAMM.NativeFeeNotConfigured.selector);
        amm.quoteNormalNativeFee();
        vm.expectRevert(IndexBrokerNFTAMM.NativeFeeNotConfigured.selector);
        amm.quoteSpecificNativeFee();

        vm.prank(paidUser);
        (bool success,) = address(amm).call{value: 0.25 ether}("");
        assertTrue(success);
        assertEq(address(amm).balance, 0.25 ether);
    }

    function _addPool(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) internal returns (IndexBrokerNFT createdPool) {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0;
        thresholds[1] = 2;
        thresholds[2] = 4;
        uint256[] memory weights = new uint256[](3);
        weights[0] = BASE_WEIGHT;
        weights[1] = 12_000;
        weights[2] = 15_000;

        IndexBrokerNFTFactory.PoolConfig memory config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "IDXNFT",
            fundsReceiver: fundsReceiver,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            nativePrice: nativePrice,
            maxSupply: supply,
            referralBps: referralRate,
            ammNormalFeeBps: AMM_NORMAL_FEE_BPS,
            ammSpecificFeeBps: AMM_SPECIFIC_FEE_BPS,
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
        createdPool = IndexBrokerNFT(payable(community.activedPools(existingPools)));
        activePoolCount = existingPools + 1;
    }

    function addPoolForRevertTest(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) external returns (IndexBrokerNFT) {
        require(msg.sender == address(this), "test only");
        return _addPool(nativePrice, supply, referralRate, lockSlots, accounts, allowances);
    }

    function _fundAndApprove(address user, IndexBrokerNFT targetPool) internal {
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
