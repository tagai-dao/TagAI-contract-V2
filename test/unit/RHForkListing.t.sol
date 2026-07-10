// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../helpers/RHV4TestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev RH mainnet fork: exercise listing against live Uniswap v4 PoolManager.
///
/// Run (either form):
///   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkListingTest \
///     --fork-url https://rpc.mainnet.chain.robinhood.com -vvv
///   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///   FOUNDRY_ETH_RPC_URL= forge test --match-contract RHForkListingTest -vvv
contract RHForkListingTest is RHV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 internal constant RH_MAINNET_CHAIN_ID = 4663;

    function _bootstrapPoolManager() internal override returns (bool) {
        // Foundry 默认 chain_id=31337，fork 后 block.chainid 可能不变；以 PM 合约 code 为准。
        if (RH_POOL_MANAGER.code.length > 0) {
            manager = IPoolManager(RH_POOL_MANAGER);
            swapRouter = new PoolSwapTest(manager);
            return true;
        }

        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;

        vm.createSelectFork(rpc);
        if (RH_POOL_MANAGER.code.length == 0) return false;

        manager = IPoolManager(RH_POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        return true;
    }

    function test_fork_createAndListOnRealPM() public onlyReady {
        Token token = _createAndListToken("RHFORK");
        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(poolId);
        assertEq(sqrtPrice, INITIAL_SQRT_PRICE_X96, "init sqrt price on real PM");
        assertGt(tick, LISTING_TICK_LOWER, "tick above lower");
        assertLt(tick, LISTING_TICK_UPPER, "tick below upper");
        assertGt(manager.getLiquidity(poolId), 0, "pool liquidity on real PM");
        assertEq(hook.poolToken(poolId), address(token), "hook registered on fork");
        assertGt(RH_POOL_MANAGER.code.length, 0, "using live RH PoolManager");
    }

    function test_fork_800mSellOnRealPM() public onlyReady {
        Token token = _createAndListToken("RHFORKSELL");
        PoolKey memory poolKey = _buildPoolKey(address(token));

        vm.prank(address(hook));
        token.transfer(buyer, NUTBOX_ALLOCATION);

        uint256 ethOut = _sellAllExternal(poolKey, buyer);
        assertGt(ethOut, LISTING_ETH_BUDGET / 2, "800M extracted meaningful ETH");

        uint256 ethAfter = _poolEthBalance(poolKey);
        assertLe(ethAfter, POOL_ETH_END_TOLERANCE, "pool ETH end ~0 on real PM");
    }
}
