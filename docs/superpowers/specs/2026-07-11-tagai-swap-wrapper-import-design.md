# TagAI Swap Wrapper + ImportHelper Enhancement Design

**Date:** 2026-07-11  
**Status:** Draft for review  
**Repo:** TagAI-contract-V2  
**Related:** `pump-contract/contracts/WrappedUniV2ForTagAI.sol`, `src/helper/ImportHelper.sol`

## Goal

1. Enhance `ImportHelper` so importing an external token mirrors `Pump.createToken` IPShare requirements, and records the importer for fee routing.
2. Add `TagAISwapWrapper` (independent of ImportHelper) with Uniswap **V2 + V3 + V4** buy/sell, fee split like the legacy wrapper.
3. RH mainnet fork tests using live token `0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31`:
   - ImportHelper → Nutbox inject → claim
   - Wrapper **V2** against existing pair `0xd95e8e2cd04c207625c6f23c974d365a5f3a91d3`
   - Wrapper **V3** / **V4**: in the fork, `deal`/mint liquidity for the tester, **create fresh V3 and V4 pools** (token↔WETH/ETH), then exercise wrapper buy/sell on those pools

## Non-goals (this iteration)

- Deploying wrapper/ImportHelper to RH mainnet production (fork + local deploy in tests only).
- DFX / SocialDistribution legacy registry.
- Relying on pre-existing V3/V4 liquidity for the test token (tests create their own pools).

## Architecture

```
EOA
 ├─ ImportHelper.createCommunityAndPool(token, calculator, policy)
 │    ├─ ensure IPShare(subject=msg.sender)  [pay createFee if needed]
 │    ├─ CommunityFactory.createCommunity + SocialCuration pool
 │    └─ importerOf[token] = msg.sender
 │
 └─ TagAISwapWrapper.buy/sell V2|V3|V4
      ├─ resolveSellsman(token, sellsmanArg)
      │    ├─ if sellsmanArg != 0 && ipshare.ipshareCreated(sellsmanArg) → sellsmanArg
      │    ├─ else if importerOf[token] != 0 → importer
      │    └─ else → feeAddress
      ├─ take sellsmanRatio + tagaiRatio (bps of ETH leg)
      └─ call Uni V2 Router / V3 Router / V4 PoolManager path
```

Two contracts, separate addresses. Wrapper **reads** ImportHelper; it does not own import logic.

## Contract 1: ImportHelper (enhanced)

### Constructor deps

- `communityFactory`, `socialCurationFactory`, `nutboxCommittee`, `ipshare`

### Storage

- `mapping(address token => address importer) public importerOf`
- Existing immutables for factories/committee; add `address public immutable ipshare`

### `createCommunityAndPool` (payable)

1. `creator = msg.sender` (EOA recommended; may keep or drop `tx.origin` check — prefer allow contract callers unless product requires EOA-only like Pump).
2. Fee math (align Pump):
   - `ipshareCreateFee = ipshareCreated(creator) ? 0 : IPShare.createFee()`
   - `nutboxFees = getCreateCommunityFee() + getCommunitySettingsFee()`
   - require `msg.value >= ipshareCreateFee + nutboxFees`
3. If needed: `IPShare.createShare{value: ipshareCreateFee}(creator)`.
4. Create community (`isMintable=false`, `communityToken=token`, `calculator`, `distributionPolicy`).
5. `adminSetDev(creator)`, add SocialCuration pool (100% ratio), `transferOwnership(creator)`.
6. `importerOf[token] = creator` (revert if already set — one import per token).
7. Refund dust ETH if any.
8. Emit `CommunityCreated` (extend with `importer` if useful).

### Views for Wrapper

- `importerOf(token)` — already public mapping.

## Contract 2: TagAISwapWrapper

### Constructor

- `importHelper`, `ipshare`, `weth`, `feeAddress`
- Default ratios: `sellsmanRatio = 100`, `tagaiRatio = 100` (1% each, same as legacy bps/10000)

### Admin (Ownable)

- `adminSetFeeRatio(sellsmanRatio, tagaiRatio)` — each `< 1000`
- `adminSetFeeAddress`, `adminSetWeth`, optional `adminSetImportHelper` / `adminSetIpshare`

### Sellsman resolution

```text
_resolveSellsman(token, sellsman) →
  if sellsman != 0 && IIPShare(ipshare).ipshareCreated(sellsman) → sellsman
  else if ImportHelper(importHelper).importerOf(token) != 0 → importer
  else → feeAddress
```

### V2 (legacy-compatible)

- `buyToken(sellsman, amountOutMin, path, to, deadline, router)` payable  
  - `path[0] == WETH`
- `sellToken(amountIn, amountOutMin, path, to, deadline, sellsman, router)`  
  - `path[last] == WETH`; pull tokens, swap to ETH on wrapper, fee, send ETH to `to`

Router address is a **call parameter** (RH V2 router may differ by env).

### V3 (legacy-compatible)

