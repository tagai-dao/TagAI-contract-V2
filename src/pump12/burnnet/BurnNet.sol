// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {CurrencySettler} from "../../utils/CurrencySettler.sol";
import {BurnNetMath} from "../libraries/BurnNetMath.sol";

interface INetNetHookBurnNet {
    function validTWAP(PoolId id) external view returns (uint256 priceWad);
    function validTWAPAfter(PoolId id, uint40 notBefore) external view returns (uint256 priceWad);
    function pendingUSDG(PoolId id) external view returns (uint256 amount);
    function pullPendingUSDG(PoolId id, address keeper, uint256 keeperBounty)
        external
        returns (uint256 activated, uint256 eligibleActivated, uint256 eligibleKeeperPaid);
}

interface IToken12BurnNet {
    function totalSupply() external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @title BurnNet
/// @notice Per-token Anchor state machine and seven-rung USDG buyback net.
contract BurnNet is IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint8 private constant ACTION_DEPLOY = 1;
    uint8 private constant ACTION_HARVEST = 2;
    uint8 private constant ACTION_SETTLE_ALL = 3;
    uint8 private constant ACTION_MIGRATE = 4;
    uint8 private constant ACTION_SETTLE_TOUCHED = 5;

    uint8 public constant TIER_COUNT = 7;
    int24 public constant TICK_SPACING = 60;
    uint40 public constant POKE_INTERVAL = 8 hours;
    uint40 public constant DOWNWARD_RESET_FREEZE = 24 hours;
    uint16 public constant MAX_ANCHOR_INCREASE_BPS = 800;
    uint16 public constant DEEPEST_TIER_PRICE_BPS = 5_000;
    uint16 public constant KEEPER_BOUNTY_BPS = 10;
    uint256 public constant MAX_KEEPER_BOUNTY_RAW = 1e6;

    error AlreadyInitialized();
    error InvalidInitialization();
    error PokeTooEarly(uint40 nextPokeAt);
    error PendingAccountingMismatch();
    error OnlyPoolManager();
    error InvalidUnlockAction();
    error UnexpectedPoolDelta();
    error NothingToHarvest();

    struct Tier {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 unfilledUSDG;
        uint256 eligiblePrincipalUSDG;
    }

    address public hook;
    address public token;
    IERC20 public usdg;
    IPoolManager public poolManager;
    PoolId public poolId;
    bool public initialized;
    bool public usdgIsCurrency0;

    uint256 public initialAnchor;
    uint256 public anchor;
    uint64 public anchorVersion;
    uint64 public generation;
    uint40 public listTime;
    uint40 public nextPokeAt;
    uint40 public lastDownwardResetAt;
    uint40 public mintFrozenUntil;

    uint256 public activeReserveUSDG;
    uint256 public activeLiquidUSDG;
    uint256 public activePositionPrincipalUSDG;
    uint256 public activeEligibleTradeFeeUSDG;
    uint256 public activeEligibleLiquidUSDG;
    uint256 public activeEligiblePositionUSDG;
    uint256 public consumedActiveUSDG;
    uint256 public consumedEligibleTradeFeeUSDG;
    uint256 public totalUSDGConvertedToToken;
    uint256 public totalBurned;
    uint256 public reserveSnapshotUSDG;
    uint256 public eligibleTradeFeeReserveUSDG;
    uint40 public snapshotAt;
    uint256 public totalKeeperPaidUSDG;
    uint256 public eligibleUSDGSpentOnKeeper;

    Tier[7] private _tiers;

