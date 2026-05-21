// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

/**
 * @title BSCForkTest
 * @notice BSC mainnet fork tests mirroring production deployment:
 *   - Reuses live Nutbox stack + IPShare + PCS V4 PoolManager/Vault
 *   - Deploys Pump / HourlyTickCalculator / TagAISwapHook (CREATE2, bitmap 0x0CC1)
 *   - Verifies listing on real PCS V4 and post-listing swaps through real Hook callbacks
 *
 * Run:
 *   source .env
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkTest --fork-url "$BSC_RPC_URL" -vvv
 *
 * Skips automatically when BSC_RPC_URL is unset (e.g. CI without RPC).
 */
contract BSCForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── BSC mainnet addresses (same as DeployBSCTwoPhase.s.sol) ───────────────
    address internal constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    address internal constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address internal constant SOCIAL_CURATION_FACTORY = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address internal constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    uint16 internal constant TARGET_HOOK_BITMAP = 0x0CC1;

    uint256 internal constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 internal constant BONDING_CURVE_TOTAL = 650_000_000 ether;
    uint256 internal constant MIN_INJECT_AMOUNT = 8400 ether;

    // ─── Deployed on fork ────────────────────────────────────────────────────
    HourlyTickCalculator internal calculator;
    Pump internal pump;
    TagAISwapHook internal hook;
    CLPoolManagerRouter internal router;

    address internal creator;
    address internal buyer;
    address internal buyer2;

    bool internal forkReady;

    function setUp() public {
        // Support both `forge test --fork-url ...` and BSC_RPC_URL in .env
        if (block.chainid != 56) {
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length == 0) {
                forkReady = false;
                return;
            }
            vm.createSelectFork(rpc);
        }

        if (block.chainid != 56) {
            forkReady = false;
            return;
        }

        forkReady = true;
        creator = makeAddr("forkCreator");
        buyer = makeAddr("forkBuyer");
        buyer2 = makeAddr("forkBuyer2");

        _deployProductionStack();
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    // ─── Listing on real PCS V4 ──────────────────────────────────────────────

    function test_fork_listingOnRealPCS() public onlyBscFork {
        Token token = _createAndListToken("FORKLIST");

        assertTrue(token.listed(), "token should be listed");
        assertEq(uint16(uint160(address(hook))), TARGET_HOOK_BITMAP, "hook bitmap");

        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice, int24 tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        assertTrue(sqrtPrice > 0, "pool sqrtPrice should be initialized");
        assertTrue(tick != 0 || sqrtPrice > 0, "pool should have state");

        assertEq(hook.poolToken(poolId), address(token), "hook pool mapping");
        (, uint96 remaining,) = hook.tokenInfo(address(token));
        assertEq(uint256(remaining), NUTBOX_ALLOCATION, "hook nutbox remaining");
        assertEq(IERC20(address(token)).balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox allocation");

        assertTrue(ICommittee(COMMITTEE).verifyContract(address(calculator)), "calculator whitelisted");
    }

    // ─── Post-listing buy swap: fee collection + Nutbox inject ─────────────────

    function test_fork_buySwap_triggersHookFeeAndInject() public onlyBscFork {
        Token token = _createAndListToken("FORKBUY");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);
        uint256 feeReceiverBalBefore = FEE_RECEIVER.balance;
        uint256 buyerTokenBefore = IERC20(tokenAddr).balanceOf(buyer);

        // Exact-input ETH buy on real PCS V4 pool (bounded-range LP may cap per-swap output).
        uint256 ethIn = 50 ether;
        vm.deal(buyer, ethIn);

        vm.prank(buyer);
        router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 tokensReceived = IERC20(tokenAddr).balanceOf(buyer) - buyerTokenBefore;
        assertTrue(tokensReceived > 0, "buy swap should deliver tokens");

        // Hook fee path on buy (ETH specified → beforeSwap fee collection)
        assertTrue(FEE_RECEIVER.balance > feeReceiverBalBefore, "platform fee collected on buy");

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        if (tokensReceived >= MIN_INJECT_AMOUNT) {
            assertTrue(uint256(remainingAfter) < uint256(remainingBefore), "inject when above threshold");

            uint256 expectedInject = (tokensReceived * 20) / 10_000;
            if (expectedInject > NUTBOX_ALLOCATION) expectedInject = NUTBOX_ALLOCATION;
            assertEq(
                uint256(remainingBefore) - uint256(remainingAfter),
                expectedInject,
                "inject equals 0.2% of bought tokens"
            );
        } else {
            // Below MIN_INJECT_AMOUNT the hook intentionally skips injection
            assertEq(uint256(remainingAfter), uint256(remainingBefore), "no inject below threshold");
        }
    }

    // ─── Post-listing sell swap: no Nutbox inject ─────────────────────────────

    function test_fork_sellSwap_doesNotInject() public onlyBscFork {
        Token token = _createAndListToken("FORKSELL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        // First buy tokens for the seller (large enough for subsequent sell)
        uint256 ethIn = 100 ether;
        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        router.swap{value: ethIn}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        uint256 tokenBal = IERC20(tokenAddr).balanceOf(buyer);
        assertTrue(tokenBal > 0, "buyer should hold tokens");

        (, uint96 remainingBefore,) = hook.tokenInfo(tokenAddr);

        // Sell half the tokens back to the pool
        uint256 sellAmount = tokenBal / 2;
        vm.prank(buyer);
        IERC20(tokenAddr).approve(address(router), sellAmount);

        vm.prank(buyer);
        router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        (, uint96 remainingAfter,) = hook.tokenInfo(tokenAddr);
        assertEq(uint256(remainingAfter), uint256(remainingBefore), "sell should not inject nutbox tokens");
    }

    // ─── Full lifecycle in one test ──────────────────────────────────────────

    function test_fork_fullLifecycle_listAndSwapBothDirections() public onlyBscFork {
        Token token = _createAndListToken("FORKFULL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        // Buy
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        router.swap{value: 5 ether}(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );
        assertTrue(IERC20(tokenAddr).balanceOf(buyer) > 0, "buyer received tokens");

        // Sell
        uint256 bal = IERC20(tokenAddr).balanceOf(buyer);
        vm.prank(buyer);
        IERC20(tokenAddr).approve(address(router), bal);
        vm.prank(buyer);
        router.swap(
            poolKey,
            ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bal / 4),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            bytes("")
        );

        assertEq(IERC20(tokenAddr).totalSupply(), 1_000_000_000 ether, "total supply invariant");
    }

    // ─── Internal: deploy stack matching production ──────────────────────────

    function _deployProductionStack() internal {
        calculator = new HourlyTickCalculator(COMMUNITY_FACTORY);

        pump = new Pump(IPSHARE, FEE_RECEIVER);
        // Pump defaults already point to BSC PCS V4 + Nutbox; wire calculator + hook next.
        pump.adminSetPoolManager(CL_POOL_MANAGER);
        pump.adminSetVault(VAULT);

        hook = _deployHookWithValidBitmap();

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(COMMUNITY_FACTORY, address(calculator), SOCIAL_CURATION_FACTORY, COMMITTEE);

        router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));

        _whitelistCalculator();
    }

    function _deployHookWithValidBitmap() internal returns (TagAISwapHook deployed) {
        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode,
            abi.encode(ICLPoolManager(CL_POOL_MANAGER), IVault(VAULT), address(pump))
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        // In `forge test`, `new Contract{salt:}` uses this test contract as CREATE2 deployer.
        // Mainnet `forge script --broadcast` uses 0x4e59... instead (see DeployBSCTwoPhase.s.sol).
        address deployer = address(this);
        (bytes32 salt, address predicted,) = _mineHookSalt(deployer, bytecodeHash);

        deployed = new TagAISwapHook{salt: salt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            address(pump)
        );

        assertEq(address(deployed), predicted, "CREATE2 hook address mismatch");
        assertEq(uint16(uint160(address(deployed))), TARGET_HOOK_BITMAP, "invalid hook bitmap");
    }

    function _mineHookSalt(address deployer, bytes32 bytecodeHash)
        internal
        pure
        returns (bytes32 salt, address predicted, uint256 iterations)
    {
        for (uint256 i = 0; i < 100_000_000; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
            predicted = address(uint160(uint256(hash)));
            if (uint16(uint160(predicted)) == TARGET_HOOK_BITMAP) {
                return (salt, predicted, i + 1);
            }
        }
        revert("hook salt not found");
    }

    function _whitelistCalculator() internal {
        address committeeOwner = Ownable(COMMITTEE).owner();
        vm.prank(committeeOwner);
        ICommittee(COMMITTEE).adminAddContract(address(calculator));
    }

    // ─── Internal: create token + fill bonding curve → listing ───────────────

    function _createAndListToken(string memory tick) internal returns (Token token) {
        _ensureCreatorIPShare();

        uint256 nutboxFees = ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee();
        uint256 ipshareFee = IIPShare(IPSHARE).ipshareCreated(creator) ? 0 : IIPShare(IPSHARE).createFee();
        uint256 totalFee = pump.createFee() + nutboxFees + ipshareFee + 1 ether; // +1 ETH pre-mine headroom

        vm.deal(creator, totalFee + 8000 ether);

        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: totalFee}(tick, keccak256(abi.encodePacked(tick, block.timestamp)));
        token = Token(payable(tokenAddr));

        _fillBondingCurve(token, buyer);
        assertTrue(token.listed(), "listing failed on real PCS V4");
    }

    function _ensureCreatorIPShare() internal {
        if (IIPShare(IPSHARE).ipshareCreated(creator)) return;

        uint256 fee = IIPShare(IPSHARE).createFee();
        vm.deal(creator, fee);
        vm.prank(creator, creator);
        IIPShare(IPSHARE).createShare{value: fee}(creator);
    }

    function _fillBondingCurve(Token token, address actor) internal {
        vm.startPrank(actor, actor);
        vm.warp(block.timestamp + 16); // skip anti-snipe window

        for (uint256 i = 0; i < 250 && !token.listed(); i++) {
            if (token.bondingCurveSupply() >= BONDING_CURVE_TOTAL) break;

            uint256 buyEth = 10 ether;
            if (actor.balance < buyEth) vm.deal(actor, buyEth + 100 ether);

            try token.buyToken{value: buyEth}(0, creator, 500) {} catch {
                try token.buyToken{value: 100 ether}(0, creator, 1000) {} catch {
                    try token.buyToken{value: 500 ether}(0, creator, 2000) {} catch {
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
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: 0,
            parameters: parameters
        });
    }
}
