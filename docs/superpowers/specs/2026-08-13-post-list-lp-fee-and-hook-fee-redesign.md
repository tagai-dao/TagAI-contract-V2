# Post-List LP Fee & Hook Fee Redesign

**Date:** 2026-08-13  
**Status:** Approved for planning  
**Scope:** Post-listing (PancakeSwap Infinity CL) fee routing only. Bonding-curve (inner market) fees unchanged.

## Problem

After listing, pools currently use `fee = 0` and TipTag collects all swap fees via `TagAISwapHook` (0.3% platform + 0.3% IPShare from the BNB side). External LPs earn almost nothing from trading fees, so there is little incentive to add liquidity.

Competitors (Four.meme, Flap) list into Pancake pools with native LP fees so external LPs can earn.

## Goals

1. Keep total trader cost around **~1%** post-list (including Pancake protocol fee ≈0.1%).
2. Enable native **0.3% LP fee** so external LPs share fees with the locked listing position.
3. Keep IPShare/deployer **0.3%** via Hook (BNB side), logic otherwise unchanged.
4. Add a Hook **directional 0.3%** fee (buy → token to Hook distribution; sell → BNB to platform).
5. Lock listing LP on the **Token** contract permanently; expose permissionless fee collection only.
6. Do **not** change bonding-curve fee behavior (`Pump.feeRatio`).

## Non-Goals

- Separate `LiquidityManager` contract
- Removing or decreasing listing liquidity
- Changing inner-market / anti-snipe fee logic
- Migrating already-listed pools (`fee` is immutable at initialize)

## Fee Model (Post-List)

| # | Source | Rate | When / asset | Destination |
|---|--------|------|--------------|-------------|
| 1 | Hook · IPShare | 0.3% (hardcoded) | Both sides; from **BNB** | `IPShare.valueCapture(subject)` |
| 2 | Pool LP fee | 0.3% (`PoolKey.fee = 3000`) | Both sides; **input** currency | Accrues to liquidity positions |
| 2' | Pancake protocol | ≈0.1% (policy; ~33% of LP fee, cap 0.4%) | Composed with LP fee | Pancake |
| 3 | Hook · directional | 0.3% (hardcoded) | **Buy:** 0.3% of output **Token** → Hook balance | Joins Nutbox distribution budget (same balance as 150M listing allocation + later top-ups) |
| 3 | Hook · directional | 0.3% (hardcoded) | **Sell:** 0.3% of output **BNB** → platform | `Pump.getFeeReceiver()` |

Approximate trader total: **0.3% + 0.3% + 0.1% + 0.3% ≈ 1.0%**.

### Inner market

Unchanged. Still reads `Pump.feeRatio` (default `[30, 30]`). Hook post-list fees are **independent** and must not call `pump.getFeeRatio()`.

### Removed post-list path

Hook no longer routes a platform cut via `feeRatio[0]`. Platform BNB after list comes from:

- sell-side Hook directional 0.3%, and
- `Token.collectFees()` BNB proceeds.

## Architecture

```
Bonding curve (unchanged feeRatio)
        │
        ▼
Token._makeLiquidityPool
  - transfer 150M to Hook
  - PoolKey.fee = 3000
  - initialize + registerPool
  - Token modifyLiquidity (position owner = Token)
  - no removeLiquidity forever
        │
        ▼
Swaps on PCS Infinity CL
  - LP fee 0.3% (+ ~0.1% protocol) → all in-range LPs
  - Hook IPShare 0.3% BNB
  - Hook directional: buy Token→Hook / sell BNB→platform
  - existing 10-min buy volume → Nutbox settle (unchanged schedule)
        │
        ▼
Anyone: Token.collectFees()
  - claim locked listing position fees
  - BNB → feeReceiver
  - Token → Hook (distribution balance)
```

## Component Design

### `Token.sol`

