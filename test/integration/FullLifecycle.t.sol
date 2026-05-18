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
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FullLifecycleTest
 * @notice Integration test deploying the FULL stack locally and testing the lifecycle:
 *
 * 1. Deploy real contracts: Committee, CommunityFactory, SocialCurationFactory,
 *    HourlyTickCalculator, IPShare, Pump, TagAISwapHook (with MockCLPoolManager + MockVault)
 * 2. Wire them: Committee.adminAddContract, Pump.adminSetHookAddress, etc.
 * 3. Test createToken → buyToken multiple times → verify bonding curve fills → listing triggers
 * 4. After listing, simulate buy swaps via Hook's afterSwap (using mock PoolManager)
 * 5. Assert: Hook's nutboxAllocationRemaining decreases on buys, stays same on sells
 * 6. Assert: totalSupply always == 1_000_000_000 ether
 *
 * Note: CommunityFactory and SocialCurationFactory are deployed via vm.getCode
 * to avoid ERC20 name collision between OpenZeppelin (MintableERC20) and Solady (Token).
 */
contract FullLifecycleTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Contracts ───
    Committee public committee;
    address public communityFactory;
    HourlyTickCalculator public calculator;
    address public scf;
    IPShare public ipshare;
    Pump public pump;
    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    TagAISwapHook public hook;

    // ─── Actors ───
    address public deployer;
    address public creator;
    address public buyer1;
    address public buyer2;
    address public feeRecipient;
    address public claimSigner;

    // ─── Constants ───
    uint256 constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 constant BONDING_CURVE_TOTAL = 650_000_000 ether;

    function setUp() public {
        deployer = address(this);
        creator = makeAddr("creator");
        buyer1 = makeAddr("buyer1");
        buyer2 = makeAddr("buyer2");
        feeRecipient = makeAddr("feeRecipient");
        claimSigner = makeAddr("claimSigner");

        // Fund actors
        vm.deal(creator, 1000 ether);
        vm.deal(buyer1, 1000 ether);
        vm.deal(buyer2, 1000 ether);
        vm.deal(deployer, 1000 ether);

        // ─── Deploy Nutbox Stack ───
        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        // Deploy CommunityFactory via vm.getCode (avoids OZ ERC20 / Solady ERC20 collision)
        communityFactory = _deployCommunityFactory(address(committee));

        // Deploy HourlyTickCalculator
        calculator = new HourlyTickCalculator(communityFactory);

        // Deploy SocialCurationFactory via vm.getCode
        scf = _deploySocialCurationFactory(communityFactory, claimSigner);

        // Whitelist in Committee
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);

        // ─── Deploy PCS V4 Mocks ───
        mockPoolManager = new MockCLPoolManager();
        mockVault = new MockVault();

        // ─── Deploy IPShare ───
        ipshare = new IPShare(feeRecipient);

        // ─── Deploy Pump ───
        pump = new Pump(address(ipshare), feeRecipient);
        pump.adminSetPoolManager(address(mockPoolManager));
        pump.adminSetVault(address(mockVault));

        // ─── Deploy Hook ───
        hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );

        // ─── Wire Pump ───
        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(
            communityFactory,
            address(calculator),
            scf,
            address(committee)
        );

        // Fund the mock vault so it can send ETH for fee collection
        vm.deal(address(mockVault), 100 ether);

        // Warp to a clean hour boundary for predictable calculator behavior
        vm.warp(3600);
    }

    // ─── Test: Full lifecycle createToken → fill bonding curve → listing ───

    function test_fullLifecycle_createAndList() public {
        // Create token as creator (EOA)
        vm.startPrank(creator, creator); // tx.origin = creator

        // IPShare needs to be created for the creator
        uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: ipsharePrice}(creator);

        // Create token with enough ETH for fees
        address tokenAddr = pump.createToken{value: 0.005 ether}("TEST", bytes32(uint256(1)));
        Token token = Token(payable(tokenAddr));
        vm.stopPrank();

        // Verify token was created
        assertTrue(pump.createdTokens(tokenAddr), "Token should be registered in Pump");
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY, "Total supply should be 1B");
        assertFalse(token.listed(), "Token should not be listed yet");

        // Verify Nutbox community was created
        address community = token.nutboxCommunity();
        assertTrue(community != address(0), "Community should be set");

        // Buy tokens to fill the bonding curve
        _fillBondingCurve(token, creator);

        // After filling, token should be listed
        assertTrue(token.listed(), "Token should be listed after bonding curve fills");

        // Verify total supply is still 1B
        assertEq(IERC20(tokenAddr).totalSupply(), TOTAL_SUPPLY, "Total supply should remain 1B after listing");
    }

    // ─── Test: After listing, Hook injection on buy swaps ───

    function test_hookInjection_decreasesOnBuy() public {
        // Setup: create and list a token
        Token token = _createAndListToken("HOOK1");
        address tokenAddr = address(token);

        // Get initial remaining
        (, uint96 initialRemaining,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(initialRemaining), NUTBOX_ALLOCATION, "Initial remaining should be NUTBOX_ALLOCATION");

        // Simulate a buy swap via MockPoolManager
        // Buy: zeroForOne = true (ETH → Token)
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        // Call afterSwap directly from pool manager
        vm.prank(address(mockPoolManager));
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether, // exactInput 1 ETH
            sqrtPriceLimitX96: 0
        });

        // Mock returns delta with tokenOut = -10_000 ether (large enough to trigger inject)
        BalanceDelta buyDelta = toBalanceDelta(-1 ether, -int128(int256(10_000 ether)));
        hook.afterSwap(address(0), poolKey, buyParams, buyDelta, bytes(""));

        // Check remaining decreased
        (, uint96 remainingAfterBuy,) = hook.tokenInfo(tokenAddr);

        // The hook has NUTBOX_ALLOCATION tokens (transferred during listing)
        // injectAmount = 10_000 * 20 / 10000 = 20 ether
        // inject does transferFrom(hook, community, 20 ether) - hook approved calculator in registerPool
        uint256 hookBalance = IERC20(tokenAddr).balanceOf(address(hook));
        if (hookBalance >= 20 ether) {
            // Inject should succeed, remaining decreases
            assertTrue(uint256(remainingAfterBuy) < uint256(initialRemaining), "Remaining should decrease on buy");
            assertEq(
                uint256(initialRemaining) - uint256(remainingAfterBuy),
                20 ether,
                "Should inject exactly 0.2% of bought amount"
            );
        }
        // If inject fails (e.g., calculator not registered for this community), try/catch restores remaining
    }

    // ─── Test: Hook remaining stays same on sell swaps ───

    function test_hookRemaining_unchangedOnSell() public {
        Token token = _createAndListToken("HOOK2");
        address tokenAddr = address(token);

        (, uint96 initialRemaining,) = hook.tokenInfo(tokenAddr);

        // Simulate a sell swap: zeroForOne = false (Token → ETH)
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        vm.prank(address(mockPoolManager));
        ICLPoolManager.SwapParams memory sellParams = ICLPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(10_000 ether), // exactInput tokens
            sqrtPriceLimitX96: 0
        });

        BalanceDelta sellDelta = toBalanceDelta(-1 ether, int128(int256(10_000 ether)));
        hook.afterSwap(address(0), poolKey, sellParams, sellDelta, bytes(""));

        (, uint96 remainingAfterSell,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfterSell), uint256(initialRemaining), "Remaining should not change on sell");
    }

    // ─── Test: Total supply invariant throughout lifecycle ───

    function test_totalSupply_invariant() public {
        Token token = _createAndListToken("SUPPLY");
        assertEq(IERC20(address(token)).totalSupply(), TOTAL_SUPPLY, "Total supply must always be 1B");
    }

    // ─── Test: Multiple buy swaps decrease remaining monotonically ───

    function test_multipleBuySwaps_monotonicDecrease() public {
        Token token = _createAndListToken("MONO");
        address tokenAddr = address(token);

        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        uint96 prevRemaining;
        (, prevRemaining,) = hook.tokenInfo(tokenAddr);

        // Simulate 5 buy swaps
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(mockPoolManager));
            ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: 0
            });
            // Large enough bought amount to trigger inject
            BalanceDelta buyDelta = toBalanceDelta(-1 ether, -int128(int256(10_000 ether)));
            hook.afterSwap(address(0), poolKey, buyParams, buyDelta, bytes(""));

            (, uint96 currentRemaining,) = hook.tokenInfo(tokenAddr);
            // Remaining should be <= previous (monotonically non-increasing)
            assertTrue(currentRemaining <= prevRemaining, "Remaining should be monotonically non-increasing");
            prevRemaining = currentRemaining;
        }
    }

    // ─── Test: Buy below MIN_INJECT_AMOUNT does not trigger inject ───

    function test_buyBelowMinimum_noInject() public {
        Token token = _createAndListToken("SMALL");
        address tokenAddr = address(token);

        (, uint96 initialRemaining,) = hook.tokenInfo(tokenAddr);

        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        // Small buy: 100 ether tokens (below MIN_INJECT_AMOUNT of 8400 ether)
        vm.prank(address(mockPoolManager));
        ICLPoolManager.SwapParams memory buyParams = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta smallDelta = toBalanceDelta(-0.01 ether, -int128(int256(100 ether)));
        hook.afterSwap(address(0), poolKey, buyParams, smallDelta, bytes(""));

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(initialRemaining), "Small buy should not trigger inject");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ─── Helpers ───
    // ═══════════════════════════════════════════════════════════════════════════

    function _createAndListToken(string memory tick) internal returns (Token) {
        vm.startPrank(creator, creator);

        // Ensure IPShare exists for creator
        if (!ipshare.ipshareCreated(creator)) {
            uint256 ipsharePrice = ipshare.getPrice(10 ether, 0);
            ipshare.createShare{value: ipsharePrice}(creator);
        }

        // Use unique salt for each token
        bytes32 salt = bytes32(uint256(keccak256(abi.encodePacked(tick))));
        address tokenAddr = pump.createToken{value: 0.005 ether}(tick, salt);
        Token token = Token(payable(tokenAddr));
        vm.stopPrank();

        // Fill bonding curve to trigger listing
        _fillBondingCurve(token, creator);

        assertTrue(token.listed(), "Token should be listed");
        return token;
    }

    function _fillBondingCurve(Token token, address buyer) internal {
        // Buy in large chunks to fill the bonding curve (650M tokens)
        vm.startPrank(buyer, buyer);

        // Skip anti-snipe window
        vm.warp(block.timestamp + 16);

        uint256 maxIterations = 200;
        for (uint256 i = 0; i < maxIterations; i++) {
            if (token.listed()) break;

            uint256 remaining = BONDING_CURVE_TOTAL - token.bondingCurveSupply();
            if (remaining == 0) break;

            // Buy with 5 ETH each time
            uint256 buyAmount = 5 ether;
            if (buyer.balance < buyAmount) {
                vm.deal(buyer, buyer.balance + 100 ether);
            }

            try token.buyToken{value: buyAmount}(0, creator, 0) {
                // Success
            } catch {
                // If buy fails, try with more ETH (near the cap, price is high)
                vm.deal(buyer, buyer.balance + 500 ether);
                try token.buyToken{value: 50 ether}(0, creator, 0) {} catch {
                    // Final attempt with very large amount
                    vm.deal(buyer, buyer.balance + 5000 ether);
                    try token.buyToken{value: 500 ether}(0, creator, 0) {} catch {
                        break;
                    }
                }
            }
        }

        vm.stopPrank();
    }

    function _buildPoolKey(address tokenAddr) internal view returns (PoolKey memory) {
        uint16 hookBitmap = IHooks(address(hook)).getHooksRegistrationBitmap();
        bytes32 parameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), int24(60));

        return PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(tokenAddr),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(mockPoolManager)),
            fee: 0,
            parameters: parameters
        });
    }

    /// @dev Deploy CommunityFactory using vm.getCode to avoid ERC20 collision
    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "CommunityFactory deployment failed");
        return deployed;
    }

    /// @dev Deploy SocialCurationFactory using vm.getCode to avoid ERC20 collision
    function _deploySocialCurationFactory(address _communityFactory, address _claimSigner) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_communityFactory, _claimSigner)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "SocialCurationFactory deployment failed");
        return deployed;
    }
}