    event BurnNetInitialized(
        PoolId indexed poolId, address indexed token, uint256 initialAnchor, uint40 listTime, uint40 nextPokeAt
    );
    event AnchorUpdated(
        PoolId indexed poolId, uint256 oldAnchor, uint256 newAnchor, uint256 marketPrice, uint64 anchorVersion
    );
    event DownwardReset(
        PoolId indexed poolId, uint64 indexed generation, uint256 oldAnchor, uint256 newAnchor, uint40 mintFrozenUntil
    );
    event TierFunded(
        uint64 indexed generation,
        uint8 indexed tier,
        uint256 usdgPrincipal,
        uint256 eligiblePrincipal,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event TierHarvested(
        uint64 indexed generation,
        uint8 indexed tier,
        uint256 usdgConverted,
        uint256 eligibleConsumed,
        uint256 tokenBurned,
        uint256 usdgReturned
    );
    event Harvested(address indexed caller, uint256 tokenBurned, uint256 usdgReturned);
    event Poked(
        PoolId indexed poolId,
        address indexed keeper,
        uint256 marketPrice,
        uint256 pendingBefore,
        uint256 keeperPaid,
        uint256 activated,
        uint256 eligibleActivated,
        uint256 reserveSnapshot,
        uint64 generation,
        uint64 anchorVersion
    );

    constructor() {
        initialized = true;
    }

    function initialize(
        address hook_,
        address token_,
        address usdg_,
        address poolManager_,
        PoolId poolId_,
        uint256 initialAnchor_,
        uint40 listTime_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            hook_ == address(0) || token_ == address(0) || usdg_ == address(0) || poolManager_ == address(0)
                || PoolId.unwrap(poolId_) == bytes32(0) || initialAnchor_ == 0 || listTime_ != block.timestamp
        ) revert InvalidInitialization();

        initialized = true;
        hook = hook_;
        token = token_;
        usdg = IERC20(usdg_);
        poolManager = IPoolManager(poolManager_);
        poolId = poolId_;
        usdgIsCurrency0 = usdg_ < token_;
        initialAnchor = initialAnchor_;
        anchor = initialAnchor_;
        anchorVersion = 1;
        generation = 1;
        listTime = listTime_;
        nextPokeAt = listTime_ + POKE_INTERVAL;
        emit BurnNetInitialized(poolId_, token_, initialAnchor_, listTime_, nextPokeAt);
    }

    function tierState(uint8 tier) external view returns (Tier memory) {
        if (tier >= TIER_COUNT) revert BurnNetMath.InvalidTier(tier);
        return _tiers[tier];
    }

    function totalUnfilledUSDG() public view returns (uint256 total) {
        for (uint8 i; i < TIER_COUNT; ++i) {
            total += _tiers[i].unfilledUSDG;
        }
    }

    function kappa3() public view returns (uint256) {
        return BurnNetMath.kappa3Wad(_tiers[6].unfilledUSDG, anchor, IToken12BurnNet(token).totalSupply());
    }