- Set listing `PoolKey.fee` from `0` to `3000`.
- Keep listing LP creation on Token (current `vault.lock` / `modifyLiquidity` path).
- Do not add decrease/remove liquidity APIs.
- Add `collectFees()` (or equivalent name):
  - callable by **anyone**
  - settles fees for the listing position (`tickLower`, `tickUpper`, `salt` used at list)
  - sends native BNB to `IPump(manager).getFeeReceiver()`
  - transfers collected community token amount to Hook address
  - emit event with amounts and caller

### `TagAISwapHook.sol`

- Hardcode post-list bps, e.g. `IPSHARE_FEE_BPS = 30`, `DIRECTIONAL_FEE_BPS = 30`, `DIVISOR = 10000`.
- Stop reading `pump.getFeeRatio()` for swap fee collection.
- IPShare path: still collect from ETH/BNB side on buys and sells; distribute via existing `_distributeFees` / `valueCapture` subject resolution (including `hookData` override if already supported).
- Directional fee:
  - buy (`zeroForOne`): take 0.3% of token output via vault accounting into Hook; leave on Hook as ERC20 balance for injection budget
  - sell: take 0.3% of BNB output to `feeReceiver`
- Fee bases (explicit):
  - IPShare 0.3% and sell-side directional 0.3% are both computed on the **same gross BNB amount** for that swap leg (same pattern as today’s split of one notional), not nested (not “platform on remainder after IPShare”).
  - Buy-side directional 0.3% is computed on **gross token output** of the swap (after pool LP/protocol fee effects already reflected in delta).
- Preserve Nutbox 10-minute period accumulation / settlement; injection budget remains Hook ERC20 balance (listing 150M + collectFees tokens + buy-side directional tokens).

### `Pump.sol`

- No required fee-ratio behavior change for this feature.
- Optional comment/docs clarifying inner vs outer fee sources.

### Tests / ops

Update unit, integration, property, security, fork, and gas benchmarks for:

- pool fee 3000
- Hook hardcoded fees and directional routing
- `collectFees` permissionless + fund routing
- inner market still on `feeRatio`

## Error Handling & Invariants

- `collectFees` with zero claimable fees: no-op or revert with clear reason (prefer no-op + event with zeros to keep bots cheap).
- Platform / Hook transfers must succeed or whole collect reverts (no partial silent loss).
- Hook buy-side token take must be consistent with PCS vault deltas so swaps never leave unsettled currency.
- Listing position parameters used in collect must match those used in seed (same ticks + salt).
- No path may decrease listing liquidity.

## Testing Plan

1. Listing creates pool with `fee == 3000` and Hook registered.
2. External LP can add liquidity and earn a share of LP fees (sanity).
3. Buy: IPShare receives ~0.3% BNB; Hook token balance increases by ~0.3% of bought tokens (directional); period buy accounting still runs.
4. Sell: IPShare ~0.3% BNB + platform ~0.3% BNB from Hook; LP fee accrues in input token.
5. `collectFees`: third party calls; BNB to platform; tokens to Hook; repeat call shortly after is no-op/zero.
6. Bonding-curve buy/sell fee still follows `feeRatio` / anti-snipe rules.
7. Gas benchmark deltas recorded for swap + collect.

## Risks

1. Trader cost rises from ~0.6% to ~1.0% (+ Pancake protocol).
2. Platform revenue timing shifts: less per-swap BNB from old `feeRatio[0]`; more from sells + collect; tokens from LP fees go to community distribution, not platform wallet.
3. Hook + LP + protocol fee stacking needs careful amount bases (input vs output) to avoid over/under charging.
4. Only new listings; existing `fee=0` pools unchanged.

## Approval Record

- Fee model A (LP both sides on input; Hook directional buy-token / sell-BNB): approved
- Inner market keeps `feeRatio`: approved
- `collectFees` permissionless: approved
- No LiquidityManager; LP owned by Token: approved
- Spec sections §1–§4: approved 2026-08-13
