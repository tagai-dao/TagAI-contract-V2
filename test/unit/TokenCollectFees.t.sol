// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/interfaces/IToken.sol";
import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/pump/IPShare.sol";
import "../../src/pump/Pump.sol";
import "../../src/pump/Token.sol";
import "../../src/hook/TagAISwapHook.sol";
import "../mocks/MockCLPoolManager.sol";
import "../mocks/MockVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenCollectFeesTest
 * @notice Unit tests for Token.collectFees — fee routing via vault.lock collect path.
 */
contract TokenCollectFeesTest is Test {
    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    Pump public pump;
    TagAISwapHook public hook;
    Token public token;

    address public creator;
    address public buyer;
    address public feeRecipient;
    address public claimSigner;

    function setUp() public {
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        vm.deal(creator, 1000 ether);
        vm.deal(buyer, 5000 ether);
        vm.deal(address(this), 1000 ether);

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = _deployCommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(communityFactory);
        scf = _deploySocialCurationFactory(communityFactory, claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);

        mockPoolManager = new MockCLPoolManager();
        mockVault = new MockVault();

        ipshare = new IPShare(feeRecipient);
        pump = new Pump(address(ipshare), feeRecipient);
        pump.adminSetPoolManager(address(mockPoolManager));
        pump.adminSetVault(address(mockVault));

        hook = new TagAISwapHook(ICLPoolManager(address(mockPoolManager)), IVault(address(mockVault)), address(pump));

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));

        vm.deal(address(mockVault), 100 ether);

        vm.warp(3600);

        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("COLLECT", bytes32(uint256(1)));
        token = Token(payable(tokenAddr));
        vm.stopPrank();

        _fillBondingCurve();
        assertTrue(token.listed(), "token must be listed");
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode =
            abi.encodePacked(vm.getCode("CommunityFactory.sol:CommunityFactory"), abi.encode(_committee));
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "CF deploy failed");
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode =
            abi.encodePacked(vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"), abi.encode(_cf, _signer));
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "SCF deploy failed");
        return d;
    }

    function _fillBondingCurve() internal {
        uint256 BONDING_CAP = 650_000_000 ether;
        vm.startPrank(buyer, buyer);
        vm.warp(block.timestamp + 16);
        for (uint256 i = 0; i < 100 && !token.listed(); i++) {
            if (BONDING_CAP - token.bondingCurveSupply() == 0) break;
            try token.buyToken{value: 500 ether}(0, creator, 0) {}
            catch {
                break;
            }
        }
        vm.stopPrank();
    }

    function test_collectFees_revertsWhenNotListed() public {
        Token unlisted = _createUnlistedToken();
        vm.expectRevert(IToken.TokenNotListed.selector);
        unlisted.collectFees();
    }

    function test_collectFees_zeroFees_emitsZeros() public {
        address collector = makeAddr("collector");

        vm.expectEmit(true, false, false, true);
        emit IToken.ListingFeesCollected(collector, 0, 0, 0);

        vm.prank(collector);
        (uint256 bnbAmount, uint256 tokenAmount) = token.collectFees();
        assertEq(bnbAmount, 0);
        assertEq(tokenAmount, 0);
    }

    function test_collectFees_routesBnbToPlatformAndTokenToHook() public {
        uint256 ethFees = 0.5 ether;
        uint256 tokenFees = 10_000 ether;

        mockPoolManager.setMockFees(ethFees, tokenFees);
        vm.deal(address(mockVault), ethFees);
        deal(address(token), address(mockVault), tokenFees);

        address collector = makeAddr("collector");
        address hookAddr = pump.getHookAddress();

        uint256 platformBefore = feeRecipient.balance;
        uint256 collectorBefore = collector.balance;
        uint256 hookTokenBefore = IERC20(address(token)).balanceOf(hookAddr);

        vm.prank(collector);
        (uint256 bnbAmount, uint256 tokenAmount) = token.collectFees();

        assertEq(bnbAmount, ethFees);
        assertEq(tokenAmount, tokenFees);
        uint256 callerReward = ethFees * token.COLLECT_CALLER_REWARD_BPS() / 10_000;
        assertEq(collector.balance - collectorBefore, callerReward);
        assertEq(feeRecipient.balance - platformBefore, ethFees - callerReward);
        assertEq(IERC20(address(token)).balanceOf(hookAddr) - hookTokenBefore, tokenFees);
        assertEq(address(token).balance, 0, "Token should not retain collected BNB");

        vm.prank(collector);
        (uint256 bnb2, uint256 token2) = token.collectFees();
        assertEq(bnb2, 0);
        assertEq(token2, 0);
    }

    function test_collectFees_roundsSubRewardDustToPlatform() public {
        uint256 ethFees = 199;
        mockPoolManager.setMockFees(ethFees, 0);
        vm.deal(address(mockVault), ethFees);

        address collector = makeAddr("dustCollector");
        uint256 platformBefore = feeRecipient.balance;

        vm.prank(collector);
        token.collectFees();

        assertEq(collector.balance, 0);
        assertEq(feeRecipient.balance - platformBefore, ethFees);
        assertEq(address(token).balance, 0);
    }

    function _createUnlistedToken() internal returns (Token) {
        vm.startPrank(creator, creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("UNLIST", bytes32(uint256(2)));
        vm.stopPrank();
        return Token(payable(tokenAddr));
    }
}
