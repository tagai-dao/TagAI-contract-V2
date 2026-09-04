// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {Token12} from "../../../src/pump12/Token12.sol";
import {NetNetHook} from "../../../src/pump12/NetNetHook.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

/// @notice Pump12 在 Robinhood mainnet canonical USDG / PoolManager 上的最小闭环验收。
contract Pump12RHListingForkTest is Test {
    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal trader = makeAddr("trader");

    bool internal forkReady;
    Pump12 internal pump;
    Token12 internal token;
    NetNetHook internal hook;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        // Foundry default profile pins local chain_id=31337 even after selecting an RPC fork.
        vm.chainId(RH_CHAIN_ID);
        require(block.chainid == RH_CHAIN_ID, "unexpected RH chain id");
        require(USDG.code.length > 0, "canonical USDG missing");
        require(POOL_MANAGER.code.length > 0, "canonical PoolManager missing");

        vm.prank(tagAI);
        pump = new Pump12(USDG, POOL_MANAGER);
        hook = _deployHook();
        vm.prank(tagAI);
        pump.setHook(address(hook));

        vm.prank(creator);
        token = Token12(
            pump.createToken(
                Pump12.CreateParams({
                    name: "Pump12 RH Fork",
                    symbol: "P12RHF",
                    salt: bytes32("rh-fork"),
                    totalFeeBps: 500,
                    creatorShareBps: 2_000,
                    creatorFeeRecipient: creator,
                    indexToken: makeAddr("indexToken"),
                    pTeamHolder: makeAddr("pTeamHolder")
                })
            )
        );
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        forkReady = true;
    }

    modifier onlyFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function test_fork_createListAndSwapBothDirections() public onlyFork {
        deal(USDG, buyer, 30_000e6, true);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(token), type(uint256).max);
        token.buy(20_000e6, 750_000_000e18);
        vm.stopPrank();

        (PoolId poolId,) = pump.list(address(token));
        PoolKey memory key = _poolKey();

        deal(USDG, trader, 100e6, true);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        _swap(key, USDG < address(token), -int256(100e6));
        uint256 bought = token.balanceOf(trader);
        assertGt(bought, 0);

        token.approve(address(swapRouter), bought / 2);
        _swap(key, USDG >= address(token), -int256(bought / 2));
        vm.stopPrank();

        assertGt(IERC20(USDG).balanceOf(trader), 0);
        assertGt(hook.pendingUSDG(poolId), 0);
        assertEq(
            hook.claimableTagAI(poolId) + hook.claimableCreator(poolId) + hook.pendingUSDG(poolId),
            IERC20(USDG).balanceOf(address(hook))
        );
    }

    function _deployHook() internal returns (NetNetHook deployed) {
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(pump), USDG);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(NetNetHook).creationCode, constructorArgs);
        deployed = new NetNetHook{salt: salt}(IPoolManager(POOL_MANAGER), address(pump), USDG);
        assertEq(address(deployed), predicted);
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(address(token));
        Currency usdgCurrency = Currency.wrap(USDG);
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))
        });
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }
}
