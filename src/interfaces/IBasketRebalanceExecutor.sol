// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBasketToken} from "./IBasketToken.sol";

interface IBasketRebalanceExecutor {
    function quoteAssetToWeth(IBasketToken.LegRoute calldata route, address asset, uint256 amount)
        external
        view
        returns (uint256);
}
