// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {Token} from "../../src/pump/Token.sol";

interface SplitPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
}

/// @notice TEST ONLY execution adapter. It accepts an off-chain allocation, never searches
/// for routes on chain. Route 0 is V4; routes 1..N buy the corresponding component then T.
/// This is an integration/gas fixture, not an audited production aggregator.
contract ForkSplitBuyRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    INutboxRouter public immutable router;

    constructor(INutboxRouter router_) {
        router = router_;
    }
    receive() external payable {}

    function buy(Token token, uint256[] calldata allocations, uint256 minOut, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 received)
    {
        require(block.timestamp <= deadline, "DEADLINE");
        require(recipient != address(0) && token.listed(), "INVALID_TARGET");
        require(allocations.length == token.componentCount() + 1, "LENGTH");
        uint256 total;
        for (uint256 i; i < allocations.length; ++i) {
            total += allocations[i];
        }
        require(total == msg.value && total != 0, "VALUE");
        uint256 beforeT = token.balanceOf(address(this));
        if (allocations[0] != 0) {
            router.swapExactInput{value: allocations[0]}(
                address(0), address(token), allocations[0], 1, address(this), deadline
            );
        }
        for (uint256 i = 1; i < allocations.length; ++i) {
            if (allocations[i] == 0) continue;
            (address asset,, address pair) = token.componentAt(i - 1);
            uint256 beforeAsset = IERC20(asset).balanceOf(address(this));
            router.swapExactInput{value: allocations[i]}(address(0), asset, allocations[i], 1, address(this), deadline);
            uint256 assetIn = IERC20(asset).balanceOf(address(this)) - beforeAsset;
            (uint112 r0, uint112 r1,) = SplitPair(pair).getReserves();
            bool input0 = SplitPair(pair).token0() == asset;
            uint256 reserveIn = input0 ? r0 : r1;
            uint256 reserveOut = input0 ? r1 : r0;
            IERC20(asset).safeTransfer(pair, assetIn);
            uint256 actualIn = IERC20(asset).balanceOf(pair) - reserveIn;
            uint256 grossOut = actualIn * 9975 * reserveOut / (reserveIn * 10000 + actualIn * 9975);
            SplitPair(pair).swap(input0 ? 0 : grossOut, input0 ? grossOut : 0, address(this), "");
        }
        received = token.balanceOf(address(this)) - beforeT;
        require(received >= minOut && received != 0, "SLIPPAGE");
        IERC20(address(token)).safeTransfer(recipient, received);
    }
}
