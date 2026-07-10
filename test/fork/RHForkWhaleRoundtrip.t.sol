// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {Token} from "../../src/pump/Token.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import "./RHForkBase.t.sol";

/**
 * @title RHForkWhaleRoundtrip
 * @notice RH fork: 800M external sellable roundtrip on live PM (~4.8 ETH listing budget).
 *
 * Run:
 *   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkWhaleRoundtrip -vv
 */
contract RHForkWhaleRoundtrip is RHForkBase {
    using PoolIdLibrary for PoolKey;

    function test_fork_whale800M_buy1EthThenSellAll() public onlyRhFork {
        address whale = makeAddr("whale800M");
        vm.deal(whale, 100 ether);

        Token token = _createAndListForWhale("WHALE800", whale);
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        console2.log("=== Whale setup ===");
        console2.log("  whale tokens (800M target):", IERC20(tokenAddr).balanceOf(whale) / 1e18);
        assertEq(IERC20(tokenAddr).balanceOf(whale), EXTERNAL_SELLABLE);

        _logPoolReserves(poolKey, "after listing");

        uint256 whaleTokensBeforeBuy = IERC20(tokenAddr).balanceOf(whale);
        uint256 tokensFrom1Eth = _swapBuyExactIn(poolKey, whale, 1 ether);
        uint256 whaleTokensAfterBuy = IERC20(tokenAddr).balanceOf(whale);

        console2.log("=== DEX buy 1 ETH ===");
        console2.log("  tokens received:", tokensFrom1Eth / 1e18);
        assertEq(whaleTokensAfterBuy, EXTERNAL_SELLABLE + tokensFrom1Eth);
        assertGt(tokensFrom1Eth, 0);

        _logPoolReserves(poolKey, "after 1 ETH buy");

        uint256 sellTotal = IERC20(tokenAddr).balanceOf(whale);
        (uint256 ethOut,,) = _swapSellAll(poolKey, whale);
        uint256 whaleLeft = IERC20(tokenAddr).balanceOf(whale);

        console2.log("=== Sell all whale tokens ===");
        console2.log("  tokens attempted:", sellTotal / 1e18);
        console2.log("  ETH received (wei):", ethOut);
        console2.log("  whale token remaining:", whaleLeft / 1e18);

        _logPoolReserves(poolKey, "after sell all");

        PoolId poolId = poolKey.toId();
        (, int24 finalTick,,) = _slot0(poolId);
        uint256 poolEthFinal = _poolEthBalance(poolKey);

        console2.log("  final tick:", finalTick);
        console2.log("  LISTING_TICK_UPPER:", LISTING_TICK_UPPER);
        console2.log("  pool ETH final (wei):", poolEthFinal);

        assertGt(ethOut, LISTING_ETH_BUDGET / 2, "800M+ extracted meaningful ETH");
        assertLe(whaleLeft, MAX_LISTING_DUST, "whale token dust");
        assertLe(poolEthFinal, POOL_ETH_END_TOLERANCE, "pool ETH ~0 after full sell");
        assertGe(finalTick, LISTING_TICK_UPPER - 360, "price near upper after full sell");
    }
}
