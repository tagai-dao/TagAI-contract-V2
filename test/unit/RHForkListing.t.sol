// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Token} from "../../src/pump/Token.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import "../fork/RHForkBase.t.sol";

/// @dev RH mainnet fork: listing + 800M sell against live Uniswap v4 PoolManager.
///
/// Run:
///   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkListingTest -vvv
contract RHForkListingTest is RHForkBase {
    using PoolIdLibrary for PoolKey;

    function test_fork_createAndListOnRealPM() public onlyRhFork {
        Token token = _createAndListToken("RHFORK");
        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice, int24 tick,,) = _slot0(poolId);
        assertEq(sqrtPrice, INITIAL_SQRT_PRICE_X96, "init sqrt price on real PM");
        assertGt(tick, LISTING_TICK_LOWER, "tick above lower");
        assertLt(tick, LISTING_TICK_UPPER, "tick below upper");
        assertGt(_poolLiquidity(poolId), 0, "pool liquidity on real PM");
        assertEq(hook.poolToken(poolId), address(token), "hook registered on fork");
        assertGt(RH_POOL_MANAGER.code.length, 0, "using live RH PoolManager");
    }

    function test_fork_800mSellOnRealPM() public onlyRhFork {
        address whale = makeAddr("fork800m");
        vm.deal(whale, 50_000 ether);

        Token token = _createAndListForWhale("RHFORKSELL", whale);
        PoolKey memory poolKey = _buildPoolKey(address(token));

        (uint256 ethOut,,) = _swapSellAll(poolKey, whale);
        assertGt(ethOut, LISTING_ETH_BUDGET / 2, "800M extracted meaningful ETH");

        uint256 ethAfter = _poolEthBalance(poolKey);
        assertLe(ethAfter, POOL_ETH_END_TOLERANCE, "pool ETH end ~0 on real PM");
    }
}
