// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {XSpaceStoreHook} from "../src/hook/XSpaceStoreHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

/**
 * @title DeployXSpaceStoreHook
 * @notice Deploy XSpaceStoreHook via CREATE2 (mined salt) and optionally initialize the CL pool.
 *
 * Hook address must satisfy: address & 0xFFFF == 0x0CC1
 *
 * Usage (deploy hook only):
 *   forge script script/DeployXSpaceStoreHook.s.sol --rpc-url $BSC_RPC_URL --broadcast
 *
 * Usage (deploy hook + initialize pool):
 *   INITIAL_SQRT_PRICE_X96=<uint160> forge script script/DeployXSpaceStoreHook.s.sol --rpc-url $BSC_RPC_URL --broadcast
 *
 * Env:
 *   PRIVATE_KEY_MAIN  — deployer private key
 *   INITIAL_SQRT_PRICE_X96 — optional; when set, initializes the pool after hook deploy
 */
contract DeployXSpaceStoreHookScript is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── BSC mainnet ───────────────────────────────────────────────────────────
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    address constant XSPACE_TOKEN = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    uint16 constant TARGET_BITMAP = 0x0CC1;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant MAX_MINING_ITERATIONS = 100_000_000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== XSpaceStoreHook Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Token:", XSPACE_TOKEN);
        console.log("Fee receiver:", FEE_RECEIVER);
        console.log("IPShare:", IPSHARE);
        console.log("");

        bytes memory creationCode = abi.encodePacked(
            type(XSpaceStoreHook).creationCode,
            abi.encode(
                ICLPoolManager(CL_POOL_MANAGER),
                IVault(VAULT),
                XSPACE_TOKEN,
                FEE_RECEIVER,
                IPSHARE
            )
        );
        bytes32 bytecodeHash = keccak256(creationCode);

        console.log("Mining CREATE2 salt...");
        (bytes32 hookSalt, address predictedAddress, uint256 iterations) =
            mineSalt(CREATE2_DEPLOYER, bytecodeHash);

        console.log("  iterations:", iterations);
        console.log("  salt (decimal):", uint256(hookSalt));
        console.log("  predicted hook:", predictedAddress);

        vm.startBroadcast(deployerPrivateKey);

        XSpaceStoreHook hook = new XSpaceStoreHook{salt: hookSalt}(
            ICLPoolManager(CL_POOL_MANAGER),
            IVault(VAULT),
            XSPACE_TOKEN,
            FEE_RECEIVER,
            IPSHARE
        );

        require(address(hook) == predictedAddress, "Hook address mismatch");
        require(uint16(uint160(address(hook))) == TARGET_BITMAP, "Invalid hook bitmap");

        console.log("XSpaceStoreHook deployed:", address(hook));

        PoolKey memory poolKey = _buildPoolKey(hook);
        PoolId poolId = poolKey.toId();
        console.logBytes32(PoolId.unwrap(poolId));

        if (vm.envOr("INITIAL_SQRT_PRICE_X96", uint256(0)) != 0) {
            uint160 sqrtPriceX96 = uint160(vm.envUint("INITIAL_SQRT_PRICE_X96"));
            console.log("Initializing pool at sqrtPriceX96:", sqrtPriceX96);
            ICLPoolManager(CL_POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
            console.log("Pool initialized");
        } else {
            console.log("Skip pool init (set INITIAL_SQRT_PRICE_X96 to initialize)");
        }

        vm.stopBroadcast();

        _writeAddresses(deployer, address(hook), hookSalt, poolId);
    }

    function _buildPoolKey(XSpaceStoreHook hook) internal view returns (PoolKey memory poolKey) {
        uint16 hookBitmap = hook.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hook.TICK_SPACING());

        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(hook.token()),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: hook.RECOMMENDED_LP_FEE_PIPS(),
            parameters: parameters
        });
    }

    function mineSalt(
        address deployer,
        bytes32 bytecodeHash
    ) internal pure returns (bytes32 salt, address predictedAddress, uint256 iterations) {
        for (uint256 i = 0; i < MAX_MINING_ITERATIONS; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
            predictedAddress = address(uint160(uint256(hash)));
            if (uint16(uint160(predictedAddress)) == TARGET_BITMAP) {
                return (salt, predictedAddress, i + 1);
            }
        }
        revert("No valid salt found");
    }

    function _writeAddresses(
        address deployer,
        address hook,
        bytes32 hookSalt,
        PoolId poolId
    ) internal {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), "/xspace-store.json");
        string memory json = string.concat(
            "{\n",
            '  "chainId": ', vm.toString(block.chainid), ",\n",
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "token": "', vm.toString(XSPACE_TOKEN), '",\n',
            '  "feeReceiver": "', vm.toString(FEE_RECEIVER), '",\n',
            '  "ipshare": "', vm.toString(IPSHARE), '",\n',
            '  "clPoolManager": "', vm.toString(CL_POOL_MANAGER), '",\n',
            '  "vault": "', vm.toString(VAULT), '",\n',
            '  "XSpaceStoreHook": "', vm.toString(hook), '",\n',
            '  "HookSalt": "', vm.toString(uint256(hookSalt)), '",\n',
            '  "poolId": "', vm.toString(PoolId.unwrap(poolId)), '",\n',
            '  "lpFeeBps": "', vm.toString(uint256(4000)), '",\n',
            '  "tickSpacing": "', vm.toString(uint256(10)), '"\n',
            "}\n"
        );
        vm.writeFile(path, json);
        console.log("Wrote", path);
    }
}
