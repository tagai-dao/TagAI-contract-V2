// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/nft-mining/NFTMiningPool.sol";
import "../../src/nutbox/dapps/nft-mining/NFTMiningPoolFactory.sol";
import "../../src/nutbox/dapps/nft-mining/NFTMiningRenderer.sol";
import "../../src/interfaces/INFTMiningRenderer.sol";

contract NFTMiningTestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply_) ERC20(name_, symbol_) {
        _mint(msg.sender, supply_);
    }
}

contract NFTMiningCustomRenderer is INFTMiningRenderer {
    function renderSVG(RenderParams calldata params) external pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 840"><text id="custom-renderer">',
            params.collectionName,
            "</text></svg>"
        );
    }
}

contract NFTMiningPoolTest is Test {
    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    NFTMiningPoolFactory internal poolFactory;
    Community internal community;
    NFTMiningPool internal pool;
    NFTMiningTestERC20 internal rewardToken;
    NFTMiningTestERC20 internal usdg;

    address internal treasury = makeAddr("treasury");
    address internal platformTreasury = makeAddr("platformTreasury");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");
    address internal marketplace = makeAddr("marketplace");

    uint256 internal constant PRICE = 1_000 ether;
    uint256 internal constant FIRST_BATCH_SUPPLY = 6;
    uint16 internal constant PLATFORM_FEE_BPS = 30;
    uint16 internal constant REFERRAL_BPS = 100;

    function setUp() public {
        vm.warp(3_600);

        committee = new Committee(payable(platformTreasury));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        poolFactory = new NFTMiningPoolFactory(address(communityFactory));
        rewardToken = new NFTMiningTestERC20("Reward", "RWD", 10_000_000 ether);
        usdg = new NFTMiningTestERC20("USDG", "USDG", 10_000_000 ether);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(poolFactory));

        address communityAddress = communityFactory.createCommunity(
            false, address(rewardToken), address(0), bytes(""), address(calculator), bytes("")
        );
        community = Community(payable(communityAddress));

        uint256[] memory thresholds = new uint256[](4);
        thresholds[0] = 0;
        thresholds[1] = 2;
        thresholds[2] = 4;
        thresholds[3] = 6;

        uint256[] memory weights = new uint256[](4);
        weights[0] = 10_000;
        weights[1] = 12_000;
        weights[2] = 15_000;
        weights[3] = 20_000;

        NFTMiningPoolFactory.PoolConfig memory config = NFTMiningPoolFactory.PoolConfig({
            symbol: "NBXNFT",
            fundsReceiver: treasury,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            firstPaymentAsset: address(usdg),
            firstMintPrice: PRICE,
            firstBatchSupply: FIRST_BATCH_SUPPLY,
            firstReferralBps: REFERRAL_BPS
        });

        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        community.adminAddPool("Nutbox Mining NFT", ratios, address(poolFactory), abi.encode(config));

        pool = NFTMiningPool(payable(community.activedPools(0)));

        assertTrue(usdg.transfer(user1, 100_000 ether));
        assertTrue(usdg.transfer(user2, 100_000 ether));
        assertTrue(usdg.transfer(user3, 100_000 ether));
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);

        vm.prank(user1);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(user2);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(user3);
        usdg.approve(address(pool), type(uint256).max);
    }

    function test_InitializationAndFactoryOwnership() public view {
        assertEq(pool.name(), "Nutbox Mining NFT");
        assertEq(pool.symbol(), "NBXNFT");
        assertEq(pool.owner(), address(this));
        assertEq(pool.getCommunity(), address(community));
        assertEq(pool.getFactory(), address(poolFactory));
        assertEq(pool.renderer(), poolFactory.defaultRenderer());
        assertEq(pool.currentBatchId(), 1);
        assertEq(pool.levelCount(), 4);

        (
            address paymentAsset,
            uint16 referralBps,
            uint8 paletteId,
            bool active,
            bool paused,
            uint256 mintPrice,
            uint256 maxSupply,
            uint256 minted
        ) = pool.batches(1);
        assertEq(paymentAsset, address(usdg));
        assertEq(referralBps, REFERRAL_BPS);
        assertEq(paletteId, 1);
        assertTrue(active);
        assertFalse(paused);
        assertEq(mintPrice, PRICE);
        assertEq(maxSupply, FIRST_BATCH_SUPPLY);
        assertEq(minted, 0);
        assertEq(poolFactory.DEFAULT_PLATFORM_FEE_BPS(), PLATFORM_FEE_BPS);
        assertEq(poolFactory.platformFeeBps(), PLATFORM_FEE_BPS);
        assertEq(pool.platformFeeBps(), PLATFORM_FEE_BPS);
        assertEq(pool.platformFeeReceiver(), platformTreasury);
    }

    function test_CustomRendererCanBeSelectedAtPoolCreation() public {
        NFTMiningCustomRenderer customRenderer = new NFTMiningCustomRenderer();
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;

        NFTMiningPoolFactory.PoolConfig memory config = NFTMiningPoolFactory.PoolConfig({
            symbol: "CUSTOM",
            fundsReceiver: treasury,
            renderer: address(customRenderer),
            levelThresholds: thresholds,
            levelWeights: weights,
            firstPaymentAsset: address(0),
            firstMintPrice: 1 ether,
            firstBatchSupply: 2,
            firstReferralBps: 0
        });

        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 5_000;
        ratios[1] = 5_000;
        community.adminAddPool("Custom Mining NFT", ratios, address(poolFactory), abi.encode(config));

        NFTMiningPool customPool = NFTMiningPool(payable(community.activedPools(1)));
        assertEq(customPool.renderer(), address(customRenderer));

        vm.prank(user1);
        uint256 tokenId = customPool.mint{value: 1 ether}(0);
        assertTrue(_contains(customPool.tokenSVG(tokenId), "custom-renderer"));
        assertTrue(_contains(customPool.tokenSVG(tokenId), "Custom Mining NFT"));
    }

    function test_DefaultRendererSupportsEveryPortraitBatchStyle() public view {
        NFTMiningRenderer defaultRenderer = NFTMiningRenderer(poolFactory.defaultRenderer());
        INFTMiningRenderer.RenderParams memory params = INFTMiningRenderer.RenderParams({
            collectionName: "Nutbox Mining NFT",
            tokenId: 4107,
            seed: 9821,
            referralCount: 2,
            miningWeight: 12_000,
            batchId: 3,
            level: 2,
            paletteId: 1
        });

        bytes32 previousHash;
        for (uint8 paletteId = 1; paletteId <= 6; ++paletteId) {
            params.paletteId = paletteId;
            string memory svg = defaultRenderer.renderSVG(params);
            assertTrue(_contains(svg, 'viewBox="0 0 600 840"'));
            assertTrue(_contains(svg, "PALETTE "));
            bytes32 svgHash = keccak256(bytes(svg));
            if (paletteId > 1) assertNotEq(svgHash, previousHash);
            previousHash = svgHash;
        }
    }

    function test_DefaultRendererDistinguishesAscensionPhases() public view {
        NFTMiningRenderer defaultRenderer = NFTMiningRenderer(poolFactory.defaultRenderer());
        INFTMiningRenderer.RenderParams memory params = INFTMiningRenderer.RenderParams({
            collectionName: "Nutbox Mining NFT",
            tokenId: 4107,
            seed: 9821,
            referralCount: 12,
            miningWeight: 100_000,
            batchId: 3,
            level: 7,
            paletteId: 3
        });

        string memory level7 = defaultRenderer.renderSVG(params);
        params.level = 8;
        string memory level8 = defaultRenderer.renderSVG(params);
        params.level = 9;
        string memory level9 = defaultRenderer.renderSVG(params);

        assertTrue(_contains(level7, "G1 P1"));
        assertTrue(_contains(level8, "G1 P2"));
        assertTrue(_contains(level9, "G1 P3"));
        assertNotEq(keccak256(bytes(level7)), keccak256(bytes(level8)));
        assertNotEq(keccak256(bytes(level8)), keccak256(bytes(level9)));
    }

    function test_MintWithERC20AndReferralSplit() public {
        _mintAs(user1, 0);

        uint256 user1Before = usdg.balanceOf(user1);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        uint256 platformBefore = usdg.balanceOf(platformTreasury);
        uint256 childId = _mintAs(user2, 1);

        uint256 platformFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        uint256 referralCommission = ((PRICE - platformFee) * REFERRAL_BPS) / 10_000;
        assertEq(childId, 2);
        assertEq(usdg.balanceOf(platformTreasury) - platformBefore, platformFee);
        assertEq(usdg.balanceOf(user1) - user1Before, referralCommission);
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, PRICE - platformFee - referralCommission);

        NFTMiningPool.NFTInfo memory parent = pool.getNFTInfo(1);
        NFTMiningPool.NFTInfo memory child = pool.getNFTInfo(2);
        assertEq(parent.owner, user1);
        assertEq(parent.referralCount, 1);
        assertEq(parent.level, 1);
        assertEq(child.owner, user2);
        assertEq(child.referrerTokenId, 1);
        assertEq(child.batchId, 1);
    }

    function test_RepeatedBuyerCountsEveryMintAndLevelsUpParent() public {
        _mintAs(user1, 0);
        _mintAs(user2, 1);
        _mintAs(user2, 1);

        NFTMiningPool.NFTInfo memory parent = pool.getNFTInfo(1);
        assertEq(parent.referralCount, 2);
        assertEq(parent.level, 2);
        assertEq(parent.miningWeight, 12_000);
        assertEq(pool.getUserStakedAmount(user1), 12_000);
        assertEq(pool.getUserStakedAmount(user2), 20_000);
        assertEq(pool.getTotalStakedAmount(), 32_000);
    }

    /// @dev Self-referral is token-based: the current NFT owner receives the batch commission.
    function test_SelfReferralIsAllowedAndPaysCurrentOwner() public {
        _mintAs(user1, 0);

        uint256 userBefore = usdg.balanceOf(user1);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        uint256 childId = _mintAs(user1, 1);

        uint256 platformFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        uint256 referralCommission = ((PRICE - platformFee) * REFERRAL_BPS) / 10_000;
        assertEq(userBefore - usdg.balanceOf(user1), PRICE - referralCommission);
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, PRICE - platformFee - referralCommission);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
        assertEq(pool.getNFTInfo(childId).referrerTokenId, 1);
        assertEq(pool.getUserStakedAmount(user1), 20_000);
    }

    function test_ReferralRightsFollowCurrentNFTOwner() public {
        _mintAs(user1, 0);

        vm.prank(user1);
        pool.transferFrom(user1, user2, 1);

        uint256 user2Before = usdg.balanceOf(user2);
        _mintAs(user3, 1);

        uint256 platformFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        uint256 referralCommission = ((PRICE - platformFee) * REFERRAL_BPS) / 10_000;
        assertEq(usdg.balanceOf(user2) - user2Before, referralCommission);
        assertEq(pool.getNFTInfo(1).owner, user2);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
    }

    function test_BatchCanUseNativeAssetAndOwnReferralRate() public {
        _mintAs(user1, 0);
        _sellOutCurrentBatch();
        uint256 secondBatchId = pool.createBatch(2, address(0), 0.2 ether, 300);
        assertEq(secondBatchId, 2);

        uint256 referrerBefore = user1.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 platformBefore = platformTreasury.balance;
        vm.prank(user2);
        uint256 tokenId = pool.mint{value: 0.2 ether}(1);

        uint256 platformFee = (0.2 ether * PLATFORM_FEE_BPS) / 10_000;
        uint256 referralCommission = ((0.2 ether - platformFee) * 300) / 10_000;
        assertEq(platformTreasury.balance - platformBefore, platformFee);
        assertEq(user1.balance - referrerBefore, referralCommission);
        assertEq(treasury.balance - treasuryBefore, 0.2 ether - platformFee - referralCommission);
        assertEq(pool.getNFTInfo(tokenId).batchId, 2);
        assertTrue(_contains(pool.tokenSVG(tokenId), "BATCH 2"));
        assertNotEq(keccak256(bytes(pool.tokenSVG(1))), keccak256(bytes(pool.tokenSVG(tokenId))));

        vm.prank(user3);
        pool.mint{value: 0.2 ether}(1);

        (,, uint8 paletteId, bool active, bool paused,, uint256 maxSupply, uint256 minted) = pool.batches(2);
        assertEq(paletteId, 2);
        assertFalse(active);
        assertFalse(paused);
        assertEq(maxSupply, 2);
        assertEq(minted, 2);
    }

    function test_CannotCreateBatchWhileCurrentBatchIsActiveOrPaused() public {
        vm.expectRevert(NFTMiningPool.ActiveBatchExists.selector);
        pool.createBatch(100, address(0), 1 ether, 0);

        pool.setCurrentBatchPaused(true);
        vm.expectRevert(NFTMiningPool.ActiveBatchExists.selector);
        pool.createBatch(100, address(0), 1 ether, 0);
    }

    function test_BatchPaletteCyclesAutomaticallyFromBatchId() public {
        for (uint256 batchId = 1; batchId <= 7; ++batchId) {
            (,, uint8 paletteId,,,,,) = pool.batches(batchId);
            assertEq(paletteId, ((batchId - 1) % 6) + 1);

            if (batchId < 7) {
                _sellOutCurrentBatch();
                assertEq(pool.createBatch(1, address(usdg), 1 ether, 0), batchId + 1);
            }
        }
    }

    function test_PauseAndClosedCommunityOnlyBlockMint() public {
        _mintAs(user1, 0);

        pool.setCurrentBatchPaused(true);
        vm.expectRevert(NFTMiningPool.MintIsPaused.selector);
        vm.prank(user2);
        pool.mint(0);
        pool.setCurrentBatchPaused(false);

        uint16[] memory emptyRatios = new uint16[](0);
        community.adminClosePool(0, emptyRatios);

        vm.expectRevert(NFTMiningPool.PoolIsInactive.selector);
        vm.prank(user2);
        pool.mint(0);

        vm.prank(user1);
        pool.transferFrom(user1, user2, 1);
        assertEq(pool.ownerOf(1), user2);
        assertEq(pool.getUserStakedAmount(user2), 10_000);
    }

    function test_OnlyOwnerCanConfigurePool() public {
        vm.startPrank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setCurrentBatchPaused(true);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setFundsReceiver(user1);
        vm.stopPrank();
    }

    function test_InvalidNativePaymentRevertsWithoutChangingSupply() public {
        _sellOutCurrentBatch();
        pool.createBatch(2, address(0), 0.2 ether, 0);

        vm.expectRevert(NFTMiningPool.InvalidPayment.selector);
        vm.prank(user1);
        pool.mint{value: 0.1 ether}(0);

        assertEq(pool.totalSupply(), FIRST_BATCH_SUPPLY);
        (,,,,,,, uint256 minted) = pool.batches(2);
        assertEq(minted, 0);
    }

    function test_PlatformFeeReceiverFollowsCommitteeConfiguration() public {
        address newPlatformTreasury = makeAddr("newPlatformTreasury");
        committee.adminSetFeeRecipient(payable(newPlatformTreasury));

        uint256 beforeBalance = usdg.balanceOf(newPlatformTreasury);
        _mintAs(user1, 0);

        assertEq(pool.platformFeeReceiver(), newPlatformTreasury);
        assertEq(usdg.balanceOf(newPlatformTreasury) - beforeBalance, (PRICE * PLATFORM_FEE_BPS) / 10_000);
    }

    function test_PlatformCanUpdateFeeRateForExistingPools() public {
        uint16 newPlatformFeeBps = 75;
        poolFactory.setPlatformFeeBps(newPlatformFeeBps);

        uint256 platformBefore = usdg.balanceOf(platformTreasury);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        _mintAs(user1, 0);

        uint256 expectedPlatformFee = (PRICE * newPlatformFeeBps) / 10_000;
        assertEq(pool.platformFeeBps(), newPlatformFeeBps);
        assertEq(usdg.balanceOf(platformTreasury) - platformBefore, expectedPlatformFee);
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, PRICE - expectedPlatformFee);

        vm.expectRevert("Invalid platform fee");
        poolFactory.setPlatformFeeBps(10_001);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        poolFactory.setPlatformFeeBps(100);
    }

    function test_TokensOfOwnerSupportsPaginationAndTransfers() public {
        _mintAs(user1, 0);
        _mintAs(user1, 1);
        _mintAs(user1, 1);

        uint256[] memory firstPage = pool.tokensOfOwner(user1, 0, 2);
        uint256[] memory secondPage = pool.tokensOfOwner(user1, 2, 2);
        assertEq(firstPage.length, 2);
        assertEq(firstPage[0], 1);
        assertEq(firstPage[1], 2);
        assertEq(secondPage.length, 1);
        assertEq(secondPage[0], 3);

        vm.prank(user1);
        pool.transferFrom(user1, user2, 2);

        uint256[] memory user2Tokens = pool.tokensOfOwner(user2, 0, 10);
        assertEq(user2Tokens.length, 1);
        assertEq(user2Tokens[0], 2);
        assertEq(pool.tokensOfOwner(user1, 10, 10).length, 0);
    }

    function test_OpenSeaStyleApprovedTransferMovesMiningWeight() public {
        _mintAs(user1, 0);

        vm.prank(user1);
        pool.setApprovalForAll(marketplace, true);
        vm.prank(marketplace);
        pool.transferFrom(user1, user2, 1);

        assertEq(pool.ownerOf(1), user2);
        assertEq(pool.getUserStakedAmount(user1), 0);
        assertEq(pool.getUserStakedAmount(user2), 10_000);
        assertEq(pool.getTotalStakedAmount(), 10_000);
    }

    function test_SupportsOpenSeaInterfacesAndDynamicMetadata() public {
        uint256 tokenId = _mintAs(user1, 0);

        assertTrue(pool.supportsInterface(type(IERC721).interfaceId));
        assertTrue(pool.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(pool.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertTrue(pool.supportsInterface(0x49064906));

        string memory uri = pool.tokenURI(tokenId);
        string memory svgBefore = pool.tokenSVG(tokenId);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
        assertTrue(_contains(svgBefore, "BATCH 1"));
        assertTrue(_contains(svgBefore, 'viewBox="0 0 600 840"'));
        assertTrue(_contains(svgBefore, ">L1"));
        assertTrue(_contains(svgBefore, "PALETTE 1"));

        _mintAs(user2, tokenId);
        _mintAs(user2, tokenId);
        string memory svgAfter = pool.tokenSVG(tokenId);
        assertTrue(_contains(svgAfter, ">L2"));
        assertTrue(_contains(svgAfter, "REF 2"));
        assertGt(bytes(svgAfter).length, bytes(svgBefore).length);
        assertNotEq(keccak256(bytes(svgBefore)), keccak256(bytes(svgAfter)));
    }

    function test_TransferSettlesOldOwnerAndCommunityPaysClaim() public {
        _mintAs(user1, 0);

        uint256 injected = 168_000 ether;
        rewardToken.approve(address(calculator), injected);
        calculator.inject(address(community), injected);

        vm.warp(11 * 3_600);
        vm.prank(user1);
        pool.transferFrom(user1, user2, 1);

        uint256 expected = 10_000 ether;
        assertEq(community.getPoolPendingRewards(address(pool), user1), expected);
        assertEq(community.getPoolPendingRewards(address(pool), user2), 0);

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint256 beforeBalance = rewardToken.balanceOf(user1);
        vm.prank(user1);
        community.withdrawPoolsRewards(pools);
        assertEq(rewardToken.balanceOf(user1) - beforeBalance, expected);

        vm.warp(12 * 3_600);
        assertEq(community.getPoolPendingRewards(address(pool), user2), 1_000 ether);
    }

    function test_LevelUpgradeSettlesAtOldWeight() public {
        _mintAs(user1, 0);

        uint256 injected = 168_000 ether;
        rewardToken.approve(address(calculator), injected);
        calculator.inject(address(community), injected);
        vm.warp(11 * 3_600);

        _mintAs(user2, 1);
        _mintAs(user2, 1);

        assertEq(pool.getNFTInfo(1).level, 2);
        assertEq(pool.getUserStakedAmount(user1), 12_000);
        assertEq(community.getPoolPendingRewards(address(pool), user1), 10_000 ether);
    }

    function testFuzz_ERC20ReferralSplit(uint16 bps) public {
        bps = uint16(bound(uint256(bps), 0, 10_000));
        _mintAs(user1, 0);
        _sellOutCurrentBatch();
        pool.createBatch(2, address(usdg), PRICE, bps);

        uint256 referrerBefore = usdg.balanceOf(user1);
        uint256 treasuryBefore = usdg.balanceOf(treasury);
        uint256 platformBefore = usdg.balanceOf(platformTreasury);
        _mintAs(user2, 1);

        uint256 expectedPlatformFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedCommission = ((PRICE - expectedPlatformFee) * bps) / 10_000;
        assertEq(usdg.balanceOf(platformTreasury) - platformBefore, expectedPlatformFee);
        assertEq(usdg.balanceOf(user1) - referrerBefore, expectedCommission);
        assertEq(usdg.balanceOf(treasury) - treasuryBefore, PRICE - expectedPlatformFee - expectedCommission);
    }

    function testFuzz_TransfersPreserveWeightAccounting(uint8 moves) public {
        _mintAs(user1, 0);
        _mintAs(user2, 1);
        _mintAs(user3, 1);
        moves = uint8(bound(uint256(moves), 1, 30));

        address[3] memory users = [user1, user2, user3];
        for (uint256 i = 0; i < moves; ++i) {
            uint256 tokenId = (i % 3) + 1;
            address from = pool.ownerOf(tokenId);
            address to = users[(i + 1) % users.length];
            if (from == to) {
                to = users[(i + 2) % users.length];
            }
            vm.prank(from);
            pool.transferFrom(from, to, tokenId);
        }

        uint256 summedWeight;
        for (uint256 i = 0; i < users.length; ++i) {
            summedWeight += pool.getUserStakedAmount(users[i]);
        }
        assertEq(summedWeight, pool.getTotalStakedAmount());

        uint256 tokenWeightSum;
        for (uint256 tokenId = 1; tokenId <= pool.totalSupply(); ++tokenId) {
            tokenWeightSum += pool.miningWeightOf(tokenId);
        }
        assertEq(tokenWeightSum, pool.getTotalStakedAmount());
    }

    function _mintAs(address user, uint256 referrerTokenId) internal returns (uint256 tokenId) {
        vm.prank(user);
        tokenId = pool.mint(referrerTokenId);
    }

    function _sellOutCurrentBatch() internal {
        (,,,,,, uint256 maxSupply, uint256 minted) = pool.batches(pool.currentBatchId());
        while (minted < maxSupply) {
            _mintAs(user3, 0);
            ++minted;
        }
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > valueBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length > valueBytes.length) return false;
        for (uint256 i = 0; i + needleBytes.length <= valueBytes.length; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < needleBytes.length; ++j) {
                if (valueBytes[i + j] != needleBytes[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
