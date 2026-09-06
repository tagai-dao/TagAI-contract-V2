// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";

contract IndexBrokerMiningCommunityMock {
    address public immutable communityToken;
    address public pool;

    constructor(address communityToken_) {
        communityToken = communityToken_;
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function poolActived(address candidate) external view returns (bool) {
        return candidate == pool;
    }

    function getCommunityToken() external view returns (address) {
        return communityToken;
    }

    function committee() external view returns (address) {
        return address(this);
    }

    function getFeeRecipient() external pure returns (address payable) {
        return payable(address(0xfee));
    }

    function updatePools() external {}

    function getShareAcc(address) external pure returns (uint256) {
        return 0;
    }

    function getUserDebt(address, address) external pure returns (uint256) {
        return 0;
    }

    function appendUserReward(address, uint256) external {}

    function setUserDebt(address, uint256) external {}
}

contract IndexBrokerMiningAMMMock {
    function isAcceptingNFT(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract IndexBrokerMiningCodeStub {}

contract IndexBrokerCallbackCommunityToken is ERC20 {
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IndexBrokerNFTBurn public callbackPool;
    uint256 public callbackTokenId;
    address public callbackRecipient;
    bool public callbackEnabled;
    bool public shortBurnEnabled;

    constructor() ERC20("Callback Community", "CALLBACK") {
        _mint(msg.sender, 10_000_000 ether);
    }

    function configureCallback(IndexBrokerNFTBurn pool_, uint256 tokenId_, bool enabled_) external {
        callbackPool = pool_;
        callbackTokenId = tokenId_;
        callbackRecipient = address(0);
        callbackEnabled = enabled_;
    }

    function configureTransferCallback(IndexBrokerNFTBurn pool_, uint256 tokenId_, address recipient_, bool enabled_)
        external
    {
        callbackPool = pool_;
        callbackTokenId = tokenId_;
        callbackRecipient = recipient_;
        callbackEnabled = enabled_;
    }

    function setShortBurnEnabled(bool enabled) external {
        shortBurnEnabled = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackEnabled) {
            callbackEnabled = false;
            address recipient = callbackRecipient == address(0) ? from : callbackRecipient;
            callbackPool.transferFrom(from, recipient, callbackTokenId);
        }
        return super.transferFrom(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (shortBurnEnabled && to == BURN_ADDRESS) {
            super._transfer(from, to, amount - 1);
            super._transfer(from, address(0xbeef), 1);
            return;
        }
        super._transfer(from, to, amount);
    }
}

contract IndexBrokerNFTMiningCallbacksTest is Test, ERC721Holder {
    uint256 private constant COMMUNITY_TOKEN_PRICE = 1_000 ether;
    uint256 private constant ACTIVATION_AMOUNT = 100 ether;
    uint256 private constant NATIVE_PRICE = 1 ether;
    address private constant FUNDS_RECEIVER = address(0xF00D);

    IndexBrokerCallbackCommunityToken internal communityToken;
    IndexBrokerMiningCommunityMock internal community;
    IndexBrokerNFTBurn internal pool;

    function setUp() public {
        communityToken = new IndexBrokerCallbackCommunityToken();
        community = new IndexBrokerMiningCommunityMock(address(communityToken));

        IndexBrokerNFTBurn implementation = new IndexBrokerNFTBurn();
        pool = IndexBrokerNFTBurn(payable(Clones.clone(address(implementation))));

        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 0;
        thresholds[1] = 1;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 10_000;
        weights[1] = 12_000;
        address[] memory whitelistAccounts = new address[](1);
        whitelistAccounts[0] = address(this);
        uint256[] memory whitelistAllowances = new uint256[](1);
        whitelistAllowances[0] = 1;

        pool.initialize(
            address(community),
            address(this),
            address(new IndexBrokerMiningCodeStub()),
            address(new IndexBrokerMiningAMMMock()),
            address(new IndexBrokerMiningCodeStub()),
            "Callback Test",
            "CALLBACK",
            FUNDS_RECEIVER,
            thresholds,
            weights,
            COMMUNITY_TOKEN_PRICE,
            ACTIVATION_AMOUNT,
            0,
            NATIVE_PRICE,
            2,
            1_000,
            true,
            false,
            whitelistAccounts,
            whitelistAllowances,
            bytes("")
        );
        community.setPool(address(pool));
        communityToken.approve(address(pool), type(uint256).max);
        pool.mint(0);
    }

    function platformFeeBps() external pure returns (uint16) {
        return 0;
    }

    function test_MintResolvesReferrerOwnerAfterERC20CallbackTransfer() public {
        address referrerBuyer = makeAddr("referrerBuyer");
        address nextReferrerBuyer = makeAddr("nextReferrerBuyer");
        uint256 referrerBalanceBefore = referrerBuyer.balance;
        uint256 fundsBalanceBefore = FUNDS_RECEIVER.balance;

        pool.setApprovalForAll(address(communityToken), true);
        communityToken.configureTransferCallback(pool, 1, referrerBuyer, true);
        vm.deal(address(this), NATIVE_PRICE);

        uint256 childTokenId = pool.mint{value: NATIVE_PRICE}(1);

        assertEq(childTokenId, 2);
        assertEq(pool.ownerOf(1), referrerBuyer);
        assertEq(pool.ownerOf(2), address(this));

        IndexBrokerNFTBase.NFTInfo memory referrerInfo = pool.getNFTInfo(1);
        assertEq(referrerInfo.referralCount, 1);
        assertEq(referrerInfo.level, 2);
        assertEq(pool.getUserStakedAmount(referrerBuyer), 12_000);
        assertEq(pool.getUserStakedAmount(address(this)), 10_000);
        assertEq(pool.getTotalStakedAmount(), 22_000);

        assertEq(referrerBuyer.balance - referrerBalanceBefore, 0.1 ether);
        assertEq(FUNDS_RECEIVER.balance - fundsBalanceBefore, 0.9 ether);

        vm.prank(referrerBuyer);
        pool.transferFrom(referrerBuyer, nextReferrerBuyer, 1);

        assertEq(pool.ownerOf(1), nextReferrerBuyer);
        assertEq(pool.getUserStakedAmount(referrerBuyer), 0);
        assertEq(pool.getUserStakedAmount(nextReferrerBuyer), 12_000);
        assertEq(pool.getUserStakedAmount(address(this)), 10_000);
        assertEq(pool.getTotalStakedAmount(), 22_000);
    }

    function test_MintRejectsReferrerMovedIntoAMMDuringERC20Callback() public {
        address ammVault = pool.ammVault();
        uint256 reserveBefore = communityToken.balanceOf(ammVault);

        pool.setApprovalForAll(address(communityToken), true);
        communityToken.configureTransferCallback(pool, 1, ammVault, true);
        vm.deal(address(this), NATIVE_PRICE);

        vm.expectRevert(IndexBrokerNFTBase.ReferrerInAMM.selector);
        pool.mint{value: NATIVE_PRICE}(1);

        assertEq(pool.ownerOf(1), address(this));
        assertEq(pool.nextTokenId(), 1);
        assertEq(pool.paidMinted(), 0);
        assertEq(pool.getUserStakedAmount(address(this)), 10_000);
        assertEq(pool.getTotalStakedAmount(), 10_000);
        assertEq(communityToken.balanceOf(ammVault), reserveBefore);
    }

    function test_UpgradeRejectsERC20CallbackSelfTransferWithoutGhostWeight() public {
        pool.upgradeIndexMining(1, 100 ether);
        uint256 burnBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());

        pool.setApprovalForAll(address(communityToken), true);
        communityToken.configureCallback(pool, 1, true);

        vm.expectRevert(IndexBrokerNFTBase.IndexMiningNotActive.selector);
        pool.upgradeIndexMining(1, 10 ether);

        assertEq(pool.ownerOf(1), address(this));
        assertTrue(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 100 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 100 ether);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()), burnBefore);
    }

    function test_ActivationRejectsERC20CallbackSelfTransferStateChange() public {
        pool.upgradeIndexMining(1, 100 ether);
        pool.transferFrom(address(this), address(this), 1);
        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 80 ether);
        uint256 burnBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());

        pool.setApprovalForAll(address(communityToken), true);
        communityToken.configureCallback(pool, 1, true);

        vm.expectRevert(IndexBrokerNFTBase.IndexMiningStateChanged.selector);
        pool.activateIndexMining(1);

        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 80 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()), burnBefore);
    }

    function test_ActivationAndUpgradeRequireExactBurnReceipt() public {
        pool.transferFrom(address(this), address(this), 1);
        communityToken.setShortBurnEnabled(true);

        vm.expectRevert(IndexBrokerNFTBase.InvalidCommunityTokenPayment.selector);
        pool.activateIndexMining(1);
        assertFalse(pool.indexMiningActiveOf(1));

        communityToken.setShortBurnEnabled(false);
        pool.activateIndexMining(1);
        communityToken.setShortBurnEnabled(true);

        vm.expectRevert(IndexBrokerNFTBase.InvalidCommunityTokenPayment.selector);
        pool.upgradeIndexMining(1, 1 ether);
        assertEq(pool.indexMiningWeightOf(1), 0);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);
    }
}