    function poke() external nonReentrant returns (uint256 activated) {
        if (block.timestamp < nextPokeAt) revert PokeTooEarly(nextPokeAt);
        INetNetHookBurnNet hook_ = INetNetHookBurnNet(hook);
        uint256 marketPrice = hook_.validTWAP(poolId);

        bool downwardReset = marketPrice < Math.mulDiv(anchor, DEEPEST_TIER_PRICE_BPS, BPS);
        bool anchorWillMove = downwardReset || _normalAnchorCandidate(marketPrice) != anchor;
        uint256[7] memory migrationUSDG;
        uint256[7] memory migrationEligible;
        if (anchorWillMove && _hasAnyPosition()) {
            bytes memory settlement = poolManager.unlock(abi.encode(ACTION_SETTLE_ALL, false, msg.sender));
            (migrationUSDG, migrationEligible) = abi.decode(settlement, (uint256[7], uint256[7]));
        } else if (_hasTouchedTier()) {
            bytes memory settlement = poolManager.unlock(abi.encode(ACTION_SETTLE_TOUCHED, false, msg.sender));
            (migrationUSDG, migrationEligible) = abi.decode(settlement, (uint256[7], uint256[7]));
        }
        _updateAnchor(marketPrice);

        uint256 pendingBefore = hook_.pendingUSDG(poolId);
        uint256 keeperBounty = Math.mulDiv(pendingBefore, KEEPER_BOUNTY_BPS, BPS);
        if (keeperBounty > MAX_KEEPER_BOUNTY_RAW) keeperBounty = MAX_KEEPER_BOUNTY_RAW;

        uint256 eligibleActivated;
        uint256 eligibleKeeperPaid;
        if (pendingBefore != 0) {
            (activated, eligibleActivated, eligibleKeeperPaid) = hook_.pullPendingUSDG(poolId, msg.sender, keeperBounty);
            if (pendingBefore != keeperBounty + activated) revert PendingAccountingMismatch();
            activeReserveUSDG += activated;
            activeLiquidUSDG += activated;
            activeEligibleTradeFeeUSDG += eligibleActivated;
            activeEligibleLiquidUSDG += eligibleActivated;
            totalKeeperPaidUSDG += keeperBounty;
            eligibleUSDGSpentOnKeeper += eligibleKeeperPaid;
        }

        if (_sum(migrationUSDG) != 0) {
            poolManager.unlock(abi.encode(ACTION_MIGRATE, false, msg.sender, migrationUSDG, migrationEligible));
        }
        if (activeLiquidUSDG != 0) poolManager.unlock(abi.encode(ACTION_DEPLOY, false, msg.sender));
        reserveSnapshotUSDG = activeReserveUSDG;
        eligibleTradeFeeReserveUSDG = activeEligibleTradeFeeUSDG;
        // The snapshot already reflects every settlement performed by this poke.
        // Consumption counters therefore cover only activity after this snapshot.
        consumedActiveUSDG = 0;
        consumedEligibleTradeFeeUSDG = 0;
        snapshotAt = uint40(block.timestamp);
        nextPokeAt = uint40(block.timestamp) + POKE_INTERVAL;

        emit Poked(
            poolId,
            msg.sender,
            marketPrice,
            pendingBefore,
            keeperBounty,
            activated,
            eligibleActivated,
            reserveSnapshotUSDG,
            generation,
            anchorVersion
        );
    }

    /// @notice Removes only fully crossed rungs and burns every Token received; it never reads the oracle.
    function harvest() external nonReentrant returns (uint256 tokenAmountBurned) {
        if (!_hasFullyCrossedTier()) revert NothingToHarvest();
        bytes memory result = poolManager.unlock(abi.encode(ACTION_HARVEST, true, msg.sender));
        (tokenAmountBurned,) = abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint8 action = abi.decode(data, (uint8));
        if (action == ACTION_DEPLOY) {
            _deployLiquid();
            return bytes("");
        }
        if (action == ACTION_HARVEST) {
            (, bool emitSummary, address caller) = abi.decode(data, (uint8, bool, address));
            (uint256 burned, uint256 returnedUSDG) = _harvestCrossed();
            if (emitSummary) emit Harvested(caller, burned, returnedUSDG);
            return abi.encode(burned, returnedUSDG);
        }
        if (action == ACTION_SETTLE_ALL) {
            (uint256[7] memory returnedUSDG, uint256[7] memory returnedEligible) = _settleAll();
            return abi.encode(returnedUSDG, returnedEligible);
        }
        if (action == ACTION_MIGRATE) {
            (,,, uint256[7] memory amounts, uint256[7] memory eligibleAmounts) =
                abi.decode(data, (uint8, bool, address, uint256[7], uint256[7]));
            _migrate(amounts, eligibleAmounts);
            return bytes("");
        }
        if (action == ACTION_SETTLE_TOUCHED) {
            (uint256[7] memory returnedUSDG, uint256[7] memory returnedEligible) = _settleTouched();
            return abi.encode(returnedUSDG, returnedEligible);
        }
        revert InvalidUnlockAction();
    }

    function _updateAnchor(uint256 marketPrice) private {
        uint256 oldAnchor = anchor;
        if (marketPrice < Math.mulDiv(oldAnchor, DEEPEST_TIER_PRICE_BPS, BPS)) {
            anchor = marketPrice;
            ++anchorVersion;
            ++generation;
            lastDownwardResetAt = uint40(block.timestamp);
            mintFrozenUntil = uint40(block.timestamp) + DOWNWARD_RESET_FREEZE;
            emit DownwardReset(poolId, generation, oldAnchor, marketPrice, mintFrozenUntil);
            return;
        }
        uint256 newAnchor = _normalAnchorCandidate(marketPrice);
        if (newAnchor != oldAnchor) {
            anchor = newAnchor;
            ++anchorVersion;
            emit AnchorUpdated(poolId, oldAnchor, newAnchor, marketPrice, anchorVersion);
        }
    }

