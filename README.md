# TagAI Contract V2

Smart contracts for **TagAI (TipTag)** on BSC — **Pump Version 9 (V9)** for new community token launches, plus **Version 10 (V10)** for importing existing ERC20s into Nutbox via `ImportHelper`. V9 ties together **community token launches**, **creator IPShare**, **Nutbox community incentives**, and **PancakeSwap V4 on-chain trading**. Users participate through Twitter/X social activity; tokens start on a bonding curve and migrate to the DEX once listing conditions are met, with swap fees flowing back to the community and creators.

> **Earlier Pump versions (V1–V8)** live in the legacy Hardhat repo: [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract). This repository is the Foundry-based **V9 / V10** deployment and supersedes V8 on BSC mainnet for new community tokens (and for external-token Nutbox imports that previously went through Pump6).

## What It Solves

- **Creators**: Launch community tokens, bind IPShare, and earn ongoing value from trading and social activity
- **Community members**: Hold community tokens, curate and stake, and share in community growth
- **Protocol**: Collect swap fees on PCS V4 and distribute them to the platform, IPShare subjects, and Nutbox reward pools

## End-to-End Flow

```
User creates community token
       │
       ▼
   Pump ──► Token (bonding curve trading)
       │            │
       │            ▼ listing threshold met
       │      PancakeSwap V4 concentrated liquidity pool
       │            │
       ▼            ▼
 Nutbox Community   TagAISwapHook
(reward calculation)  (swap fees + Nutbox injection)
```

1. Users create a community token via **Pump**, which also spins up a Nutbox **Community** and default reward pools
2. The **Token** trades on the bonding curve; price follows the supply curve
3. Once listing conditions are met, liquidity migrates to **PCS V4** and trading moves on-chain via the DEX
4. **TagAISwapHook** is attached to the V4 pool: it collects swap fees, routes them by rule, and injects community tokens into Nutbox on a 10-minute settlement schedule

## Core Contracts

| Contract | Role |
|----------|------|
| **Pump** | Community token factory: creation fees, Nutbox wiring, listing trigger |
| **Token** | Per-community ERC20: curve trading → listing → V4 liquidity |
| **IPShare** | Creator shares: buy/sell/stake with value capture (V2 reuses the live v1 deployment) |
| **TagAISwapHook** | PCS V4 hook: before/after swap callbacks, platform fee, IPShare share, Nutbox injection |
| **HourlyTickCalculator** | Nutbox reward calculator: hourly buckets + 168h linear vesting per injection |
| **SocialCurationFactory** | Social curation reward pool (Nutbox dApp) |
| **DFXStarScoreStakingFactory** | Score-staking reward pool (Nutbox dApp, e.g. DFXStar Score) |
| **ImportHelper** | V10 helper: import an existing ERC20 into Nutbox (Community + SocialCuration) in one tx |

### Nutbox Stack

Nutbox handles **Community creation, multi-pool reward ratios, Committee governance, and contract whitelisting**. When Pump creates a token, it also creates a Community and mounts a default SocialCuration pool. The Community admin can later add pools such as DFXStar Score Staking and adjust reward splits.

### Hourly reward distribution (`HourlyTickCalculator`)

V9 uses **HourlyTickCalculator** as the Nutbox reward calculator for each community. It turns injected community tokens into a **hourly, linearly vesting** reward stream that SocialCuration / DFXStar Score Staking pools can claim against.

**Time buckets**

- Rewards are indexed by **hour** (`timestamp / 3600`), not block-by-block.
- The active “reward head” is the start of the current hour (`rewardHead()`).

**7-day linear vesting per injection**

- Each `inject(community, amount)` starts a new vesting tranche.
- Tranche length: **168 hours (7 days)**.
- Within the window, tokens unlock **linearly at a constant hourly rate**: `amount / 168` per hour.
- After 168 hours, that tranche is fully vested and counted toward cumulative rewards.

**Injection rules**

- Tokens are transferred from the caller to the **Community** contract on inject.
- Multiple injects in the **same hour** are **merged** into one bucket (same `startHour`).
- Only communities registered via `setDistributionEra()` (at Community creation) accept injects.

**Where tokens come from**

