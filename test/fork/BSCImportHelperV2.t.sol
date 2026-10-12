// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../../src/helper/ImportHelperV2.sol";
import "../../src/helper/ImportedTokenSwapWrapper.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";

contract BSCImportHelperV2Test is Test {
    function test_tradeOnlyImportAndBuyAccrueRewardsUsingExistingBSCInfrastructure() public {
        if (block.chainid != 56) {
            vm.skip(true);
            return;
        }
        ImportHelper old = ImportHelper(payable(0xcCB0f9a9db22cCC29fDd315180F89747118ec296));
        ImportedTokenSwapWrapper wrapper = ImportedTokenSwapWrapper(payable(address(old.swapWrapper())));
        address token = 0xe614E2fc6C787035FF51f452e8E826Bfd32D5283; // INTCB: no community at the pinned test block.
        (bool imported,,) = wrapper.getImportedMarket(token);
        assertFalse(imported);
        address tradeFactory = 0x774A48Ba391a1013Ae43289eBdf871618822CD67;
        ImportHelperV2 helper = new ImportHelperV2(
            old.communityFactory(), tradeFactory, old.committee(), old.hourlyTickCalculator(), address(wrapper)
        );
        assertEq(helper.owner(), wrapper.owner());
        vm.prank(wrapper.owner());
        wrapper.setRegistrar(address(helper));
        address user = makeAddr("importer");
        vm.deal(user, 1 ether);
        uint256 fees =
            ICommittee(old.committee()).getCreateCommunityFee() + ICommittee(old.committee()).getCommunitySettingsFee();
        vm.prank(user);
        (address community, address pool) = helper.createCommunityAndPool{value: fees}(token, address(0));
        assertEq(Community(payable(community)).owner(), user);
        assertEq(TradeCuration(payable(pool)).factory(), tradeFactory);
        assertTrue(TradeCurationFactory(tradeFactory).createdPoolOfCommunity(community));
        assertFalse(SocialCurationFactory(old.socialCurationFactory()).createdPoolOfCommunity(community));
        assertEq(uint256(vm.load(community, keccak256(abi.encode(pool, uint256(10))))), 10_000);
        vm.expectRevert();
        Community(payable(community)).activedPools(1);

        ImportedTokenSwapWrapper.V3Source memory source = ImportedTokenSwapWrapper.V3Source(
            0x13f4EA83D0bd40E75C8222255bc855a974568Dd4,
            0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997,
            0x4dD8e7C67033Ef4A745bB9f82a7C57c676eB2481
        );
        vm.prank(user);
        uint256 received = wrapper.buyToken{value: 0.01 ether}(
            token, INutboxRouter.SourceType.V3_POOL, abi.encode(source), 1, user, block.timestamp + 300, address(0)
        );
        assertGt(received, 0);
        assertEq(IERC20(token).balanceOf(user), received);
        assertGt(wrapper.pendingNutboxInjection(token), 0);
    }

    function test_mixedSelectionUsesExistingBSCFactoriesAndFinalRatios() public {
        if (block.chainid != 56) {
            vm.skip(true);
            return;
        }
        ImportHelper old = ImportHelper(payable(0xcCB0f9a9db22cCC29fDd315180F89747118ec296));
        ImportedTokenSwapWrapper wrapper = ImportedTokenSwapWrapper(payable(address(old.swapWrapper())));
        address token = 0xe614E2fc6C787035FF51f452e8E826Bfd32D5283;
        address tradeFactory = 0x774A48Ba391a1013Ae43289eBdf871618822CD67;
        ImportHelperV2 helper = new ImportHelperV2(
            old.communityFactory(), tradeFactory, old.committee(), old.hourlyTickCalculator(), address(wrapper)
        );
        vm.prank(wrapper.owner());
        wrapper.setRegistrar(address(helper));
        address socialFactory = old.socialCurationFactory();
        vm.prank(helper.owner());
        helper.adminSetPoolFactory(socialFactory, "Social Curation", 10_000, true);
        ImportHelperV2.PoolConfig[] memory configs = new ImportHelperV2.PoolConfig[](2);
        configs[0] = ImportHelperV2.PoolConfig(tradeFactory, 7000, bytes(""));
        configs[1] = ImportHelperV2.PoolConfig(old.socialCurationFactory(), 3000, bytes(""));
        address user = makeAddr("mixedImporter");
        vm.deal(user, 1 ether);
        uint256 fees = ICommittee(old.committee()).getCreateCommunityFee() + 2
            * ICommittee(old.committee()).getCommunitySettingsFee();
        vm.prank(user);
        (address c, address[] memory pools) = helper.createCommunityAndPools{value: fees}(token, configs);
        assertEq(pools.length, 2);
        assertEq(Community(payable(c)).owner(), user);
        assertTrue(TradeCurationFactory(tradeFactory).createdPoolOfCommunity(c));
        assertTrue(SocialCurationFactory(old.socialCurationFactory()).createdPoolOfCommunity(c));
        assertEq(uint256(vm.load(c, keccak256(abi.encode(pools[0], uint256(10))))), 7000);
        assertEq(uint256(vm.load(c, keccak256(abi.encode(pools[1], uint256(10))))), 3000);
        (bool imported, address registeredCommunity, address creator) = wrapper.getImportedMarket(token);
        assertTrue(imported);
        assertEq(registeredCommunity, c);
        assertEq(creator, user);
    }
}
