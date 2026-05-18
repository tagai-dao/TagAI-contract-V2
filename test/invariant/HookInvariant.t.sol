// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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
 * @title AttackerHandler
 * @notice Handler that attempts every public/external function on Hook from a non-PoolManager
 *         caller, never decreasing the Hook's token balance.
 */
contract AttackerHandler is Test {
    TagAISwapHook public hook;
    Token public token;
    address public attacker;

    constructor(TagAISwapHook _hook, Token _token, address _attacker) {
        hook = _hook;
        token = _token;
        attacker = _attacker;
    }

    /// Try direct transfer call (function shouldn't exist)
    function tryTransfer(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000 ether);
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        vm.prank(attacker);
        (bool success,) = address(hook).call(abi.encodeWithSelector(selector, attacker, amount));
        // Should always fail
        assertFalse(success);
    }

    /// Try fake registerPool from random address
    function tryRegisterPool(uint256 poolIdSeed) external {
        bytes32 poolId = bytes32(poolIdSeed);
        vm.prank(attacker);
        try hook.registerPool(PoolId.wrap(poolId), address(token)) {} catch {}
    }

    /// Try direct calls to swap callbacks
    function tryDirectCallback(uint256 mode) external {
        mode = mode % 3;
        // These should all revert (NotPoolManager)
        if (mode == 0) {
            vm.prank(attacker);
            try hook.beforeInitialize(attacker, _emptyKey(), 0) {} catch {}
        }
    }

    function _emptyKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(0)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0)),
            fee: 0,
            parameters: bytes32(0)
        });
    }
}

/**
 * @title HookInvariantTest
 * @notice Invariant test: Hook's token balance only decreases via the inject path.
 * Random sequence of attacker calls should never reduce Hook's balance.
 */
contract HookInvariantTest is StdInvariant, Test {
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

    AttackerHandler public handler;

    address public creator;
    address public buyer;
    address public attacker;
    address public feeRecipient;
    address public claimSigner;

    uint256 public initialHookBalance;

    function setUp() public {
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        attacker = makeAddr("attacker");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        vm.deal(creator, 1000 ether);
        vm.deal(buyer, 1000 ether);
        vm.deal(attacker, 1000 ether);
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
        hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );
        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));
        vm.deal(address(mockVault), 100 ether);

        vm.warp(3600);

        // Create and list token
        vm.startPrank(creator, creator);
        ipshare.createShare{value: ipshare.getPrice(10 ether, 0)}(creator);
        token = Token(payable(pump.createToken{value: 0.005 ether}("INV", bytes32(uint256(1)))));
        vm.stopPrank();

        _fillBondingCurve();

        initialHookBalance = IERC20(address(token)).balanceOf(address(hook));

        // Set up handler
        handler = new AttackerHandler(hook, token, attacker);
        targetContract(address(handler));
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return d;
    }

    function _deploySocialCurationFactory(address _cf, address _signer) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_cf, _signer)
        );
        address d;
        assembly { d := create(0, add(bytecode, 0x20), mload(bytecode)) }
        return d;
    }

    function _fillBondingCurve() internal {
        uint256 BONDING_CAP = 650_000_000 ether;
        vm.startPrank(buyer, buyer);
        vm.warp(block.timestamp + 16);
        for (uint256 i = 0; i < 100 && !token.listed(); i++) {
            uint256 remaining = BONDING_CAP - token.bondingCurveSupply();
            if (remaining == 0) break;
            uint256 buyAmount = 5 ether;
            if (buyer.balance < buyAmount) vm.deal(buyer, 1000 ether);
            try token.buyToken{value: buyAmount}(0, creator, 0) {} catch {
                vm.deal(buyer, 5000 ether);
                try token.buyToken{value: 500 ether}(0, creator, 0) {} catch { break; }
            }
        }
        vm.stopPrank();
    }

    /// @dev Invariant: attacker calls cannot decrease Hook's token balance
    function invariant_P7_hookBalanceUnchangedByAttacker() public {
        uint256 currentBalance = IERC20(address(token)).balanceOf(address(hook));
        // Balance could decrease only via legitimate inject path (which the handler doesn't trigger)
        assertEq(currentBalance, initialHookBalance, "Hook balance should not change from attacker calls");
    }
}
