// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XSpaceStoreHook} from "../src/hook/XSpaceStoreHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {XSpaceLiquidityMath} from "./helpers/XSpaceLiquidityMath.sol";

/**
 * @title AddXSpaceLiquidityScript
 * @notice Add concentrated liquidity to the deployed XSpaceStoreHook pool on BSC.
 *
 * PancakeSwap Infinity UI often does NOT list custom-hook pools — use this script instead.
 *
 * Price convention: currency0 = BNB, currency1 = SPCXB → pool price = SPCXB per BNB.
 * Default range: SPCXB ≈ $180 – $160 (tick 12110 – 13290 @ BNB ≈ $604.25).
 *
 * Usage (dry-run):
 *   forge script script/AddXSpaceLiquidity.s.sol --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Usage (broadcast, token-primary 1 SPCXB in $160–$190 band):
 *   LP_TOKEN=1ether LP_BNB=0 \
 *   forge script script/AddXSpaceLiquidity.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast -vv
 *
 * Env:
 *   PRIVATE_KEY_MAIN   — LP provider key (must hold BNB + SPCXB)
 *   LP_BNB             — BNB budget (default 0.001 ether); set 0 to derive from LP_TOKEN at spot
 *   LP_TOKEN           — SPCXB budget; if 0, derived from LP_BNB at pool spot price
 *   TICK_LOWER         — default 12110 (~$180 SPCXB @ BNB $604.25)
 *   TICK_UPPER         — default 13290 (~$160 SPCXB @ BNB $604.25)
 *   XSPACE_DEPLOY_JSON — default deployments/56/xspace-store.json
 */
contract AddXSpaceLiquidityScript is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using stdJson for string;

    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;

    /// @dev tick spacing on XSpaceStoreHook pool
    int24 constant TICK_SPACING = 10;

    /// @dev SPCXB USD band $180 – $160 mapped at BNB ≈ $604.25 → pool price 3.36 – 3.78 SPCXB/BNB.
    int24 constant DEFAULT_TICK_LOWER = 12110;
    int24 constant DEFAULT_TICK_UPPER = 13290;

    /// @dev Default BNB budget for a small seed LP position.
    uint256 constant DEFAULT_LP_BNB = 0.001 ether;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_MAIN");
        address lpProvider = vm.addr(deployerKey);

        string memory deployPath = vm.envOr("XSPACE_DEPLOY_JSON", string("deployments/56/xspace-store.json"));
        string memory json = vm.readFile(deployPath);
        address hook = json.readAddress(".XSpaceStoreHook");
        address token = json.readAddress(".token");
        bytes32 poolIdRaw = json.readBytes32(".poolId");
        uint24 lpFee = uint24(json.readUint(".lpFeeBps"));

        uint256 bnbBudget = vm.envOr("LP_BNB", DEFAULT_LP_BNB);
        int24 tickLower = int24(int256(vm.envOr("TICK_LOWER", uint256(int256(DEFAULT_TICK_LOWER)))));
        int24 tickUpper = int24(int256(vm.envOr("TICK_UPPER", uint256(int256(DEFAULT_TICK_UPPER)))));
        uint256 tokenBudget = vm.envOr("LP_TOKEN", uint256(0));

        console.log("=== Add XSpace Liquidity ===");
        console.log("LP provider:", lpProvider);
        console.log("Hook:", hook);
        console.log("Token:", token);
        console.log("lpFeePips:", lpFee);
        console.log("PoolId:");
        console.logBytes32(poolIdRaw);
        console.log("tickLower:", tickLower);
        console.log("tickUpper:", tickUpper);
        console.log("price band: SPCXB ~$180 (tickLower) to ~$160 (tickUpper), BNB ref ~$604");
        console.log("BNB budget:", _format18(bnbBudget), "BNB");

        require(tickLower < tickUpper, "tick order");
        require(tickLower % TICK_SPACING == 0 && tickUpper % TICK_SPACING == 0, "ticks must align to spacing");

        PoolKey memory poolKey = _buildPoolKey(hook, token, lpFee);
        require(PoolId.unwrap(poolKey.toId()) == poolIdRaw, "poolId mismatch");

        (uint160 sqrtPrice, int24 currentTick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolKey.toId());
        console.log("current tick:", currentTick);
        console.log("current sqrtPriceX96:", sqrtPrice);
        require(currentTick >= tickLower && currentTick <= tickUpper, "spot outside LP range");

        // token1/token0 at spot ≈ (sqrtPriceX96 / 2^96)^2
        if (tokenBudget == 0 && bnbBudget > 0) {
            tokenBudget = FullMath.mulDiv(
                FullMath.mulDiv(bnbBudget, uint256(sqrtPrice), FixedPoint96.Q96),
                uint256(sqrtPrice),
                FixedPoint96.Q96
            );
        } else if (tokenBudget > 0 && bnbBudget == 0) {
            // BNB budget derived from SPCXB at spot (token-primary mode)
            bnbBudget = FullMath.mulDiv(tokenBudget, FixedPoint96.Q96, uint256(sqrtPrice));
            bnbBudget = FullMath.mulDiv(bnbBudget, FixedPoint96.Q96, uint256(sqrtPrice));
            // 5% buffer so BNB side is not the limiting factor
            bnbBudget = bnbBudget + bnbBudget / 20;
        }
        console.log("BNB budget (effective):", _format18(bnbBudget), "BNB");
        console.log("token budget:", _format18(tokenBudget), "SPCXB");

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = XSpaceLiquidityMath.liquidityForAmounts(sqrtPrice, sqrtLower, sqrtUpper, bnbBudget, tokenBudget);
        (uint256 spentEth, uint256 spentToken) =
            XSpaceLiquidityMath.amountsForLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity);

        console.log("liquidity:", liquidity);
        console.log("spent BNB:", _format18(spentEth), "BNB");
        console.log("spent token:", _format18(spentToken), "SPCXB");

        require(spentEth <= lpProvider.balance, "insufficient BNB");
        require(spentToken <= IERC20(token).balanceOf(lpProvider), "insufficient token");

        vm.startBroadcast(deployerKey);

        CLPoolManagerRouter router = new CLPoolManagerRouter(IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER));
        console.log("Router deployed:", address(router));

        IERC20(token).approve(address(router), type(uint256).max);

        (BalanceDelta delta,) = router.modifyPosition{value: spentEth}(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        vm.stopBroadcast();

        console.log("LP added. BNB:", _format18(uint256(uint128(-delta.amount0()))), "BNB");
        console.log("LP added. SPCXB:", _format18(uint256(uint128(-delta.amount1()))), "SPCXB");
        console.log("active pool liquidity:", ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolKey.toId()));
    }

    /// @dev Format 18-decimal token amounts as "whole.frac" (6 fractional digits).
    function _format18(uint256 amount) internal view returns (string memory) {
        return string.concat(vm.toString(amount / 1e18), ".", _padFrac6((amount % 1e18) / 1e12));
    }

    function _padFrac6(uint256 frac) internal pure returns (string memory) {
        bytes memory out = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            out[5 - i] = bytes1(uint8(48 + (frac % 10)));
            frac /= 10;
        }
        return string(out);
    }

    function _buildPoolKey(address hook, address token, uint24 lpFee) internal view returns (PoolKey memory key) {
        XSpaceStoreHook hookContract = XSpaceStoreHook(payable(hook));
        uint16 hookBitmap = hookContract.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hookContract.TICK_SPACING());

        key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(token),
            hooks: IHooks(hook),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: lpFee,
            parameters: parameters
        });
    }
}
