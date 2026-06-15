// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

/// @dev PancakeSwap Infinity Universal Router action bytes (infinity-periphery Actions.sol).
library XSpaceUniversalRouterActions {
    uint256 internal constant CL_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;
    uint256 internal constant INFI_SWAP = 0x10;
}

struct CLSwapExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @dev Build INFI_SWAP payload for Universal Router.execute().
library XSpaceUniversalRouterEncoder {
    function encodeExactInSingle(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bytes memory hookData
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        CLSwapExactInputSingleParams memory swapParams = CLSwapExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            hookData: hookData
        });

        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(XSpaceUniversalRouterActions.CL_SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(XSpaceUniversalRouterActions.SETTLE_ALL)),
            bytes1(uint8(XSpaceUniversalRouterActions.TAKE_ALL))
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(inputCurrency, type(uint256).max);
        params[2] = abi.encode(outputCurrency, uint256(0));

        commands = abi.encodePacked(bytes1(uint8(XSpaceUniversalRouterActions.INFI_SWAP)));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
