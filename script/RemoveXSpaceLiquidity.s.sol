// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XSpaceStoreHook} from "../src/hook/XSpaceStoreHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

/**
 * @title RemoveXSpaceLiquidityScript
 * @notice Remove concentrated liquidity from the XSpaceStoreHook pool.
 *
 * Usage (dry-run):
 *   forge script script/RemoveXSpaceLiquidity.s.sol --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Usage (broadcast, remove the 0.005 BNB LP added earlier):
 *   forge script script/RemoveXSpaceLiquidity.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast -vv
 *
 * Env:
 *   PRIVATE_KEY_MAIN   — LP provider key
 *   REMOVE_LIQUIDITY   — optional; default 707518339380156491 (last add)
 *   XSPACE_ROUTER      — optional; default 0x02679... (router from add-LP tx)
 *   TICK_LOWER         — default 12810
 *   TICK_UPPER         — default 13080
 *   XSPACE_DEPLOY_JSON — default deployments/56/xspace-store.json
 */
contract RemoveXSpaceLiquidityScript is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using stdJson for string;

    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    /// @dev Router deployed when LP was added; position owner is this contract.
    address constant DEFAULT_ROUTER = 0x02679B15DBFD5BE9B2918156AeB2A626F0895a8C;

    int24 constant DEFAULT_TICK_LOWER = 12810;
    int24 constant DEFAULT_TICK_UPPER = 13080;
    uint128 constant DEFAULT_LIQUIDITY = 707518339380156491;

    function run() public {
        uint256 lpKey = vm.envUint("PRIVATE_KEY_MAIN");
        address lpProvider = vm.addr(lpKey);

        string memory deployPath = vm.envOr("XSPACE_DEPLOY_JSON", string("deployments/56/xspace-store.json"));
        string memory json = vm.readFile(deployPath);
        address hook = json.readAddress(".XSpaceStoreHook");
        address token = json.readAddress(".token");
        bytes32 poolIdRaw = json.readBytes32(".poolId");
        uint24 lpFee = uint24(json.readUint(".lpFeeBps"));

        int24 tickLower = int24(int256(vm.envOr("TICK_LOWER", uint256(int256(DEFAULT_TICK_LOWER)))));
        int24 tickUpper = int24(int256(vm.envOr("TICK_UPPER", uint256(int256(DEFAULT_TICK_UPPER)))));
        uint128 liquidityToRemove = uint128(vm.envOr("REMOVE_LIQUIDITY", uint256(DEFAULT_LIQUIDITY)));
        address routerAddr = vm.envOr("XSPACE_ROUTER", DEFAULT_ROUTER);

        console.log("=== Remove XSpace Liquidity ===");
        console.log("LP provider:", lpProvider);
        console.log("router:", routerAddr);
        console.log("tickLower:", tickLower);
        console.log("tickUpper:", tickUpper);
        console.log("liquidity to remove:", liquidityToRemove);

        PoolKey memory poolKey = _buildPoolKey(hook, token, lpFee);
        require(PoolId.unwrap(poolKey.toId()) == poolIdRaw, "poolId mismatch");

        (uint160 sqrtPrice, int24 currentTick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolKey.toId());
        console.log("current tick:", currentTick);
        console.log("current sqrtPriceX96:", sqrtPrice);
        console.log("pool active liquidity:", ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolKey.toId()));

        uint256 bnbBefore = lpProvider.balance;
        uint256 tokenBefore = IERC20(token).balanceOf(lpProvider);

        vm.startBroadcast(lpKey);

        CLPoolManagerRouter router = CLPoolManagerRouter(payable(routerAddr));

        (BalanceDelta delta,) = router.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        vm.stopBroadcast();

        uint256 bnbReceived = lpProvider.balance - bnbBefore;
        uint256 tokenReceived = IERC20(token).balanceOf(lpProvider) - tokenBefore;
        console.log("BNB received:", bnbReceived);
        console.log("SPCXB received:", tokenReceived);
        console.log("delta amount0:", uint256(uint128(delta.amount0())));
        console.log("delta amount1:", uint256(uint128(delta.amount1())));
        console.log("pool active liquidity after:", ICLPoolManager(CL_POOL_MANAGER).getLiquidity(poolKey.toId()));
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
