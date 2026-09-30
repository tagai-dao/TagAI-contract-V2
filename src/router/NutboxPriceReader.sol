// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {INutboxRouter} from "./INutboxRouter.sol";
import {NutboxSpotPrice} from "./NutboxSpotPrice.sol";

/// @notice Stateless source validation and spot pricing. Deployed with each Router.
/// @dev Keeping read-only DEX decoding out of Router leaves room for configuration APIs under EIP-170.
contract NutboxPriceReader {
    function quote(
        INutboxRouter registry,
        address input,
        address output,
        uint256 amount,
        INutboxRouter.SourceType kind,
        bytes calldata source
    ) external view returns (uint256) {
        return NutboxSpotPrice.quote(registry, input, output, amount, kind, source);
    }

    function sourceTokens(INutboxRouter.SourceType kind, bytes calldata source)
        external
        view
        returns (address, address)
    {
        return NutboxSpotPrice.sourceTokens(kind, source);
    }
}
