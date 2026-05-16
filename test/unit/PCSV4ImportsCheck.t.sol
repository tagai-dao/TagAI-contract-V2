// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

// PCS V4 Hook interfaces
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

// PCS V4 types
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

// PCS V4 libraries
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

/// @title PCSV4ImportsCheck
/// @notice Verifies all PCS V4 (infinity-core) imports resolve correctly
contract PCSV4ImportsCheck is Test {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    function test_allImportsResolve() public pure {
        // If this test compiles and runs, all imports are valid
        assertTrue(true);
    }

    function test_poolKeyStructUsable() public pure {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0)),
            fee: 3000,
            parameters: bytes32(0)
        });
        PoolId id = key.toId();
        // Verify PoolId is usable
        assertTrue(PoolId.unwrap(id) != bytes32(0) || PoolId.unwrap(id) == bytes32(0));
    }

    function test_currencyLibraryUsable() public pure {
        Currency native = CurrencyLibrary.NATIVE;
        assertTrue(Currency.unwrap(native) == address(0));
    }

    function test_balanceDeltaUsable() public pure {
        BalanceDelta delta = toBalanceDelta(int128(100), int128(-100));
        // Just verify it compiles and is usable
        assertTrue(delta.amount0() == 100);
        assertTrue(delta.amount1() == -100);
    }

    function test_beforeSwapDeltaUsable() public pure {
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(0), int128(0));
        // Verify the zero delta constant
        assertTrue(BeforeSwapDelta.unwrap(delta) == BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    }
}