    function _normalAnchorCandidate(uint256 marketPrice) private view returns (uint256 newAnchor) {
        uint256 oldAnchor = anchor;
        uint256 cap = Math.mulDiv(oldAnchor, BPS + MAX_ANCHOR_INCREASE_BPS, BPS);
        newAnchor = marketPrice < cap ? marketPrice : cap;
        if (newAnchor < oldAnchor) newAnchor = oldAnchor;
    }

    function _migrate(uint256[7] memory amounts, uint256[7] memory eligibleAmounts) private {
        uint8 fallbackTier = _deepestValidTier();
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (amounts[i] == 0 || _tierIsPureUSDG(i)) continue;
            if (fallbackTier == type(uint8).max) continue;
            amounts[fallbackTier] += amounts[i];
            eligibleAmounts[fallbackTier] += eligibleAmounts[i];
            amounts[i] = 0;
            eligibleAmounts[i] = 0;
        }
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (amounts[i] != 0) _placeTier(i, amounts[i], eligibleAmounts[i]);
        }
    }

    function _deployLiquid() private {
        uint256 liquid = activeLiquidUSDG;
        uint256 eligibleLiquid = activeEligibleLiquidUSDG;
        uint256[7] memory parts = BurnNetMath.allocate(
            liquid,
            BurnNetMath.kappa3Wad(_tiers[6].unfilledUSDG, anchor, IToken12BurnNet(token).totalSupply()),
            _tiers[6].unfilledUSDG,
            totalUnfilledUSDG()
        );
        uint256[7] memory eligibleParts;
        uint256 assignedEligible;
        for (uint8 i; i < TIER_COUNT; ++i) {
            eligibleParts[i] =
                i == TIER_COUNT - 1 ? eligibleLiquid - assignedEligible : Math.mulDiv(eligibleLiquid, parts[i], liquid);
            assignedEligible += eligibleParts[i];
        }

        uint8 fallbackTier = _deepestValidTier();
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (parts[i] == 0 || _tierIsPureUSDG(i)) continue;
            if (fallbackTier == type(uint8).max) continue;
            parts[fallbackTier] += parts[i];
            eligibleParts[fallbackTier] += eligibleParts[i];
            parts[i] = 0;
            eligibleParts[i] = 0;
        }
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (parts[i] != 0) _placeTier(i, parts[i], eligibleParts[i]);
        }
    }

    function _placeTier(uint8 tier, uint256 budget, uint256 eligibleBudget) private {
        Tier storage state = _tiers[tier];
        (int24 tickLower, int24 tickUpper) = _tierTicks(tier);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = usdgIsCurrency0
            ? BurnNetMath.liquidityForAmount0(sqrtLower, sqrtUpper, budget)
            : BurnNetMath.liquidityForAmount1(sqrtLower, sqrtUpper, budget);
        if (liquidity == 0) return;
        uint256 required = usdgIsCurrency0
            ? BurnNetMath.amount0Ceil(sqrtLower, sqrtUpper, liquidity)
            : BurnNetMath.amount1Ceil(sqrtLower, sqrtUpper, liquidity);
        if (required > budget) {
            --liquidity;
            required = usdgIsCurrency0
                ? BurnNetMath.amount0Ceil(sqrtLower, sqrtUpper, liquidity)
                : BurnNetMath.amount1Ceil(sqrtLower, sqrtUpper, liquidity);
        }
        if (liquidity == 0 || required > budget) return;

        PoolKey memory key = _poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: BurnNetMath.tierSalt(generation, tier)
            }),
            bytes("")
        );
        int128 usdgDelta = usdgIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = usdgIsCurrency0 ? delta.amount1() : delta.amount0();
        if (usdgDelta >= 0 || tokenDelta != 0) revert UnexpectedPoolDelta();
        uint256 used = uint256(uint128(-usdgDelta));
        if (used > budget) revert UnexpectedPoolDelta();
        CurrencySettler.settle(usdgIsCurrency0 ? key.currency0 : key.currency1, poolManager, address(this), used, false);

        uint256 eligibleUsed = used == budget ? eligibleBudget : Math.mulDiv(eligibleBudget, used, budget);
        activeLiquidUSDG -= used;
        activePositionPrincipalUSDG += used;
        activeEligibleLiquidUSDG -= eligibleUsed;
        activeEligiblePositionUSDG += eligibleUsed;
        state.tickLower = tickLower;
        state.tickUpper = tickUpper;
        state.liquidity += liquidity;
        state.unfilledUSDG += used;
        state.eligiblePrincipalUSDG += eligibleUsed;
        emit TierFunded(generation, tier, used, eligibleUsed, tickLower, tickUpper, liquidity);
    }

    function _harvestCrossed() private returns (uint256 burned, uint256 returnedUSDG) {
        int24 spot = _spotTick();
        for (uint8 i; i < TIER_COUNT; ++i) {
            Tier storage state = _tiers[i];
            if (state.liquidity == 0 || !_fullyCrossed(state, spot)) continue;
            (uint256 tierBurned, uint256 tierReturned,) = _removeTier(i);
            burned += tierBurned;
            returnedUSDG += tierReturned;
        }
    }

    function _settleAll() private returns (uint256[7] memory returnedUSDG, uint256[7] memory returnedEligible) {
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (_tiers[i].liquidity == 0) continue;
            (, returnedUSDG[i], returnedEligible[i]) = _removeTier(i);
        }
    }

    function _settleTouched() private returns (uint256[7] memory returnedUSDG, uint256[7] memory returnedEligible) {
        int24 spot = _spotTick();
        for (uint8 i; i < TIER_COUNT; ++i) {
            Tier storage state = _tiers[i];
            if (state.liquidity == 0 || !_touched(state, spot)) continue;
            (, returnedUSDG[i], returnedEligible[i]) = _removeTier(i);
        }
    }

    function _removeTier(uint8 tier) private returns (uint256 tokenOut, uint256 usdgOut, uint256 eligibleReturned) {
        Tier storage state = _tiers[tier];
        uint256 principal = state.unfilledUSDG;
        uint256 eligiblePrincipal = state.eligiblePrincipalUSDG;
        PoolKey memory key = _poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: state.tickLower,
                tickUpper: state.tickUpper,
                liquidityDelta: -int256(uint256(state.liquidity)),
                salt: BurnNetMath.tierSalt(generation, tier)
            }),
            bytes("")
        );
        int128 usdgDelta = usdgIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = usdgIsCurrency0 ? delta.amount1() : delta.amount0();
        if (usdgDelta < 0 || tokenDelta < 0) revert UnexpectedPoolDelta();
        usdgOut = uint256(uint128(usdgDelta));
        tokenOut = uint256(uint128(tokenDelta));
        if (usdgOut != 0) {
            CurrencySettler.take(
                usdgIsCurrency0 ? key.currency0 : key.currency1, poolManager, address(this), usdgOut, false
            );
        }
        if (tokenOut != 0) {
            CurrencySettler.take(
                usdgIsCurrency0 ? key.currency1 : key.currency0, poolManager, address(this), tokenOut, false
            );
            IToken12BurnNet(token).burn(tokenOut);
        }

        uint256 converted = principal > usdgOut ? principal - usdgOut : 0;
        uint256 eligibleConsumed = principal == 0 ? 0 : Math.mulDiv(eligiblePrincipal, converted, principal);
        eligibleReturned = eligiblePrincipal - eligibleConsumed;
        activePositionPrincipalUSDG -= principal;
        activeLiquidUSDG += usdgOut;
        activeReserveUSDG -= converted;
        activeEligiblePositionUSDG -= eligiblePrincipal;
        activeEligibleLiquidUSDG += eligibleReturned;
        activeEligibleTradeFeeUSDG -= eligibleConsumed;
        consumedActiveUSDG += converted;
        consumedEligibleTradeFeeUSDG += eligibleConsumed;
        totalUSDGConvertedToToken += converted;
        totalBurned += tokenOut;
        emit TierHarvested(generation, tier, converted, eligibleConsumed, tokenOut, usdgOut);
        delete _tiers[tier];
    }

    function _hasFullyCrossedTier() private view returns (bool) {
        int24 spot = _spotTick();
        for (uint8 i; i < TIER_COUNT; ++i) {
            Tier storage state = _tiers[i];
            if (state.liquidity != 0 && _fullyCrossed(state, spot)) return true;
        }
        return false;
    }

    function _hasAnyPosition() private view returns (bool) {
        for (uint8 i; i < TIER_COUNT; ++i) {
            if (_tiers[i].liquidity != 0) return true;
        }
        return false;
    }

    function _hasTouchedTier() private view returns (bool) {
        int24 spot = _spotTick();
        for (uint8 i; i < TIER_COUNT; ++i) {
            Tier storage state = _tiers[i];
            if (state.liquidity != 0 && _touched(state, spot)) return true;
        }
        return false;
    }

    function _touched(Tier storage state, int24 spot) private view returns (bool) {
        return usdgIsCurrency0 ? spot > state.tickLower : spot < state.tickUpper;
    }

    function _fullyCrossed(Tier storage state, int24 spot) private view returns (bool) {
        return usdgIsCurrency0 ? spot >= state.tickUpper : spot <= state.tickLower;
    }

    function _deepestValidTier() private view returns (uint8) {
        for (uint8 reverse; reverse < TIER_COUNT; ++reverse) {
            uint8 tier = TIER_COUNT - 1 - reverse;
            if (_tierIsPureUSDG(tier)) return tier;
        }
        return type(uint8).max;
    }

    function _tierIsPureUSDG(uint8 tier) private view returns (bool) {
        (int24 lower, int24 upper) = _tierTicks(tier);
        int24 spot = _spotTick();
        return usdgIsCurrency0 ? spot <= lower : spot >= upper;
    }

    function _tierTicks(uint8 tier) private view returns (int24 lower, int24 upper) {
        Tier storage state = _tiers[tier];
        if (state.liquidity != 0) return (state.tickLower, state.tickUpper);
        return BurnNetMath.tierTicks(_anchorTick(), tier, usdgIsCurrency0);
    }

    function _anchorTick() private view returns (int24) {
        uint256 ratioX192 = usdgIsCurrency0
            ? FullMath.mulDiv(1e30, uint256(1) << 192, anchor)
            : FullMath.mulDiv(anchor, uint256(1) << 192, 1e30);
        return TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(ratioX192)));
    }

    function _spotTick() private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _poolKey() private view returns (PoolKey memory key) {
        Currency tokenCurrency = Currency.wrap(token);
        Currency usdgCurrency = Currency.wrap(address(usdg));
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidInitialization();
    }

    function _sum(uint256[7] memory values) private pure returns (uint256 total) {
        for (uint8 i; i < TIER_COUNT; ++i) {
            total += values[i];
        }
    }

    function mintingAvailable() external view returns (bool) {
        if (snapshotAt != 0 && block.timestamp <= snapshotAt) return false;
        uint40 resetAt = lastDownwardResetAt;
        if (resetAt != 0 && block.timestamp < mintFrozenUntil) return false;
        if (resetAt == 0) {
            try INetNetHookBurnNet(hook).validTWAP(poolId) returns (uint256 price) {
                return price != 0;
            } catch {
                return false;
            }
        }
        try INetNetHookBurnNet(hook).validTWAPAfter(poolId, resetAt) returns (uint256 price) {
            return price != 0;
        } catch {
            return false;
        }
    }
}
