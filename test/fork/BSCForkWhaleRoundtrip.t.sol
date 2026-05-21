// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./BSCForkBase.t.sol";

/**
 * @title BSCForkWhaleRoundtrip
 * @notice 单账号确定性 800M 外部 token 往返测试：
 *   1. 买满内盘 650M + 收 Hook 150M = 800M
 *   2. DEX 上花 1 BNB 买入，记录 token 与池子余额
 *   3. 卖出 800M + 刚买的全部 token，记录终态池子余额
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkWhaleRoundtrip --fork-url "$BSC_RPC_URL" -vv
 */
contract BSCForkWhaleRoundtrip is BSCForkBase {
    function test_fork_whale800M_buy1BnbThenSellAll() public onlyBscFork {
        address whale = makeAddr("whale800M");
        Token token = _createAndListForWhale("WHALE800", whale);
        address tokenAddr = address(token);
        PoolKey memory poolKey = _buildPoolKey(tokenAddr);

        console2.log("=== Whale setup ===");
        console2.log("  whale address:", whale);
        console2.log("  whale tokens (800M target):", IERC20(tokenAddr).balanceOf(whale) / 1e18);

        assertEq(IERC20(tokenAddr).balanceOf(whale), EXTERNAL_SELLABLE, "800M before DEX");

        _logPoolReserves(poolKey, "after listing");

        // Step 1: DEX 买入 1 BNB
        vm.deal(whale, whale.balance + 1 ether);
        uint256 whaleTokensBeforeBuy = IERC20(tokenAddr).balanceOf(whale);
        uint256 tokensFrom1Bnb = _swapBuyExactIn(poolKey, whale, 1 ether);
        uint256 whaleTokensAfterBuy = IERC20(tokenAddr).balanceOf(whale);

        console2.log("=== DEX buy 1 BNB ===");
        console2.log("  BNB spent (wei):", uint256(1 ether));
        console2.log("  tokens received:", tokensFrom1Bnb / 1e18);
        console2.log("  whale tokens before:", whaleTokensBeforeBuy / 1e18);
        console2.log("  whale tokens after:", whaleTokensAfterBuy / 1e18);

        assertEq(whaleTokensAfterBuy, EXTERNAL_SELLABLE + tokensFrom1Bnb, "800M + buy");
        assertTrue(tokensFrom1Bnb > 0, "1 BNB should buy tokens");

        _logPoolReserves(poolKey, "after 1 BNB buy");

        // Step 2: 卖出 whale 全部 token（800M + 1 BNB 买到的）
        uint256 sellTotal = IERC20(tokenAddr).balanceOf(whale);
        (uint256 bnbOut,,) = _swapSellAll(poolKey, whale);
        uint256 whaleLeft = IERC20(tokenAddr).balanceOf(whale);

        console2.log("=== Sell all whale tokens ===");
        console2.log("  tokens attempted:", sellTotal / 1e18);
        console2.log("  BNB received (wei):", bnbOut);
        console2.log("  BNB received (ether):", bnbOut / 1e18);
        console2.log("  whale token remaining:", whaleLeft / 1e18);

        _logPoolReserves(poolKey, "after sell all");

        PoolId poolId = poolKey.toId();
        (, int24 finalTick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolId);
        uint256 vaultTokenFinal = IERC20(tokenAddr).balanceOf(VAULT);
        console2.log("  final tick:", finalTick);
        console2.log("  LISTING_TICK_UPPER:", LISTING_TICK_UPPER);
        console2.log("  vault token final (tokens):", vaultTokenFinal / 1e18);

        assertApproxEqAbs(bnbOut, LISTING_ETH_AMOUNT, 1 ether, "~19 BNB back from full roundtrip");
        assertLe(whaleLeft, MAX_LISTING_DUST, "whale token dust <= 1");
        // 808M 卖完后 tick 应接近 upper（不必精确到 tickUpper，spacing=60）
        assertGe(finalTick, LISTING_TICK_UPPER - 360, "price near upper after full sell");
        // 808M 卖完后，vault 中 token 应接近 10 亿（200M LP + ~808M 卖入）
        assertGe(vaultTokenFinal, 990_000_000 ether, "vault holds ~1B tokens");
    }
}
