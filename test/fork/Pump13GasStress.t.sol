// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump13MainnetForkTest, ForkCreate, ForkPair, ForkStake, ForkBasketRouter} from "./Pump13Mainnet.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {BSCNutboxRouterConfig as Config} from "../../script/config/BSCNutboxRouterConfig.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "infinity-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {ForkSplitBuyRouter} from "../helpers/ForkSplitBuyRouter.sol";

interface GasV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface GasV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function initialize(uint160) external;
    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256);
}

interface GasWrappedNative {
    function deposit() external payable;
}

interface GasFinalize {
    function finalizeTokenListing(address, uint256[] calldata, uint256) external;
}

/// @dev Run with --match-contract Pump13GasStressForkTest --match-test test_gas_.
/// Existing functional cases are inherited but excluded by that filter.
contract Pump13GasStressForkTest is Pump13MainnetForkTest {
    uint256 constant MAINNET_TX_CAP = 16_777_216;
    uint256 constant EXECUTION_BUDGET = 16_600_000;
    address private mintingPool;

    function pancakeV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == mintingPool && mintingPool != address(0), "UNEXPECTED_MINT_CALLBACK");
        if (amount0 != 0) IERC20(GasV3Pool(msg.sender).token0()).transfer(msg.sender, amount0);
        if (amount1 != 0) IERC20(GasV3Pool(msg.sender).token1()).transfer(msg.sender, amount1);
    }

    function _fourStocks() internal view returns (IPump.IndexConfig memory c) {
        // QQQB, SPCXB, AAPLB, SKHYB: four equally weighted stock/ETF assets.
        c = _config(2, 4, true);
    }

    function _quoteVenues(IPump.IndexConfig memory c, bool nativeQuote) internal {
        _quoteVenuesWithDepth(c, nativeQuote, 50 ether);
    }

    function _quoteVenuesWithDepth(IPump.IndexConfig memory c, bool nativeQuote, uint256 nativeDepth) internal {
        address quote = nativeQuote ? Config.wrappedNative() : Config.settlementToken();
        address opposite = nativeQuote ? Config.settlementToken() : Config.wrappedNative();
        uint256 hubCount = router.routePoolCount(quote, opposite);
        bytes32[] memory hub = new bytes32[](hubCount);
        for (uint256 j; j < hubCount; ++j) {
            hub[j] = router.routePoolAt(quote, opposite, j);
        }
        for (uint256 i; i < 4; ++i) {
            address a = c.constituentAssets[i];
            // Real purchases from the imported live route; no ERC20 deal/storage substitution.
            uint256 amountA = router.swapExactInput{value: nativeDepth}(
                address(0), a, nativeDepth, 1, address(this), block.timestamp + 60
            );
            uint256 amountQ;
            if (nativeQuote) {
                GasWrappedNative(quote).deposit{value: nativeDepth}();
                amountQ = nativeDepth;
            } else {
                amountQ = router.swapExactInput{value: nativeDepth}(
                    address(0), quote, nativeDepth, 1, address(this), block.timestamp + 60
                );
            }
            GasV3Factory factory = GasV3Factory(Config.pancakeV3Factory());
            address p = factory.getPool(a, quote, 10000);
            if (p == address(0)) p = factory.createPool(a, quote, 10000);
            bool aFirst = a < quote;
            uint256 amount0 = aFirst ? amountA : amountQ;
            uint256 amount1 = aFirst ? amountQ : amountA;
            (uint160 sqrtP,,,,,,) = GasV3Pool(p).slot0();
            if (sqrtP == 0) {
                sqrtP = uint160(Math.sqrt(FullMath.mulDiv(amount1, uint256(1) << 192, amount0)));
                GasV3Pool(p).initialize(sqrtP);
            }
            int24 spacing = GasV3Pool(p).tickSpacing();
            int24 lower = (TickMath.MIN_TICK / spacing) * spacing;
            int24 upper = (TickMath.MAX_TICK / spacing) * spacing;
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtP, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), amount0, amount1
            );
            mintingPool = p;
            GasV3Pool(p).mint(address(this), lower, upper, liquidity, "");
            mintingPool = address(0);
            bytes32 id = router.pricePoolId(a, quote);
            bytes memory source = abi.encode(address(factory), p);
            if (router.hasPricePool(id)) router.replacePricePool(INutboxRouter.SourceType.V3_POOL, source);
            else assertEq(router.addPricePool(INutboxRouter.SourceType.V3_POOL, source), id);
            bytes32[] memory direct = new bytes32[](1);
            direct[0] = id;
            router.replaceRoute(a, quote, direct);
            bytes32[] memory indirect = new bytes32[](1 + hubCount);
            indirect[0] = id;
            for (uint256 j; j < hubCount; ++j) {
                indirect[j + 1] = hub[j];
            }
            router.replaceRoute(a, opposite, indirect);
            assertEq(router.routePoolCount(a, quote), 1);
            router.validateRoute(a, opposite);
        }
    }

    /// @dev Discover accessed accounts in a reverted rehearsal, then cool every address and
    /// all its slots. This includes nested proxies/pools, not just top-level contracts.
    /// Approvals and preparatory quotes are separate, like preceding wallet transactions.
    function _measure(string memory label, address actor, address target, uint256 value, bytes memory payload)
        internal
        returns (bytes memory result)
    {
        uint256 scratchStart;
        assembly { scratchStart := mload(0x40) }
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(actor, actor);
        (bool rehearsalOk, bytes memory rehearsalResult) = target.call{value: value}(payload);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        if (!rehearsalOk) {
            console2.log("rehearsal failed", label);
            assembly { revert(add(rehearsalResult, 32), mload(rehearsalResult)) }
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < accesses.length; ++i) {
            vm.cool(accesses[i].account);
        }
        vm.cool(target);
        // State-diff ABI data can be megabytes. None is needed after cooling. Reuse
        // its scratch space so a long test does not accumulate quadratic caller
        // memory gas across otherwise independent mainnet transactions. Payload and
        // the caller's live values were allocated before scratchStart and survive.
        assembly { mstore(0x40, scratchStart) }
        vm.prank(actor, actor);
        bool ok;
        (ok, result) = target.call{value: value, gas: EXECUTION_BUDGET}(payload);
        Vm.Gas memory callGas = vm.lastCallGas();
        // Foundry's reported call consumption. The bounded call above is the
        // executable-gas check; this estimate is not a wallet gas-limit recommendation.
        uint256 executionGas = uint256(callGas.gasLimit) - callGas.gasRemaining;
        if (!ok) {
            console2.log("bounded execution failed", label);
            assembly { revert(add(result, 32), mload(result)) }
        }
        uint256 intrinsic = 21_000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
        }
        uint256 total = executionGas + intrinsic;
        console2.log(label, total);
        assertLt(total, MAINNET_TX_CAP, "transaction exceeds BSC cap");
    }

    function _gasBuy(Token t, string memory label, uint256 amount) internal {
        _measure(
            label,
            address(this),
            address(router),
            amount,
            abi.encodeCall(
                INutboxRouter.swapExactInput, (address(0), address(t), amount, 1, address(this), block.timestamp + 60)
            )
        );
    }

    function _runGasLifecycle(bool nativeQuote) internal {
        console2.log(nativeQuote ? "SCENARIO: 4 A-WBNB" : "SCENARIO: 4 A-USDT");
        IPump.IndexConfig memory c = _fourStocks();
        _quoteVenues(c, nativeQuote);
        uint256 fee = pump.createFee() + IIPShare(IPSHARE).createFee() + ICommittee(COMMITTEE).getCreateCommunityFee()
            + ICommittee(COMMITTEE).getCommunitySettingsFee() * 4;
        bytes memory result = _measure(
            "create_4",
            creator,
            address(pump),
            fee,
            abi.encodeCall(ForkCreate.createToken, ("GAS4", bytes32(uint256(888)), c))
        );
        Token t = Token(payable(abi.decode(result, (address))));
        assertEq(t.componentCount(), 4);
        vm.warp(block.timestamp + 16);
        _measure("curve_buy", creator, address(t), 1 ether, abi.encodeCall(Token.buyToken, (0, creator, 0)));
        _measure("curve_sell", creator, address(t), 0, abi.encodeCall(Token.sellToken, (100_000 ether, 0, creator, 0)));
        _measure("curve_final_buy", creator, address(t), 100 ether, abi.encodeCall(Token.buyToken, (0, creator, 0)));
        uint256[] memory mins = _mins(t);
        _measure(
            "list_4",
            keeper,
            address(pump),
            0,
            abi.encodeCall(GasFinalize.finalizeTokenListing, (address(t), mins, block.timestamp + 60))
        );
        assertTrue(t.listed());
        _gasBuy(t, "v4_buy_1BNB", 1 ether);
        uint256 sell = t.balanceOf(address(this)) / 4;
        t.approve(address(router), sell);
        _measure(
            "v4_sell",
            address(this),
            address(router),
            0,
            abi.encodeCall(
                INutboxRouter.swapExactInput, (address(t), address(0), sell, 1, address(this), block.timestamp + 60)
            )
        );
        vm.warp((block.timestamp / 600 + 1) * 600);
        _gasBuy(t, "v4_buy_period_rollover_4pools", 0.1 ether);
        assertGt(calculator.totalInjected(t.nutboxCommunity()), 0);
        BasketTradeData memory data;
        data.legMins = new uint256[](4);
        data.legSqrtPriceLimitsX96 = new uint160[](0);
        data.allowFailedLegs = new bool[](4);
        for (uint256 i; i < 4; ++i) {
            data.legMins[i] = 1;
        }
        _measure(
            "buyback_first_mint_4",
            address(this),
            address(hook),
            0,
            abi.encodeCall(
                TagAISwapHook.executeBuyback, (address(t), 1, block.timestamp + 60, _buybackData(t, abi.encode(data)))
            )
        );
        _measure("claim_for_creator", address(this), address(t), 0, abi.encodeCall(Token.claimBuybackReward, (creator)));
        _measure(
            "claim_for_self", address(this), address(t), 0, abi.encodeCall(Token.claimBuybackReward, (address(this)))
        );
        _measure(
            "transfer_after_rewards",
            address(this),
            address(t),
            0,
            abi.encodeCall(IERC20.transfer, (makeAddr("gas-recipient"), 100 ether))
        );
        _measure(
            "buyback_subsequent_4",
            address(this),
            address(hook),
            0,
            abi.encodeCall(
                TagAISwapHook.executeBuyback, (address(t), 1, block.timestamp + 60, _buybackData(t, abi.encode(data)))
            )
        );
        address u = Config.settlementToken();
        router.swapExactInput{value: 0.1 ether}(address(0), u, 0.1 ether, 10 ether, address(this), block.timestamp + 60);
        IERC20(u).approve(address(basketRouter), 10 ether);
        _measure(
            "index_buy_4",
            address(this),
            address(basketRouter),
            0,
            abi.encodeCall(ForkBasketRouter.buyExactSettlement, (t.indexToken(), 10 ether, 1, bytes(""), address(this)))
        );
        uint256 redeem = IERC20(t.indexToken()).balanceOf(address(this)) / 2;
        IERC20(t.indexToken()).approve(address(basketRouter), redeem);
        _measure(
            "index_sell_4",
            address(this),
            address(basketRouter),
            0,
            abi.encodeCall(ForkBasketRouter.sellExactBasket, (t.indexToken(), redeem, 1, bytes(""), address(this)))
        );
        _gasLp(t);
        _gasBuy(t, "v4_large_buy_5BNB_after_rewards", 5 ether);
    }

    function gasAddLiquidity(address token, address asset, address pair, uint256 tIn, uint256 aIn)
        external
        returns (uint256)
    {
        require(msg.sender == address(this), "ONLY_TEST");
        IERC20(token).transfer(pair, tIn);
        IERC20(asset).transfer(pair, aIn);
        return ForkPair(pair).mint(address(this));
    }

    function _gasLp(Token t) internal {
        (address a,, address p) = t.componentAt(0);
        uint256 tIn = 100 ether;
        uint256 aIn = IERC20(a).balanceOf(p) * tIn / t.balanceOf(p);
        router.swapExactInput{value: 0.01 ether}(address(0), a, 0.01 ether, aIn, address(this), block.timestamp + 60);
        bytes memory minted = _measure(
            "v2_add_liquidity_after_rewards",
            address(this),
            address(this),
            0,
            abi.encodeCall(this.gasAddLiquidity, (address(t), a, p, tIn, aIn))
        );
        uint256 lp = abi.decode(minted, (uint256));
        address staking = ICommunity(t.nutboxCommunity()).activedPools(0);
        IERC20(p).approve(staking, lp);
        uint256 operationFee = ICommittee(COMMITTEE).getPoolOperationFee();
        _measure(
            "lp_stake_4_active_pools", address(this), staking, operationFee, abi.encodeCall(ForkStake.deposit, (lp))
        );
        vm.warp(block.timestamp + 3600);
        _measure(
            "lp_unstake_4_active_pools", address(this), staking, operationFee, abi.encodeCall(ForkStake.withdraw, (lp))
        );
        IERC20(p).transfer(p, lp);
        _measure(
            "v2_remove_liquidity_after_rewards", address(this), p, 0, abi.encodeCall(ForkPair.burn, (address(this)))
        );
    }

    function test_gas_fourBnbQuotedAssets() public {
        _runGasLifecycle(true);
    }

    function test_gas_fourUsdtQuotedAssets() public {
        _runGasLifecycle(false);
    }

    function test_gas_fourThinQuotesSlippageRollsBack() public {
        IPump.IndexConfig memory c = _fourStocks();
        _quoteVenuesWithDepth(c, true, 20 ether);
        Token t = _create(c);
        _fill(t);
        uint256 beforeBnb = address(t).balance;
        uint256[] memory mins = _mins(t);
        // Four legs buy ~1.25 BNB each. This shallow fixture cannot satisfy a 5% bound.
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("PriceUnavailable()")));
        pump.finalizeTokenListing(address(t), mins, block.timestamp + 60);
        assertTrue(t.listingPending());
        assertFalse(t.listed());
        assertEq(address(t).balance, beforeBnb);
        assertEq(t.balanceOf(address(hook)), 0);
        assertEq(t.indexToken(), address(0));
        for (uint256 i; i < 4; ++i) {
            (,, address pair) = t.componentAt(i);
            assertEq(IERC20(pair).totalSupply(), 0);
        }
        pump.adminRecoverFailedListing(address(t));
        vm.prank(creator, creator);
        t.sellToken(1_000_000 ether, 0, creator, 0);
        assertLt(t.bondingCurveSupply(), 650_000_000 ether);
    }

    function _planQuote(ForkSplitBuyRouter aggregate, Token t, uint256[] memory plan)
        internal
        returns (uint256 output)
    {
        uint256 snapshot = vm.snapshotState();
        uint256 amount;
        for (uint256 i; i < plan.length; ++i) {
            amount += plan[i];
        }
        try aggregate.buy{value: amount}(t, plan, 1, block.timestamp + 60, address(this)) returns (uint256 out) {
            output = out;
        } catch {
            output = 0;
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    /// @dev Off-chain quote simulation, deliberately outside measured execution. Twenty
    /// slices give 5% allocation resolution; this is a marginal greedy approximation,
    /// not a proof of the continuous global optimum or a production quote service.
    function _greedyPlan(ForkSplitBuyRouter aggregate, Token t, uint256 amount)
        internal
        returns (uint256[] memory plan)
    {
        uint256 snapshot = vm.snapshotState();
        uint256 count = t.componentCount() + 1;
        plan = new uint256[](count);
        uint256 allocated;
        for (uint256 step; step < 20; ++step) {
            uint256 chunk = step == 19 ? amount - allocated : amount / 20;
            uint256 best;
            uint256 bestOut;
            for (uint256 i; i < count; ++i) {
                uint256[] memory candidate = new uint256[](count);
                candidate[i] = chunk;
                uint256 out = _planQuote(aggregate, t, candidate);
                if (out > bestOut) {
                    bestOut = out;
                    best = i;
                }
            }
            require(bestOut > 0, "NO_QUOTABLE_ROUTE");
            uint256[] memory execution = new uint256[](count);
            execution[best] = chunk;
            aggregate.buy{value: chunk}(t, execution, 1, block.timestamp + 60, address(this));
            plan[best] += chunk;
            allocated += chunk;
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _aggregateComparison(bool nativeQuote, uint256 amount, bool rewardsActive) internal {
        console2.log(nativeQuote ? "AGGREGATE: 4 A-WBNB" : "AGGREGATE: 4 A-USDT");
        console2.log("BNB input", amount);
        IPump.IndexConfig memory c = _fourStocks();
        _quoteVenues(c, nativeQuote);
        Token t = _create(c);
        _fill(t);
        _list(t);
        if (rewardsActive) {
            console2.log("reward accounting active", true);
            _buyT(t, 0.1 ether);
            BasketTradeData memory data;
            data.legMins = new uint256[](4);
            data.legSqrtPriceLimitsX96 = new uint160[](0);
            data.allowFailedLegs = new bool[](4);
            for (uint256 i; i < 4; ++i) {
                data.legMins[i] = 1;
            }
            hook.executeBuyback(address(t), 1, block.timestamp + 60, _buybackData(t, abi.encode(data)));
            assertGt(t.accIndexRewardPerToken(), 0);
        }
        ForkSplitBuyRouter aggregate = new ForkSplitBuyRouter(INutboxRouter(address(router)));
        uint256[] memory direct = new uint256[](5);
        direct[0] = amount;
        uint256[] memory equal = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            equal[i] = i == 4 ? amount - (amount / 5) * 4 : amount / 5;
        }
        uint256 directOut = _planQuote(aggregate, t, direct);
        uint256 equalOut = _planQuote(aggregate, t, equal);
        uint256[] memory optimized = _greedyPlan(aggregate, t, amount);
        uint256 optimizedOut = _planQuote(aggregate, t, optimized);
        // A frontend should retain better simple candidates when discretization loses.
        if (directOut > optimizedOut) {
            optimized = direct;
            optimizedOut = directOut;
        }
        if (equalOut > optimizedOut) {
            optimized = equal;
            optimizedOut = equalOut;
        }
        assertGe(optimizedOut, directOut);
        assertGe(optimizedOut, equalOut);
        console2.log("direct T received", directOut);
        console2.log("equal T received", equalOut);
        console2.log("optimized T received", optimizedOut);
        uint256 active;
        for (uint256 i; i < 5; ++i) {
            if (optimized[i] != 0) ++active;
            console2.log(string.concat("allocation route ", vm.toString(i)), optimized[i]);
        }
        console2.log("optimized active routes", active);
        address buyer = makeAddr("aggregate-wallet");
        vm.deal(buyer, 100 ether);
        // A stale or malicious frontend minimum must revert the entire split.
        uint256 reserveBefore = hook.buybackBnbReserve(address(t));
        vm.expectRevert(bytes("SLIPPAGE"));
        aggregate.buy{value: amount}(t, optimized, type(uint256).max, block.timestamp + 60, buyer);
        assertEq(t.balanceOf(buyer), 0);
        assertEq(hook.buybackBnbReserve(address(t)), reserveBefore);
        _measurePlan("aggregate_direct_gas", aggregate, t, direct, directOut, buyer, amount);
        _measurePlan("aggregate_equal_gas", aggregate, t, equal, equalOut, buyer, amount);
        _measurePlan("aggregate_optimized_gas", aggregate, t, optimized, optimizedOut, buyer, amount);
    }

    function _measurePlan(
        string memory label,
        ForkSplitBuyRouter aggregate,
        Token t,
        uint256[] memory plan,
        uint256 quotedOut,
        address buyer,
        uint256 amount
    ) internal {
        uint256 snapshot = vm.snapshotState();
        bytes memory result = _measure(
            label,
            buyer,
            address(aggregate),
            amount,
            abi.encodeCall(ForkSplitBuyRouter.buy, (t, plan, quotedOut * 995 / 1000, block.timestamp + 60, buyer))
        );
        uint256 received = abi.decode(result, (uint256));
        assertEq(received, quotedOut);
        assertEq(t.balanceOf(buyer), received);
        assertEq(t.balanceOf(address(aggregate)), 0);
        assertEq(address(aggregate).balance, 0);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function test_gas_aggregate_bnbQuotes_small() public {
        _aggregateComparison(true, 0.1 ether, false);
    }

    function test_gas_aggregate_bnbQuotes_medium() public {
        _aggregateComparison(true, 1 ether, false);
    }

    function test_gas_aggregate_bnbQuotes_large() public {
        _aggregateComparison(true, 5 ether, false);
    }

    function test_gas_aggregate_usdtQuotes_small() public {
        _aggregateComparison(false, 0.1 ether, false);
    }

    function test_gas_aggregate_usdtQuotes_medium() public {
        _aggregateComparison(false, 1 ether, false);
    }

    function test_gas_aggregate_usdtQuotes_large() public {
        _aggregateComparison(false, 5 ether, false);
    }

    function test_gas_aggregate_bnbQuotes_afterRewards() public {
        _aggregateComparison(true, 1 ether, true);
    }

    function test_gas_aggregate_usdtQuotes_afterRewards() public {
        _aggregateComparison(false, 1 ether, true);
    }
}
