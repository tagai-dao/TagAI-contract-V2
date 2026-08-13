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

    IndexBrokerNFT public callbackPool;
    uint256 public callbackTokenId;
    bool public callbackEnabled;
    bool public shortBurnEnabled;

    constructor() ERC20("Callback Community", "CALLBACK") {
        _mint(msg.sender, 10_000_000 ether);
    }

    function configureCallback(IndexBrokerNFT pool_, uint256 tokenId_, bool enabled_) external {
        callbackPool = pool_;
        callbackTokenId = tokenId_;
        callbackEnabled = enabled_;
    }

    function setShortBurnEnabled(bool enabled) external {
        shortBurnEnabled = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callbackEnabled) {
            callbackEnabled = false;
            callbackPool.transferFrom(from, from, callbackTokenId);
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

    IndexBrokerCallbackCommunityToken internal communityToken;
    IndexBrokerMiningCommunityMock internal community;
    IndexBrokerNFT internal pool;

    function setUp() public {
        communityToken = new IndexBrokerCallbackCommunityToken();
        community = new IndexBrokerMiningCommunityMock(address(communityToken));

        IndexBrokerNFT implementation = new IndexBrokerNFT();
        pool = IndexBrokerNFT(payable(Clones.clone(address(implementation))));

        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
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
            address(this),
            thresholds,
            weights,
            COMMUNITY_TOKEN_PRICE,
            ACTIVATION_AMOUNT,
            0,
            0,
            1,
            0,
            true,
            false,
            whitelistAccounts,
            whitelistAllowances
        );
        community.setPool(address(pool));
        communityToken.approve(address(pool), type(uint256).max);
        pool.mint(0);
    }

    function test_UpgradeRejectsERC20CallbackSelfTransferWithoutGhostWeight() public {
        pool.upgradeIndexMining(1, 100 ether);
        uint256 burnBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());

        pool.setApprovalForAll(address(communityToken), true);
        communityToken.configureCallback(pool, 1, true);

        vm.expectRevert(IndexBrokerNFT.IndexMiningNotActive.selector);
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

        vm.expectRevert(IndexBrokerNFT.IndexMiningStateChanged.selector);
        pool.activateIndexMining(1);

        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 80 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()), burnBefore);
    }

    function test_ActivationAndUpgradeRequireExactBurnReceipt() public {
        pool.transferFrom(address(this), address(this), 1);
        communityToken.setShortBurnEnabled(true);

        vm.expectRevert(IndexBrokerNFT.InvalidCommunityTokenPayment.selector);
        pool.activateIndexMining(1);
        assertFalse(pool.indexMiningActiveOf(1));

        communityToken.setShortBurnEnabled(false);
        pool.activateIndexMining(1);
        communityToken.setShortBurnEnabled(true);

        vm.expectRevert(IndexBrokerNFT.InvalidCommunityTokenPayment.selector);
        pool.upgradeIndexMining(1, 1 ether);
        assertEq(pool.indexMiningWeightOf(1), 0);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);
    }
}
