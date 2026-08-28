// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XSpaceStoreHook} from "../src/hook/XSpaceStoreHook.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {
    XSpaceUniversalRouterEncoder,
    IUniversalRouter,
    IPermit2
} from "./helpers/XSpaceUniversalRouter.sol";

/**
 * @title SwapXSpaceScript
 * @notice Swap SPCXB <-> BNB via official PancakeSwap Infinity Universal Router.
 *
 * Sell SPCXB (default 0.02):
 *   SWAP_DIR=sell SWAP_AMOUNT=0.02ether forge script script/SwapXSpace.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast -vv
 *
 * Buy SPCXB with BNB:
 *   SWAP_DIR=buy SWAP_AMOUNT=0.001ether forge script script/SwapXSpace.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast -vv
 *
 * Env:
 *   PRIVATE_KEY_MAIN  — trader key
 *   SWAP_DIR          — "sell" (default) or "buy"
 *   SWAP_AMOUNT       — exact input amount (default 0.02 ether)
 *   XSPACE_DEPLOY_JSON — default deployments/56/xspace-store.json
 */
contract SwapXSpaceScript is Script {
    using stdJson for string;
    using CurrencyLibrary for Currency;

    address constant UNIVERSAL_ROUTER = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    function run() public {
        uint256 traderKey = vm.envUint("PRIVATE_KEY_MAIN");
        address trader = vm.addr(traderKey);

        string memory dir = vm.envOr("SWAP_DIR", string("sell"));
        uint128 amountIn = uint128(vm.envOr("SWAP_AMOUNT", uint256(0.02 ether)));
        bytes memory hookData = bytes("");

        string memory deployPath = vm.envOr("XSPACE_DEPLOY_JSON", string("deployments/56/xspace-store.json"));
        string memory json = vm.readFile(deployPath);
        address hook = json.readAddress(".XSpaceStoreHook");
        address token = json.readAddress(".token");
        uint24 lpFee = uint24(json.readUint(".lpFeeBps"));

        bool zeroForOne = _isBuy(dir);
        PoolKey memory poolKey = _buildPoolKey(hook, token, lpFee);

        console.log("=== XSpace Universal Router Swap ===");
        console.log("trader:", trader);
        console.log("direction:", dir);
        console.log("zeroForOne:", zeroForOne);
        console.log("amountIn:", amountIn);

        if (zeroForOne) {
            require(trader.balance >= amountIn, "insufficient BNB");
        } else {
            require(IERC20(token).balanceOf(trader) >= amountIn, "insufficient SPCXB");
        }

        (bytes memory commands, bytes[] memory inputs) =
            XSpaceUniversalRouterEncoder.encodeExactInSingle(poolKey, zeroForOne, amountIn, 0, hookData);

        vm.startBroadcast(traderKey);

        if (!zeroForOne) {
            IERC20(token).approve(PERMIT2, type(uint256).max);
            IPermit2(PERMIT2).approve(token, UNIVERSAL_ROUTER, type(uint160).max, uint48(block.timestamp + 365 days));
        }

        if (zeroForOne) {
            IUniversalRouter(UNIVERSAL_ROUTER).execute{value: amountIn}(commands, inputs);
        } else {
            IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);
        }

        vm.stopBroadcast();

        console.log("swap submitted via Universal Router");
    }

    function _isBuy(string memory dir) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(dir));
        if (h == keccak256("buy")) return true;
        if (h == keccak256("sell")) return false;
        revert("SWAP_DIR must be buy or sell");
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
