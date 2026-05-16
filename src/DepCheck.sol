// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// Verify OpenZeppelin imports work
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Verify Solady imports work
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

// Verify PancakeSwap infinity-core imports work — pool-cl interfaces
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

// Verify PancakeSwap infinity-core imports work — core interfaces
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

// Verify PancakeSwap infinity-core imports work — types
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

// Verify PancakeSwap infinity-core imports work — libraries
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

/// @notice Dependency verification contract - can be removed after verification
contract DepCheck is ReentrancyGuard {
    function check() external pure returns (bool) {
        return true;
    }
}
