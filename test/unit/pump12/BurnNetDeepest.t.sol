// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump12ListingTest, ListingTestUsdG} from "./Pump12Listing.t.sol";
import {BurnNet} from "../../../src/pump12/burnnet/BurnNet.sol";
import {Token12} from "../../../src/pump12/Token12.sol";
import {NetNetHook} from "../../../src/pump12/NetNetHook.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Real PoolManager swaps, both currency orders. Only the oracle return
/// is mocked after initial funding, to test spot/TWAP divergence independently.
contract BurnNetDeepestTest is Pump12ListingTest {
    using StateLibrary for IPoolManager;

    function _prepareDeepest(bool usdg0) internal returns (PoolId id, BurnNet net) {
        if ((USDG < address(token)) != usdg0) {
            bool found;
            for (uint256 i = 1; i < 100; ++i) {
                bytes32 salt = bytes32(i);
                if ((USDG < pump.predictTokenAddress(creator, salt)) != usdg0) continue;
                vm.prank(creator);
                token = Token12(pump.createToken(_params(salt, "DEEP")));
                found = true;
                break;
            }
            assertTrue(found);
            vm.prank(buyer);
            ListingTestUsdG(USDG).approve(address(token), type(uint256).max);
        }
        (id,) = _fillAndList();
        net = BurnNet(token.burnNet());
        // Seed both real eligible swap fees and a non-eligible contribution.
        ListingTestUsdG(USDG).mint(trader, 10e6);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(swapRouter), 10e6);
        _swap(_poolKey(), usdg0, -int256(10e6));
        vm.stopPrank();
        _addPending(id, 100e6);
        uint40 start = uint40(block.timestamp);
        _checkpointFor(id, start, 16);
        vm.warp(start + 8 hours + 1);
        net.poke();
        assertGt(net.tierState(6).liquidity, 0);
        assertGt(net.tierState(6).eligiblePrincipalUSDG, 0);
        assertLt(net.tierState(6).eligiblePrincipalUSDG, net.tierState(6).unfilledUSDG);
        assertEq(net.usdgIsCurrency0(), usdg0);
    }

    function _addPending(PoolId id, uint256 amount) internal {
        ListingTestUsdG(USDG).mint(trader, amount);
        vm.startPrank(trader);
        ListingTestUsdG(USDG).approve(address(hook), amount);
        hook.addPendingUSDG(id, amount);
        vm.stopPrank();
    }

    function _moveTo(PoolId id, uint160 target) internal {
        (uint160 current,,,) = manager.getSlot0(id);
        if (current == target) return;
        bool zeroForOne = target < current;
        if (zeroForOne == _usdgIsCurrency0()) {
            ListingTestUsdG(USDG).mint(trader, 100e6);
            vm.startPrank(trader);
            ListingTestUsdG(USDG).approve(address(swapRouter), type(uint256).max);
            _swapWithLimit(_poolKey(), zeroForOne, -int256(100e6), target);
        } else {
            vm.startPrank(buyer);
            token.approve(address(swapRouter), type(uint256).max);
            _swapWithLimit(_poolKey(), zeroForOne, -int256(500_000_000e18), target);
        }
        vm.stopPrank();
        (current,,,) = manager.getSlot0(id);
        assertEq(current, target, "must reach the requested price");
    }

    function _pokeAtTwap(PoolId id, BurnNet net, uint256 twap) internal returns (uint256) {
        vm.warp(net.nextPokeAt());
        vm.mockCall(address(hook), abi.encodeWithSelector(NetNetHook.validTWAP.selector, id), abi.encode(twap));
        return net.poke();
    }

    function _assertAccounting(BurnNet net) internal view {
        assertEq(net.activeReserveUSDG(), net.activeLiquidUSDG() + net.activePositionPrincipalUSDG());
        assertEq(net.activeEligibleTradeFeeUSDG(), net.activeEligibleLiquidUSDG() + net.activeEligiblePositionUSDG());
        assertEq(ListingTestUsdG(USDG).balanceOf(address(net)), net.activeLiquidUSDG());
        assertLe(net.activeEligibleLiquidUSDG(), net.activeLiquidUSDG());
        assertLe(net.activeEligiblePositionUSDG(), net.activePositionPrincipalUSDG());
    }

    function _assertSameWall(PoolId id, BurnNet net, BurnNet.Tier memory beforeTier, uint64 gen) internal view {
        BurnNet.Tier memory afterTier = net.tierState(6);
        assertEq(abi.encode(afterTier), abi.encode(beforeTier));
        (uint128 actualLiquidity,,) = manager.getPositionInfo(
            id,
            address(net),
            beforeTier.tickLower,
            beforeTier.tickUpper,
            keccak256(abi.encodePacked("PUMP12_BURN_NET", gen, uint8(6)))
        );
        assertEq(actualLiquidity, beforeTier.liquidity, "real LP must remain intact");
    }

    function _partial(bool usdg0, uint8 offset) internal {
        (PoolId id, BurnNet net) = _prepareDeepest(usdg0);
        BurnNet.Tier memory tier = net.tierState(6);
        _moveTo(id, TickMath.getSqrtPriceAtTick(tier.tickLower + int24(uint24(offset))));
        _addPending(id, 10e6);
        uint256 pending = hook.pendingUSDG(id);
        uint256 eligible = hook.pendingEligibleTradeFeeUSDG(id);
        uint256 activated = net.totalEligibleTradeFeeActivatedUSDG();
        uint256 keeper = net.totalKeeperPaidUSDG();
        uint256 anchorBefore = net.anchor();
        uint64 gen = net.generation();
        uint64 anchorVersionBefore = net.anchorVersion();
        // Repeated pokes preserve this position only when the oracle does not
        // move the anchor. Exactly 50% does not trigger the strict reset threshold.
        for (uint256 j; j < 3; ++j) {
            uint256 twap = j == 0 ? anchorBefore : j == 1 ? anchorBefore / 2 : anchorBefore * 3 / 4;
            assertEq(_pokeAtTwap(id, net, twap), 0);
            _assertSameWall(id, net, tier, gen);
            assertEq(net.anchor(), anchorBefore);
            assertEq(net.anchorVersion(), anchorVersionBefore);
            assertEq(net.generation(), gen);
            assertEq(net.mintFrozenUntil(), 0);
            assertEq(hook.pendingUSDG(id), pending);
            assertEq(hook.pendingEligibleTradeFeeUSDG(id), eligible);
            assertEq(net.totalEligibleTradeFeeActivatedUSDG(), activated);
            assertEq(net.totalKeeperPaidUSDG(), keeper);
            _assertAccounting(net);
        }
        uint256 supply = token.totalSupply();
        vm.expectRevert(BurnNet.NothingToHarvest.selector);
        net.harvest();
        assertEq(token.totalSupply(), supply);
    }

    function _anchorPriority(bool usdg0, bool downward) internal {
        (PoolId id, BurnNet net) = _prepareDeepest(usdg0);
        BurnNet.Tier memory tier = net.tierState(6);
        _moveTo(id, TickMath.getSqrtPriceAtTick(tier.tickLower + 30));
        _addPending(id, 10e6);
        uint256 oldAnchor = net.anchor();
        uint64 oldVersion = net.anchorVersion();
        uint64 oldGen = net.generation();
        uint256 oldSupply = token.totalSupply();
        uint256 oldBurned = net.totalBurned();
        uint256 pending = hook.pendingUSDG(id);
        uint256 activated = _pokeAtTwap(id, net, downward ? oldAnchor / 3 : oldAnchor * 2);

        // The original, still partially filled deepest LP must be settled and
        // burned BEFORE any generation/salt update; no old position is orphaned.
        (uint128 oldLiquidity,,) = manager.getPositionInfo(
            id,
            address(net),
            tier.tickLower,
            tier.tickUpper,
            keccak256(abi.encodePacked("PUMP12_BURN_NET", oldGen, uint8(6)))
        );
        assertEq(oldLiquidity, 0);
        assertEq(net.anchorVersion(), oldVersion + 1);
        assertGt(net.totalBurned(), oldBurned);
        assertEq(oldSupply - token.totalSupply(), net.totalBurned() - oldBurned);
        if (downward) {
            assertEq(net.anchor(), oldAnchor / 3);
            assertEq(net.generation(), oldGen + 1);
            assertEq(net.mintFrozenUntil(), block.timestamp + 24 hours);
            assertGt(activated, 0);
            assertEq(hook.pendingUSDG(id), 0);
            BurnNet.Tier memory newTier = net.tierState(6);
            assertGt(newTier.liquidity, 0);
            (uint128 newLiquidity,,) = manager.getPositionInfo(
                id,
                address(net),
                newTier.tickLower,
                newTier.tickUpper,
                keccak256(abi.encodePacked("PUMP12_BURN_NET", oldGen + 1, uint8(6)))
            );
            assertEq(newLiquidity, newTier.liquidity);
        } else {
            assertEq(net.anchor(), oldAnchor * 10_800 / 10_000);
            assertEq(net.generation(), oldGen);
            assertEq(net.mintFrozenUntil(), 0);
            // The oracle can lag spot. Anchor priority must not force new USDG
            // into an underwater range or revert the update if no range is valid.
            assertEq(activated, 0);
            assertEq(hook.pendingUSDG(id), pending);
            assertEq(net.activePositionPrincipalUSDG(), 0);
            assertGt(net.activeLiquidUSDG(), 0);
            assertGt(net.activeEligibleLiquidUSDG(), 0);
        }
        _assertAccounting(net);
    }

    function test_deepestPartialAnchorResetTakesPriority_currency0() public {
        _anchorPriority(true, true);
    }

    function test_deepestPartialAnchorResetTakesPriority_currency1() public {
        _anchorPriority(false, true);
    }

    function test_deepestPartialAnchorIncreaseTakesPriority_currency0() public {
        _anchorPriority(true, false);
    }

    function test_deepestPartialAnchorIncreaseTakesPriority_currency1() public {
        _anchorPriority(false, false);
    }

    function test_deepestPartial_currency0() public {
        _partial(true, 30);
    }

    function test_deepestPartial_currency1() public {
        _partial(false, 30);
    }

    function testFuzz_deepestPartial(bool usdg0, uint8 offset) public {
        _partial(usdg0, uint8(bound(offset, 1, 59)));
    }

    function _entryBoundaryAndRecovery(bool usdg0) internal {
        (PoolId id, BurnNet net) = _prepareDeepest(usdg0);
        BurnNet.Tier memory tier = net.tierState(6);
        uint64 gen = net.generation();
        uint160 entry = TickMath.getSqrtPriceAtTick(usdg0 ? tier.tickLower : tier.tickUpper);
        // One sqrt-price unit inside the entry: raw slot0.tick can still equal
        // the entry tick. No accidental two-token placement may occur.
        _moveTo(id, usdg0 ? entry + 1 : entry - 1);
        _addPending(id, 10e6);
        uint256 pending = hook.pendingUSDG(id);
        assertEq(_pokeAtTwap(id, net, net.anchor()), 0);
        _assertSameWall(id, net, tier, gen);
        assertEq(hook.pendingUSDG(id), pending);
        _moveTo(id, entry);
        pending = hook.pendingUSDG(id);
        assertEq(_pokeAtTwap(id, net, net.anchor()), 0, "equal highest price must not fund");
        _assertSameWall(id, net, tier, gen);
        assertEq(hook.pendingUSDG(id), pending);
        // Recover above the highest price: fund the SAME range and position.
        _moveTo(id, TickMath.getSqrtPriceAtTick(usdg0 ? tier.tickLower - 1 : tier.tickUpper + 1));
        pending = hook.pendingUSDG(id);
        uint256 activatedBefore = net.totalEligibleTradeFeeActivatedUSDG();
        uint256 pendingEligible = hook.pendingEligibleTradeFeeUSDG(id);
        uint256 bounty = pending / 1000;
        if (bounty > 1e6) bounty = 1e6;
        uint256 activated = _pokeAtTwap(id, net, net.anchor());
        assertGt(activated, 0);
        assertEq(hook.pendingUSDG(id), 0);
        assertEq(net.tierState(6).tickLower, tier.tickLower);
        assertEq(net.tierState(6).tickUpper, tier.tickUpper);
        assertGt(net.tierState(6).liquidity, tier.liquidity);
        assertEq(
            net.totalEligibleTradeFeeActivatedUSDG() - activatedBefore,
            pendingEligible - pendingEligible * bounty / pending
        );
        assertEq(activated, pending - bounty, "keeper bounty only on actual activation");
        _assertAccounting(net);
    }

    function test_deepestEntryBoundaryAndRecovery_currency0() public {
        _entryBoundaryAndRecovery(true);
    }

    function test_deepestEntryBoundaryAndRecovery_currency1() public {
        _entryBoundaryAndRecovery(false);
    }

    function _cross(bool usdg0, bool reset) internal {
        (PoolId id, BurnNet net) = _prepareDeepest(usdg0);
        BurnNet.Tier memory tier = net.tierState(6);
        uint64 gen = net.generation();
        uint256 anchorBefore = net.anchor();
        uint160 exitPrice = TickMath.getSqrtPriceAtTick(usdg0 ? tier.tickUpper : tier.tickLower);
        // Last sqrt-price unit before the exit is still protected.
        _moveTo(id, usdg0 ? exitPrice - 1 : exitPrice + 1);
        assertEq(_pokeAtTwap(id, net, anchorBefore), 0);
        _assertSameWall(id, net, tier, gen);
        _moveTo(id, exitPrice);
        uint256 supply = token.totalSupply();
        if (reset) {
            _pokeAtTwap(id, net, anchorBefore / 3);
            assertEq(net.generation(), gen + 1);
            assertEq(net.anchor(), anchorBefore / 3);
            assertEq(net.mintFrozenUntil(), block.timestamp + 24 hours);
            assertGt(net.tierState(6).liquidity, 0);
            assertEq(hook.pendingUSDG(id), 0);
        } else {
            net.harvest();
            assertEq(net.tierState(6).liquidity, 0);
            assertEq(net.generation(), gen);
            _pokeAtTwap(id, net, anchorBefore);
            assertEq(net.tierState(6).liquidity, 0);
            assertGt(hook.pendingUSDG(id), 0, "underwater ladder leaves Pending untouched");
        }
        assertLt(token.totalSupply(), supply);
        (uint128 oldLiquidity,,) = manager.getPositionInfo(
            id,
            address(net),
            tier.tickLower,
            tier.tickUpper,
            keccak256(abi.encodePacked("PUMP12_BURN_NET", gen, uint8(6)))
        );
        assertEq(oldLiquidity, 0);
        _assertAccounting(net);
    }

    function test_deepestCrossAndHarvest_currency0() public {
        _cross(true, false);
    }

    function test_deepestCrossAndHarvest_currency1() public {
        _cross(false, false);
    }

    function test_deepestCrossAndReset_currency0() public {
        _cross(true, true);
    }

    function test_deepestCrossAndReset_currency1() public {
        _cross(false, true);
    }
}
