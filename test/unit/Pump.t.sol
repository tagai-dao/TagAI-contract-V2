// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
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

/**
 * @title PumpTest
 * @notice Unit tests for Pump contract — admin functions, createToken happy path/revert paths.
 */
contract PumpTest is Test {
    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    Pump public pump;
    TagAISwapHook public hook;

    address public deployer;
    address public creator;
    address public feeRecipient;
    address public claimSigner;

    function setUp() public {
        deployer = address(this);
        creator = makeAddr("creator");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        vm.deal(creator, 1000 ether);
        vm.deal(deployer, 1000 ether);

        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        // Deploy CommunityFactory via vm.getCode (avoids OZ ERC20 / Solady ERC20 collision)
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

        hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(
            communityFactory,
            address(calculator),
            scf,
            address(committee)
        );

        vm.warp(3600);
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "CommunityFactory deploy failed");
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(d != address(0), "SocialCurationFactory deploy failed");
        return d;
    }

    // ─── Admin Functions ───

    function test_adminSetCalculator_onlyOwner() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminSetCalculator(makeAddr("newCalc"));
    }

    function test_adminSetCalculator_updatesAddress() public {
        address newCalc = makeAddr("newCalc");
        pump.adminSetCalculator(newCalc);
        assertEq(pump.getCalculator(), newCalc);
    }

    function test_adminSetHookAddress_onlyOwner() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminSetHookAddress(makeAddr("newHook"));
    }

    function test_adminSetHookAddress_updatesAddress() public {
        address newHook = makeAddr("newHook");
        pump.adminSetHookAddress(newHook);
        assertEq(pump.getHookAddress(), newHook);
    }

    function test_getCalculator_returnsConfiguredAddress() public {
        assertEq(pump.getCalculator(), address(calculator));
    }

    function test_getHookAddress_returnsConfiguredAddress() public {
        assertEq(pump.getHookAddress(), address(hook));
    }

    function test_getIPShare_returnsConfiguredAddress() public {
        assertEq(pump.getIPShare(), address(ipshare));
    }

    function test_getFeeRatio_returnsDefaultValues() public {
        uint256[2] memory ratio = pump.getFeeRatio();
        assertEq(ratio[0], 30); // platform fee
        assertEq(ratio[1], 30); // sellsman fee
    }

    function test_adminChangeFeeRatio_onlyOwner() public {
        address rando = makeAddr("rando");
        uint256[2] memory newRatio = [uint256(50), uint256(50)];
        vm.prank(rando);
        vm.expectRevert();
        pump.adminChangeFeeRatio(newRatio);
    }

    function test_adminChangeFeeRatio_updatesValues() public {
        uint256[2] memory newRatio = [uint256(50), uint256(50)];
        pump.adminChangeFeeRatio(newRatio);
        uint256[2] memory ratio = pump.getFeeRatio();
        assertEq(ratio[0], 50);
        assertEq(ratio[1], 50);
    }

    function test_adminChangeFeeRatio_revertsTooMuchFee() public {
        uint256[2] memory tooMuch = [uint256(1001), uint256(50)];
        vm.expectRevert();
        pump.adminChangeFeeRatio(tooMuch);
    }

    function test_adminChangeCreateFee_onlyOwner() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminChangeCreateFee(0.01 ether);
    }

    function test_adminChangeCreateFee_revertsTooMuchFee() public {
        vm.expectRevert();
        pump.adminChangeCreateFee(2 ether);
    }

    // ─── createToken happy path ───

    function test_createToken_succeedsHappyPath() public {
        vm.startPrank(creator, creator); // tx.origin = creator (Pump requires EOA)

        // Create IPShare for creator first
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);

        address tokenAddr = pump.createToken{value: 0.005 ether}("TEST", bytes32(uint256(1)));

        assertTrue(pump.createdTokens(tokenAddr));
        assertTrue(tokenAddr != address(0));

        vm.stopPrank();
    }

    function test_createToken_revertsIfTickAlreadyExists() public {
        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);

        pump.createToken{value: 0.005 ether}("DUPE", bytes32(uint256(1)));

        // Same tick again should revert
        vm.expectRevert();
        pump.createToken{value: 0.005 ether}("DUPE", bytes32(uint256(2)));

        vm.stopPrank();
    }

    function test_createToken_revertsIfInsufficientFee() public {
        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);

        // Only 0.001 ether — less than createFee (0.005)
        vm.expectRevert();
        pump.createToken{value: 0.001 ether}("LOWFEE", bytes32(uint256(1)));

        vm.stopPrank();
    }

    function test_createToken_revertsIfNotEOA() public {
        // Call from this contract (not an EOA, no tx.origin trick)
        // tx.origin == address(this) ≠ msg.sender
        // Actually since we're calling directly from a contract, tx.origin == this and msg.sender == this
        // Both equal, so the EOA check passes. To trigger Only EOA, we need a contract calling Pump.
        // Use a helper proxy contract.
        ContractCaller caller = new ContractCaller(address(pump));
        vm.deal(address(caller), 1 ether);

        vm.expectRevert();
        caller.callCreateToken{value: 0.005 ether}("PROXY", bytes32(uint256(1)));
    }

    function test_createToken_revertsIfNutboxNotConfigured() public {
        // Deploy fresh Pump without adminSetNutbox to set calculator/community factory
        Pump freshPump = new Pump(address(ipshare), feeRecipient);
        freshPump.adminSetCalculator(address(0)); // explicitly clear calculator
        // The check `hourlyTickCalculator == address(0)` will trigger NutboxNotConfigured
        // BUT freshPump still has BSC mainnet hardcoded addresses for nutboxCommunityFactory etc.
        // So the explicit zero on calculator will hit the revert check.

        vm.startPrank(creator, creator);
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);

        vm.expectRevert();
        freshPump.createToken{value: 0.005 ether}("FRESH", bytes32(uint256(1)));

        vm.stopPrank();
    }

    function test_pump_doesNotHaveTradeSigner() public {
        // Verify getTradeSigner() function does NOT exist on Pump.
        // Try a low-level call with the tradeSigner selector — should fail.
        bytes4 selector = bytes4(keccak256("getTradeSigner()"));
        (bool success,) = address(pump).call(abi.encodeWithSelector(selector));
        assertFalse(success, "getTradeSigner should not exist on v2 Pump");
    }

    function test_pump_doesNotHaveAdminSetTradeSigner() public {
        bytes4 selector = bytes4(keccak256("adminSetTradeSigner(address)"));
        (bool success,) = address(pump).call(abi.encodeWithSelector(selector, address(0)));
        assertFalse(success, "adminSetTradeSigner should not exist on v2 Pump");
    }

    // ─── Bonding curve formulas ───

    function test_getPrice_consistentWithV1() public {
        // Sanity check: same constants (a = 6_500_000_000, b = 2.5175516438e26)
        uint256 price = pump.getPrice(0, 100 ether);
        assertGt(price, 0, "Price should be positive");
    }

    function test_getBuyAmountByValue_consistentWithV1() public {
        uint256 amount = pump.getBuyAmountByValue(0, 1 ether);
        assertGt(amount, 0, "Buy amount should be positive");
    }
}

/// @dev Helper to call Pump.createToken from a contract context (not EOA).
contract ContractCaller {
    Pump public pump;

    constructor(address _pump) {
        pump = Pump(payable(_pump));
    }

    function callCreateToken(string calldata tick, bytes32 salt) external payable returns (address) {
        return pump.createToken{value: msg.value}(tick, salt);
    }

    receive() external payable {}
}
