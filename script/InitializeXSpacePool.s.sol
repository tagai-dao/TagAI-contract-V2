// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {XSpaceStoreHook} from "../src/hook/XSpaceStoreHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

/**
 * @title InitializeXSpacePoolScript
 * @notice Initialize a CL pool for an already-deployed XSpaceStoreHook.
 *
 * Default price: 3.59 SPCXB per 1 BNB (PRICE_NUM=359, PRICE_DEN=100).
 * Default LP fee: 4000 pips (= 0.4%). Protocol fee is set by PCS controller at init (not configurable).
 *
 * Usage:
 *   forge script script/InitializeXSpacePool.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast -vv
 *
 * Env:
 *   PRIVATE_KEY_MAIN       — deployer key
 *   LP_FEE_PIPS            — default 4000 (0.4% LP fee)
 *   PRICE_NUM / PRICE_DEN  — token1 per token0 ratio (default 359/100 = 3.59 SPCXB/BNB)
 *   INITIAL_SQRT_PRICE_X96 — optional override for sqrtPriceX96
 *   XSPACE_DEPLOY_JSON     — default deployments/56/xspace-store.json
 */
contract InitializeXSpacePoolScript is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using stdJson for string;

    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerKey);

        string memory deployPath = vm.envOr("XSPACE_DEPLOY_JSON", string("deployments/56/xspace-store.json"));
        string memory json = vm.readFile(deployPath);
        address hook = json.readAddress(".XSpaceStoreHook");
        address token = json.readAddress(".token");

        uint24 lpFee = uint24(vm.envOr("LP_FEE_PIPS", uint256(4000)));
        uint160 sqrtPriceX96 = _resolveSqrtPriceX96();

        PoolKey memory poolKey = _buildPoolKey(hook, token, lpFee);
        PoolId poolId = poolKey.toId();

        console.log("=== Initialize XSpace Pool ===");
        console.log("deployer:", deployer);
        console.log("hook:", hook);
        console.log("token:", token);
        console.log("lpFeePips:", lpFee);
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.logBytes32(PoolId.unwrap(poolId));

        _logProtocolFee(poolKey);

        vm.startBroadcast(deployerKey);
        int24 tick = ICLPoolManager(CL_POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
        vm.stopBroadcast();

        console.log("initialized tick:", tick);
        _writeDeployJson(deployPath, deployer, hook, token, poolId, lpFee);

        console.log("Pool initialized successfully");
    }

    function _resolveSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        if (vm.envOr("INITIAL_SQRT_PRICE_X96", uint256(0)) != 0) {
            return uint160(vm.envUint("INITIAL_SQRT_PRICE_X96"));
        }

        uint256 priceNum = vm.envOr("PRICE_NUM", uint256(359));
        uint256 priceDen = vm.envOr("PRICE_DEN", uint256(100));
        require(priceNum > 0 && priceDen > 0, "invalid price ratio");

        // price = token1/token0 = priceNum/priceDen  →  sqrtPriceX96 = sqrt(price * 2^192)
        uint256 ratioX192 = FullMath.mulDiv(priceNum, uint256(1) << 192, priceDen);
        sqrtPriceX96 = _sqrtRatioX192(ratioX192);
    }

    /// @dev Babylonian sqrt for ratioX192, then shift to Q64.96.
    function _sqrtRatioX192(uint256 ratioX192) internal pure returns (uint160 sqrtPriceX96) {
        uint256 z = (ratioX192 >> 1) + 1;
        uint256 y = ratioX192;
        while (z < y) {
            y = z;
            z = (ratioX192 / z + z) >> 1;
        }
        sqrtPriceX96 = uint160(y);
        require(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO && sqrtPriceX96 < TickMath.MAX_SQRT_RATIO, "sqrt out of range");
    }

    function _logProtocolFee(PoolKey memory poolKey) internal view {
        IProtocolFeeController controller = ICLPoolManager(CL_POOL_MANAGER).protocolFeeController();
        if (address(controller) == address(0)) {
            console.log("protocolFeeController: none (protocol fee 0)");
            return;
        }

        uint24 packed = controller.protocolFeeForPool(poolKey);
        uint16 zeroForOne = uint16(packed & 0xfff);
        uint16 oneForZero = uint16(packed >> 12);
        console.log("PCS protocolFeeController:", address(controller));
        console.log("  zeroForOne pips:", zeroForOne);
        console.log("  oneForZero pips:", oneForZero);
        console.log("  (PCS sets protocol fee; pool creator cannot force 0%)");
    }

    function _buildPoolKey(address hook, address token, uint24 lpFee) internal view returns (PoolKey memory poolKey) {
        XSpaceStoreHook hookContract = XSpaceStoreHook(payable(hook));
        uint16 hookBitmap = hookContract.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hookContract.TICK_SPACING());

        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(token),
            hooks: IHooks(hook),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: lpFee,
            parameters: parameters
        });
    }

    function _writeDeployJson(
        string memory path,
        address deployer,
        address hook,
        address token,
        PoolId poolId,
        uint24 lpFee
    ) internal {
        string memory json = vm.readFile(path);
        string memory updated = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "token": "', vm.toString(token), '",\n',
            '  "feeReceiver": "', vm.toString(json.readAddress(".feeReceiver")), '",\n',
            '  "ipshare": "', vm.toString(json.readAddress(".ipshare")), '",\n',
            '  "clPoolManager": "', vm.toString(CL_POOL_MANAGER), '",\n',
            '  "vault": "', vm.toString(json.readAddress(".vault")), '",\n',
            '  "XSpaceStoreHook": "', vm.toString(hook), '",\n',
            '  "HookSalt": "', vm.toString(json.readUint(".HookSalt")), '",\n',
            '  "poolId": "', vm.toString(PoolId.unwrap(poolId)), '",\n',
            '  "lpFeeBps": "', vm.toString(uint256(lpFee)), '",\n',
            '  "priceTokensPerBnb": "3.59",\n',
            '  "tickSpacing": "', vm.toString(uint256(10)), '"\n',
            "}\n"
        );
        vm.writeFile(path, updated);
        console.log("Updated", path);
    }
}