- `buyTokenV3(sellsman, amountOutMin, token, to, deadline, router, poolFee)` payable
- `sellTokenV3(amountIn, amountOutMin, token, to, deadline, sellsman, router, poolFee)`  
  - WETH unwrap after swap when selling

### V4 (new)

- `buyTokenV4` / `sellTokenV4`: caller supplies `PoolKey` (and any router/PM address required by chosen integration).
- Prefer a thin path via existing patterns (`PoolSwapTest`-style unlock/swap against `IPoolManager`) **or** Universal Router if we standardize on RH UR — **implementation choice in plan**: default to **PoolManager + unlock callback on the wrapper** so we do not depend on UR encoding; document that frontend may later use UR.
- ETH as `currency0` / native settle like TagAI listing pools when applicable; support general `PoolKey` as long as one side is WETH/native per documented constraints.

### Fees

- Always computed on the **ETH amount** of the trade (msg.value for buys; ETH out for sells), same as legacy.
- `sellsmanFee = amount * sellsmanRatio / 10000` → `sellsman.call`
- `tagaiFee = amount * tagaiRatio / 10000` → `feeAddress.call`
- Remainder to user / swap.

### Security

- `ReentrancyGuard` on all swap entrypoints
- `receive()` for ETH
- Approve router only for exact amount; reset approve to 0 after V2/V3 where practical
- No arbitrary `call` to user-supplied targets except known router interfaces + ETH transfers to sellsman/fee/to

## RH mainnet reference addresses (fork tests)

| Item | Address |
|------|---------|
| Test ERC20 | `0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31` |
| V2 pair | `0xd95e8e2cd04c207625c6f23c974d365a5f3a91d3` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| PoolManager (v4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| V3 Factory (Uniswap) | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| V3 NFT Position Manager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| V4 Position Manager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |

## Test plan (RH mainnet fork)

Profile: `FOUNDRY_PROFILE=rh_fork` + `RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com`

Shared setup:

1. Fork RH mainnet; deploy fresh Nutbox stack + IPShare + ImportHelper + TagAISwapWrapper.
2. `vm.deal(tester, …)` for ETH; for the live token use `deal(token, tester, amount)` (Foundry ERC20 deal) — **no real mint authority required** if `deal` works; if token is non-standard, fall back to whale `prank` + transfer.
3. Resolve V2/V3 routers from RH Uniswap deployments (pass as call args).

### A. Import + Nutbox

4. **Import:** `createCommunityAndPool(token, calculator, "")`; assert `importerOf`, IPShare, community/pool.
5. **Inject:** approve + `inject`; assert balances / `totalInjected`.
6. **Claim:** `vm.warp(+2 hours)`; EIP-712 claim; assert token balance up.

### B. Wrapper V2 (existing pair)

7. **Buy:** path `[WETH, token]` via live pair liquidity.
8. **Sell:** approve wrapper, sell back to ETH; assert fees paid.

### C. Wrapper V3 (create pool in fork)

9. Create V3 pool token/WETH (e.g. fee 3000) via factory + `NonfungiblePositionManager.mint` with tester’s `deal`’d token + WETH.
10. **Buy/sell** via `buyTokenV3` / `sellTokenV3` against that pool; assert balances + fees.

### D. Wrapper V4 (create pool in fork)

11. `PoolManager.initialize` + add liquidity (PositionManager or direct `modifyLiquidity` unlock) for ETH/token (or WETH/token per PoolKey convention used by wrapper).
12. **Buy/sell** via `buyTokenV4` / `sellTokenV4`; assert balances + fees.
13. Hooks: use **empty hooks / zero address hooks** for the ad-hoc test pool unless TagAISwapHook flags are required — prefer **no TagAI hook** so listing constants do not block arbitrary liquidity.

Also run existing `test/fork/*` RHFork suite for regressions.

## Deploy script impact

- Update `DeployRH.s.sol` to pass `ipshare` into `ImportHelper` constructor and deploy `TagAISwapWrapper`.
- Write addresses into `deployments/<chainId>/addresses.json`.

## Open decisions (locked by product confirmation 2026-07-11)

| Topic | Decision |
|-------|----------|
| Architecture | Two contracts; Wrapper reads ImportHelper |
| Sellsman | Arg if valid IPShare subject; else importer; else feeAddress |
| Importer | Always `msg.sender` at import (no separate `dev` param) |
| DEX surface | V2 + V3 + V4; fork tests cover V2 (live pair) + V3/V4 (pools created in-test) |
| Registry | No separate TokenDevRegistry; `importerOf` on ImportHelper |

## Risks

- RH V2 Router address must be correct in tests or swaps revert.
- HourlyTick claim needs ≥1 hour warp after inject.
- V4 PoolManager unlock pattern is more complex than V2/V3; keep V4 path minimal and well-commented.
- Changing ImportHelper constructor breaks already-deployed testnet ImportHelper — expected; redeploy on next RH deploy.
