// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../helpers/RHV4TestBase.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Local anvil / pure Foundry: fresh v4 PoolManager + full Pump listing lifecycle.
contract RHV4ListingLocalTest is RHV4TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_local_createAndList() public onlyReady {
        Token token = _createAndListToken("RHLOCAL");

        PoolKey memory poolKey = _buildPoolKey(address(token));
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPrice,,,) = manager.getSlot0(poolId);
        assertEq(sqrtPrice, INITIAL_SQRT_PRICE_X96, "init sqrt price");
        assertGt(manager.getLiquidity(poolId), 0, "pool has liquidity");
        assertEq(hook.poolToken(poolId), address(token), "hook pool mapping");

        (, uint96 remaining,) = hook.tokenInfo(address(token));
        assertEq(uint256(remaining), NUTBOX_ALLOCATION, "hook nutbox budget");
        assertEq(token.balanceOf(address(hook)), NUTBOX_ALLOCATION, "hook holds nutbox tokens");
    }

    function test_local_listingPoolLiquidity() public onlyReady {
        Token token = _createAndListToken("RHBUDGET");
        PoolKey memory poolKey = _buildPoolKey(address(token));

        assertLe(address(token).balance, 0.1 ether, "token ETH mostly consumed at listing");

        uint256 poolEth = _poolEthBalance(poolKey);
        assertGe(poolEth, LISTING_ETH_BUDGET / 2, "pool holds ~4.8 ETH liquidity");
        assertLe(poolEth, LISTING_ETH_BUDGET + 0.05 ether, "pool ETH near listing budget");
    }

    function test_local_800mExternalSellDrainsPoolEth() public onlyReady {
        Token token = _createAndListToken("RHSELL");
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        // 模拟池外 800M：buyer 650M + 从 hook 取出 150M Nutbox
        vm.prank(address(hook));
        token.transfer(buyer, NUTBOX_ALLOCATION);

        assertEq(token.balanceOf(buyer), EXTERNAL_SELLABLE, "buyer holds 800M external");

        uint256 ethBefore = _poolEthBalance(poolKey);
        assertGe(ethBefore, LISTING_ETH_BUDGET / 2, "pool holds listing ETH");

        uint256 ethOut = _sellAllExternal(poolKey, buyer);
        assertGt(ethOut, 0, "external sell produced ETH");

        uint256 ethAfter = _poolEthBalance(poolKey);
        assertLe(ethAfter, POOL_ETH_END_TOLERANCE, "pool ETH drained (~0)");
        assertLe(token.balanceOf(buyer), 1 ether, "800M mostly sold into pool");
    }
}