| Source | When | Amount |
|--------|------|--------|
| **TagAISwapHook** | DEX buy (BNB → token) on PCS V4 | **Tiered %** settled every **10 minutes** (see [Dynamic Nutbox injection](#dynamic-nutbox-injection-tagaiswaphook)); period settlement must be ≥ **16.8** whole tokens; capped at **420M tokens/10-min period** and **150M** Nutbox allocation per community |
| **Token (anti-snipe)** | Bonding-curve buy within 15s of creation | Sellsman fee BNB is used to buy tokens on-curve, then injected into the community |

**Claiming**

- Nutbox pools call `calculateReward(community, lastCursor, head)` to get newly vested tokens between two hour-aligned cursors.
- The calculator uses a cumulative function `F(t)` with prefix sums and binary search — **O(log N)** per query, **O(1)** per inject.

**Example:** Inject 168,000 tokens at hour *H* → ~1,000 tokens become claimable each hour from *H* through *H+167*, then the tranche is fully distributed.

### Token Supply (1B per community)

| Allocation | Amount | Purpose |
|------------|--------|---------|
| Bonding curve | 650M | Pre-listing curve trading |
| Listing liquidity | 200M | LP migrated to PCS V4 |
| Social / Nutbox | 150M | Community rewards (including Hook injection, etc.) |

### Key Mechanisms (summary)

- **Anti-snipe**: Elevated sell fees right after creation that decay quickly, discouraging sniping
- **Listing**: Once enough BNB accumulates on the curve, the Token initializes a V4 pool with bounded-range liquidity
- **Hook bitmap**: Hook address lower 16 bits must satisfy PCS V4 requirements (`0x0CC1`); deployed via CREATE2 salt mining
- **IPShare fee share**: Hook can route part of swap fees to a chosen IPShare subject (creator by default)
- **IPShare subject transfer**: The token’s current fee subject (`ipshareSubject`, set to the creator at launch) may call `transferIPShareOwner(newSubject)` to redirect default bonding-curve sellsman fees and the Hook’s fallback fee recipient to another **registered IPShare** address. Emits `IPShareSubjectTransferred`. Does not transfer Nutbox Community admin rights.
- **Nutbox injection**: On DEX buys, Hook injects a **volume-tiered** share of purchased tokens into `HourlyTickCalculator` (see [Dynamic Nutbox injection](#dynamic-nutbox-injection-tagaiswaphook))

### Dynamic Nutbox injection (`TagAISwapHook`)

On **BNB → community token** swaps through a V4 pool wired to `TagAISwapHook`, buy volume is **accumulated per 10-minute period** (`block.timestamp / 600`). There is **no per-swap inject** within the same period.

**Settlement timing**

- On the **first buy of the next 10-minute period**, the hook settles the **previous period’s cumulative buy volume** in a **single** `HourlyTickCalculator.inject` call.
- If a period has no buys, nothing is settled for that period until a later period’s first buy rolls forward (empty periods are skipped).
- If trading stops entirely, the last active period may never settle (by design).

**How the ratio is chosen**

- For a completed period with cumulative buy volume *P* (whole tokens, 18 decimals):
  - The tier is looked up **directly from *P*** (10-minute volume; no hourly scaling).
  - `ratioPpm` is fixed at deploy time from the 10-minute extract-ratio tier table (T0–T12).
  - Settlement inject: `injectAmount = P × ratioPpm / 10⁹`.
  - `lookupVolume` in events and `previewPeriodSettle` equals *P* (same value, kept for observability).

**Per-period rules**

- Buys within the same period only **accumulate** toward *P* (no minimum per swap).
- At settlement, if `injectAmount` is below **16.8** whole tokens (`MIN_INJECT_OUTPUT`), the **entire period is skipped** (no inject).
- Period buy volume is capped at **420,000,000** tokens; excess buys in the same period do not count toward *P*.
- Injection is still limited by the token’s **remaining 150M** social/Nutbox balance held by the hook.

**Volume → ratio tiers**

Period buy volume *P* (whole tokens, 18 decimals). Ratio applies to the settled period volume *P*.

| Period buy volume *P* (tokens) | `ratioPpm` | Injection ratio |
|-------------------------------|------------|-----------------|
| *P* &lt; 26,700 | 106,069,772 | **10.6069772%** |
| 26,700 ≤ *P* &lt; 93,200 | 53,034,886 | **5.3034886%** |
| 93,200 ≤ *P* &lt; 236,000 | 31,517,443 | **3.1517443%** |
| 236,000 ≤ *P* &lt; 548,000 | 15,758,722 | **1.5758722%** |
| 548,000 ≤ *P* &lt; 1,250,000 | 7,079,361 | **0.7079361%** |
| 1,250,000 ≤ *P* &lt; 3,320,000 | 6,003,489 | **0.6003489%** |
| 3,320,000 ≤ *P* &lt; 7,360,000 | 4,727,617 | **0.4727617%** |
| 7,360,000 ≤ *P* &lt; 14,500,000 | 3,651,745 | **0.3651745%** |
| 14,500,000 ≤ *P* &lt; 23,400,000 | 3,000,000 | **0.3000000%** |
| 23,400,000 ≤ *P* &lt; 41,400,000 | 1,575,873 | **0.1575873%** |
| 41,400,000 ≤ *P* &lt; 84,000,000 | 787,936 | **0.0787936%** |
| 84,000,000 ≤ *P* &lt; 355,000,000 | 393,969 | **0.0393969%** |
| *P* ≥ 355,000,000 | 196,984 | **0.0196984%** |

**Caps and limits**

| Limit | Value | Behavior |
|-------|--------|----------|
| **Minimum settlement inject** | **16.8** tokens per period | Periods whose settlement would inject less are skipped entirely. |
| **Period buy volume cap** | **420,000,000** tokens per token per 10 minutes | Cumulative buy volume in the current period is tracked; excess does not count toward *P*. |
| **Nutbox allocation** | **150M** tokens per community | Hook stops injecting when the community’s remaining social allocation is exhausted. |

**Observability**

- `PeriodSettled(token, settledPeriodIndex, periodVolume, lookupVolume, ratioPpm, injectAmount)` when a prior period is settled (`lookupVolume` equals `periodVolume`; `injectAmount` may be 0 if skipped).
- `previewPeriodSettle(periodVolume)` — view period volume, `ratioPpm`, and inject amount for a hypothetical completed period.
- `periodState(token)` — current period index and accumulated buy volume.

## Protocol Versions

TagAI’s on-chain launch stack has evolved through multiple **Pump** factory versions on BSC. **IPShare v1** (`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`) has been reused since early versions and is still shared by V9 / V11.

The source commits and complete BSC deployment inventory for each release are maintained in [`VERSION_HISTORY.md`](VERSION_HISTORY.md).

| Version | Repository | Status | Summary |
|---------|------------|--------|---------|
| **V1–V7** | [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract) | Legacy | Iterative Hardhat releases: bonding-curve launch, IPShare value capture, PCS hook fee routing. Historical Pump / Hook addresses documented in that repo. |
| **V8** | [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract) | Legacy (superseded) | Agent-focused communities: only agents could trade on the bonding curve pre-listing; 15% supply auto-provisioned for Nutbox Community creation with a default SocialCuration pool. |
| **V9** | **This repo** | **Legacy launch path** | Full Nutbox integration (HourlyTickCalculator, SocialCuration, DFXStar Score Staking), open bonding-curve trading with anti-snipe, PCS V4 listing via `TagAISwapHook`, and Nutbox token injection on DEX swaps. Existing V9 tokens keep their deployed implementation. |
| **V10** | **This repo** (`ImportHelper`) | **Current (external import)** | Import an **already-deployed ERC20** into Nutbox without going through Pump: create a non-mintable Community bound to that token, mount a default SocialCuration pool, and hand ownership to the caller. Replaces the old Pump6 import flow. |
| **V11** | **This repo** | **Current (new launches)** | Pump/Token/Hook fee-collection refresh plus the Index Broker NFT factory, fixed-price NFT AMM, index-token buybacks, dual mining, and on-chain renderer stack. |

### What is V10 (`ImportHelper`)

Pump creates **new** community tokens through the bonding curve and PCS V4 launch flow. **V10** is a parallel path for tokens that **already exist** on-chain and only need Nutbox community incentives wired up.

Contract: [`src/helper/ImportHelper.sol`](src/helper/ImportHelper.sol)

**One-shot flow** (`createCommunityAndPool`)

1. Pay the Committee create-community fee and call `CommunityFactory.createCommunity` with `isMintable = false` and `communityToken =` the imported ERC20
2. Set the Community `devFund` to the caller
3. Pay the community-settings fee and `adminAddPool` a **Social Curation** pool at **100%** reward ratio
4. Transfer Community ownership to the caller

**What V10 does *not* do**

- Does not deploy a new ERC20, Pump Token, bonding curve, or `TagAISwapHook`
- Does not list on PCS V4 or inject from DEX fees (those remain V9 Pump-token mechanics)
- Reward calculator (e.g. `HourlyTickCalculator`) and `distributionPolicy` are supplied by the caller at import time

Existing tokens created under V9 (or earlier) remain bound to their original Pump / Token / Hook contracts. **New launches use Pump V11**; **importing an external ERC20 into Nutbox uses ImportHelper V10**.

### Legacy mainnet addresses (V1–V8)

Published in [tagai-contract README](https://github.com/tagai-dao/tagai-contract#contract-addresses-bsc-mainnet):

| Label | Address |
|-------|---------|
| IPShare (shared) | `0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922` |
| Pump (early BSC) | `0x3E75E2db40E7cc9C7d7869Fc2d97eDAb01724212` |
| Token implementation (early BSC) | `0x679a06AB0970CA68007777b5460bDca240B59cD2` |
| TipTagSwapHook (early BSC) | `0xF815dB0fbeafED4C719F65E41dEC9C50fb357896` |
| **Pump V8** | `0x88d495228E831b01D8Ae6d62f9633cBcC6d27De2` |
| **TipTagSwapHook V8** | `0xF1fa1B3Eb87D9A916fc8d9D1b172Ec67b4612800` |

### What changed in V9

- **Broader Nutbox stack**: HourlyTickCalculator plus DFXStar Score Staking factory alongside SocialCuration
- **Open curve trading**: No longer restricted to agent-only buys on the bonding curve (V8 constraint removed)
- **New Pump + Hook deployment**: Fresh factory and `TagAISwapHook` with updated listing and fee/injection logic on PCS V4
- **Same IPShare layer**: Creator shares still flow through the production IPShare v1 contract

## BSC Mainnet — V11 deployment

Chain: **BNB Smart Chain (56)**

V11 deployment snapshot: [`deployments/56/version11.json`](deployments/56/version11.json)

Status: Pump V11 is live. The upgraded Index Broker NFT stack is deployed, source-verified and fork-tested; its Factory authorization remains disabled until the final ownership handover.

| Contract | Address |
|----------|---------|
| Pump | [`0x8fEF5b4c0f761a0cc447800e3019B089ac306F28`](https://bscscan.com/address/0x8fef5b4c0f761a0cc447800e3019b089ac306f28) |
| Token implementation | [`0xfD40C112F39D372786265a032C546D05Feec4D66`](https://bscscan.com/address/0xfd40c112f39d372786265a032c546d05feec4d66) |
| TagAISwapHook | [`0x9E38747072F326b4e614EfF6FdCA8529db090cc1`](https://bscscan.com/address/0x9e38747072f326b4e614eff6fdca8529db090cc1) |
| NutboxRouter (shared) | [`0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f`](https://bscscan.com/address/0x04e2d43ba38e3f3f0d0dab3a30d1b58bfe9b659f) |
| IndexBrokerNFTFactory | [`0xB1708D2F3A504846a47cdB2e4Dfb48b3ea1c9b5F`](https://bscscan.com/address/0xb1708d2f3a504846a47cdb2e4dfb48b3ea1c9b5f) |
| IndexBrokerNFTBurn template | [`0x1D875946C87a650AF2Aa5B04427D44E647a480B9`](https://bscscan.com/address/0x1d875946c87a650af2aa5b04427d44e647a480b9) |
| IndexBrokerNFTStake template | [`0xc24Ff0009fF1AaD70eF8714ee32ebc8f6b7983a5`](https://bscscan.com/address/0xc24ff0009ff1aad70ef8714ee32ebc8f6b7983a5) |
| IndexBrokerNFTAMM template | [`0x698680412e34db49CdBa62c46a0Faad31D05ce0A`](https://bscscan.com/address/0x698680412e34db49cdba62c46a0faad31d05ce0a) |
| StonkBrokerRenderer | [`0xd4B6120f566CDecD88b7Be6f994a6c7493F8a068`](https://bscscan.com/address/0xd4b6120f566cdecd88b7be6f994a6c7493f8a068) |

Detailed behavior: [`Pump / Token / Hook V11`](docs/PUMP_TOKEN_HOOK_V11.md) · [`NutboxRouter`](src/router/README.md) · [`Index Broker NFT`](src/nutbox/dapps/index-broker-nft/README.md) · [`full version and transaction history`](VERSION_HISTORY.md).

Previous production snapshots remain immutable: [`V9`](deployments/56/version9.json) · [`V10`](deployments/56/version10.json). Reused Nutbox, Basket, IPShare, PancakeSwap and ImportHelper addresses are included in the cumulative V11 snapshot.

## Ecosystem

This repo is the contract layer of TipTag. It works with:

| Project | Role |
|---------|------|
| **tiptag-ui** | Frontend: wallet, launch, trading, community pages |
| **tagai-api** | Primary API: users, communities, off-chain business logic |
| **tiptag-graph** | The Graph: indexes Pump, Token, Hook, IPShare, and related on-chain events |
| **[tagai-contract](https://github.com/tagai-dao/tagai-contract)** | Legacy Pump V1–V8 (Hardhat); historical deployments and prior Hook/Pump addresses |

## License

Core contracts: UNLICENSED. Nutbox-related modules: MIT.
