// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../script/DeployRHImportHelperV2.s.sol";
import "../../src/helper/ImportHelper.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import "../../src/interfaces/IIPShare.sol";

contract RHImportV2Token is ERC20 {
    constructor() ERC20("RH import fixture", "RHIV2") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Only a local fork is mutated. No mainnet transaction or production key is used.
contract RHImportHelperV2ForkTest is Test, DeployRHImportHelperV2 {
    uint256 private constant SIGNER_KEY = 0xABC123;
    uint256 private constant PINNED_BLOCK = 86_435_919;
    address private constant SOCIAL_FACTORY = 0xddbAba530728b5B8939d7fdDC334432490916e90;
    address private constant IPSHARE = 0x8A7b0d80FA92699CE3e5bB2c8fE404D6733796d1;
    ImportHelperV2 private helper;
    ImportedTokenSwapWrapper private wrapper;
    address private admin;
    address private creator;

    function setUp() public {
        if (!vm.envOr("RUN_RH_IMPORT_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(
            vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")),
            vm.envOr("RH_IMPORT_FORK_BLOCK", PINNED_BLOCK)
        );
        require(block.chainid == 4663, "Wrong fork chain");
        admin = preflight();
        wrapper = ImportedTokenSwapWrapper(payable(WRAPPER));
        helper = new ImportHelperV2(COMMUNITY_FACTORY, TRADE_FACTORY, COMMITTEE, CALCULATOR, WRAPPER);
        creator = makeAddr("rh-v2-importer");
        vm.deal(creator, 10 ether);
    }

    function _activate() private {
        vm.prank(admin);
        wrapper.setRegistrar(address(helper));
    }

    function _fee(uint256 count) private view returns (uint256) {
        return ICommittee(COMMITTEE).getCreateCommunityFee() + count * ICommittee(COMMITTEE).getCommunitySettingsFee();
    }

    function _ratio(address c, address pool) private view returns (uint256) {
        // Deployed RH Community predates the public getter; preserve its proven storage layout.
        return uint256(vm.load(c, keccak256(abi.encode(pool, uint256(10)))));
    }

    function test_preflightPinsExactMulticallChildrenAndRejectsAChangedRegistrar() public {
        IRHImportMulticall.Call3[] memory calls = new IRHImportMulticall.Call3[](9);
        calls[0] = IRHImportMulticall.Call3(WRAPPER, false, abi.encodeWithSignature("owner()"));
        calls[1] = IRHImportMulticall.Call3(WRAPPER, false, abi.encodeWithSignature("registrar()"));
        calls[2] = IRHImportMulticall.Call3(WRAPPER, false, abi.encodeWithSignature("wrappedNative()"));
        calls[3] = IRHImportMulticall.Call3(OLD_HELPER, false, abi.encodeWithSignature("swapWrapper()"));
        calls[4] = IRHImportMulticall.Call3(TRADE_FACTORY, false, abi.encodeWithSignature("communityFactory()"));
        calls[5] = IRHImportMulticall.Call3(TRADE_FACTORY, false, abi.encodeWithSignature("claimSigner()"));
        calls[6] = IRHImportMulticall.Call3(CALCULATOR, false, abi.encodeWithSignature("communityFactory()"));
        calls[7] = IRHImportMulticall.Call3(
            COMMITTEE, false, abi.encodeWithSignature("verifyContract(address)", TRADE_FACTORY)
        );
        calls[8] =
            IRHImportMulticall.Call3(COMMITTEE, false, abi.encodeWithSignature("verifyContract(address)", CALCULATOR));
        vm.expectCall(MULTICALL, abi.encodeCall(IRHImportMulticall.aggregate3, (calls)));
        assertEq(preflight(), admin);
        _activate();
        vm.expectRevert("Registrar already changed");
        this.preflight();
    }

    function test_defaultImportUsesRealRHFactoriesWithoutCreatingIPShareAndClaimsAccruedRewards() public {
        _activate();
        RHImportV2Token token = new RHImportV2Token();
        assertFalse(IIPShare(IPSHARE).ipshareCreated(creator));
        uint256 beforeBalance = creator.balance;
        uint256 fee = _fee(1);
        vm.prank(creator);
        (address c, address poolAddress) =
            helper.createCommunityAndPool{value: fee + 1 ether}(address(token), address(0));
        assertEq(beforeBalance - creator.balance, _fee(1));
        assertFalse(IIPShare(IPSHARE).ipshareCreated(creator));
        assertEq(Community(payable(c)).owner(), creator);
        assertEq(Community(payable(c)).rewardCalculator(), CALCULATOR);
        assertEq(Community(payable(c)).getCommunityToken(), address(token));
        assertEq(_ratio(c, poolAddress), 10_000);
        assertTrue(TradeCurationFactory(TRADE_FACTORY).createdPoolOfCommunity(c));
        assertFalse(SocialCurationFactory(SOCIAL_FACTORY).createdPoolOfCommunity(c));
        (bool registered, address storedCommunity, address importer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(storedCommunity, c);
        assertEq(importer, creator);
        assertEq(helper.owner(), admin);

        // Exercise actual deployed calculator -> Community -> TradeCuration -> user accounting.
        token.approve(CALCULATOR, 168_000 ether);
        HourlyTickCalculator(CALCULATOR).inject(c, 168_000 ether);
        vm.warp(block.timestamp + 168 hours);
        vm.prank(TradeCurationFactory(TRADE_FACTORY).owner());
        TradeCurationFactory(TRADE_FACTORY).adminSetClaimSigner(vm.addr(SIGNER_KEY));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nutbox TradeCuration"),
                keccak256("1"),
                uint256(4663),
                poolAddress
            )
        );
        bytes32 claim = keccak256(
            abi.encode(
                keccak256(
                    "Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)"
                ),
                uint256(4663),
                poolAddress,
                uint256(1),
                uint256(100 ether),
                creator,
                block.timestamp
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, keccak256(abi.encodePacked("\x19\x01", domain, claim)));
        uint256 claimFee = ICommittee(COMMITTEE).getPoolOperationFee();
        vm.prank(creator);
        TradeCuration(payable(poolAddress)).claim{value: claimFee}(
            1, 100 ether, block.timestamp, abi.encodePacked(r, s, v)
        );
        assertEq(token.balanceOf(creator), 100 ether);
        assertTrue(TradeCuration(payable(poolAddress)).claimedOrders(creator, 1));
    }

    function test_ownerConfiguresRealSocialAndTradePoolsAndDefaultEntryChargesTwoSettings() public {
        _activate();
        vm.startPrank(admin);
        helper.adminSetPoolFactory(SOCIAL_FACTORY, "Social Curation", 10_000, true);
        ImportHelperV2.PoolConfig[] memory configs = new ImportHelperV2.PoolConfig[](2);
        configs[0] = ImportHelperV2.PoolConfig(TRADE_FACTORY, 7000, bytes(""));
        configs[1] = ImportHelperV2.PoolConfig(SOCIAL_FACTORY, 3000, bytes(""));
        helper.adminSetDefaultPools(configs);
        vm.stopPrank();
        RHImportV2Token token = new RHImportV2Token();
        uint256 beforeBalance = creator.balance;
        uint256 fee = _fee(2);
        vm.prank(creator);
        (address c, address primary) = helper.createCommunityAndPool{value: fee + 1}(address(token), address(0));
        address secondary = Community(payable(c)).activedPools(1);
        assertEq(beforeBalance - creator.balance, _fee(2));
        assertEq(_ratio(c, primary), 7000);
        assertEq(_ratio(c, secondary), 3000);
        assertEq(TradeCuration(payable(primary)).factory(), TRADE_FACTORY);
        assertEq(SocialCuration(payable(secondary)).factory(), SOCIAL_FACTORY);
        assertEq(Community(payable(c)).owner(), creator);
        assertTrue(TradeCurationFactory(TRADE_FACTORY).createdPoolOfCommunity(c));
        assertTrue(SocialCurationFactory(SOCIAL_FACTORY).createdPoolOfCommunity(c));
    }

    function test_registrarSwitchPreservesLegacyImportAndRejectsReimport() public {
        RHImportV2Token token = new RHImportV2Token();
        uint256 legacyFee = _fee(1) + IIPShare(IPSHARE).createFee();
        vm.prank(creator);
        (address c, address pool) =
            ImportHelper(payable(OLD_HELPER)).createCommunityAndPool{value: legacyFee}(address(token), CALCULATOR, "");
        assertTrue(IIPShare(IPSHARE).ipshareCreated(creator));
        _activate();
        uint256 fee = _fee(1);
        vm.prank(creator);
        vm.expectRevert(ImportHelperV2.TokenAlreadyImported.selector);
        helper.createCommunityAndPool{value: fee}(address(token), address(0));
        (bool registered, address storedCommunity, address importer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(storedCommunity, c);
        assertEq(importer, creator);
        assertEq(Community(payable(c)).activedPools(0), pool);
        assertEq(SocialCuration(payable(pool)).factory(), SOCIAL_FACTORY);
        assertEq(ImportHelper(payable(OLD_HELPER)).importerOf(address(token)), creator);
    }
}
