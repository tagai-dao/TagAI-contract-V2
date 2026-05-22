# TagAI Contract V2

Smart contracts for **TagAI (TipTag)** on BSC — **Pump Version 9 (V9)**. V9 ties together **community token launches**, **creator IPShare**, **Nutbox community incentives**, and **PancakeSwap V4 on-chain trading**. Users participate through Twitter/X social activity; tokens start on a bonding curve and migrate to the DEX once listing conditions are met, with swap fees flowing back to the community and creators.

> **Earlier Pump versions (V1–V8)** live in the legacy Hardhat repo: [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract). This repository is the Foundry-based **V9** deployment and supersedes V8 on BSC mainnet for new community tokens.

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
4. **TagAISwapHook** is attached to the V4 pool: it collects swap fees, routes them by rule, and can inject community tokens into Nutbox on large buys

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
| **TagAISwapHook** | DEX buy (ETH → token), buy size ≥ 8,400 tokens | **0.2%** of tokens bought, capped by remaining 150M Nutbox allocation held by Hook |
| **Token (anti-snipe)** | Bonding-curve buy within 15s of creation | Sellsman fee ETH is used to buy tokens on-curve, then injected into the community |

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
- **Listing**: Once enough ETH accumulates on the curve, the Token initializes a V4 pool with bounded-range liquidity
- **Hook bitmap**: Hook address lower 16 bits must satisfy PCS V4 requirements (`0x0CC1`); deployed via CREATE2 salt mining
- **IPShare fee share**: Hook can route part of swap fees to a chosen IPShare subject (creator by default)
- **IPShare subject transfer**: The token’s current fee subject (`ipshareSubject`, set to the creator at launch) may call `transferIPShareOwner(newSubject)` to redirect default bonding-curve sellsman fees and the Hook’s fallback fee recipient to another **registered IPShare** address. Emits `IPShareSubjectTransferred`. Does not transfer Nutbox Community admin rights.
- **Nutbox injection**: On large DEX buys, Hook injects **0.2%** of purchased tokens into `HourlyTickCalculator`, where they vest over 7 days and feed SocialCuration / staking pools (see above)

## Protocol Versions

TagAI’s on-chain launch stack has evolved through multiple **Pump** factory versions on BSC. **IPShare v1** (`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`) has been reused since early versions and is still shared by V9.

| Version | Repository | Status | Summary |
|---------|------------|--------|---------|
| **V1–V7** | [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract) | Legacy | Iterative Hardhat releases: bonding-curve launch, IPShare value capture, PCS hook fee routing. Historical Pump / Hook addresses documented in that repo. |
| **V8** | [tagai-dao/tagai-contract](https://github.com/tagai-dao/tagai-contract) | Legacy (superseded) | Agent-focused communities: only agents could trade on the bonding curve pre-listing; 15% supply auto-provisioned for Nutbox Community creation with a default SocialCuration pool. |
| **V9** | **This repo** | **Current** | Full Nutbox integration (HourlyTickCalculator, SocialCuration, DFXStar Score Staking), open bonding-curve trading with anti-snipe, PCS V4 listing via `TagAISwapHook`, and Nutbox token injection on DEX swaps. |

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

Existing tokens created under V8 (or earlier) remain bound to their original Pump / Token / Hook contracts. **New launches should use Pump V9** (addresses below).

### What changed in V9

- **Broader Nutbox stack**: HourlyTickCalculator plus DFXStar Score Staking factory alongside SocialCuration
- **Open curve trading**: No longer restricted to agent-only buys on the bonding curve (V8 constraint removed)
- **New Pump + Hook deployment**: Fresh factory and `TagAISwapHook` with updated listing and fee/injection logic on PCS V4
- **Same IPShare layer**: Creator shares still flow through the production IPShare v1 contract

## BSC Mainnet — Pump V9

Chain: **BNB Smart Chain (56)**  
Full list: [`deployments/56/addresses.json`](deployments/56/addresses.json)

| Contract | Address |
|----------|---------|
| Pump | [`0x7FcBa2063899AF1a9bABc856339eC472D95CAEA8`](https://bscscan.com/address/0x7fcba2063899af1a9babc856339ec472d95caea8) |
| Token (implementation) | [`0x502C1E6ed4a5B4F3c7050492FB9556De8216974c`](https://bscscan.com/address/0x502c1e6ed4a5b4f3c7050492fb9556de8216974c) |
| TagAISwapHook | [`0x458e5E6b319Dbf5574a6feB60dFE7A063F5C0Cc1`](https://bscscan.com/address/0x458e5e6b319dbf5574a6feb60dfe7a063f5c0cc1) |
| HourlyTickCalculator | [`0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d`](https://bscscan.com/address/0x6ccec02e7d371fed954d7d16ecb7f2f57cccf54d) |
| DFXStarScoreStakingFactory | [`0x77Fb65140B746e639bB512c2C25604d1924aE774`](https://bscscan.com/address/0x77fb65140b746e639bb512c2c25604d1924ae774) |
| IPShare (reused) | [`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`](https://bscscan.com/address/0x95450aad4cc195e03bb4791b7f6f04ac6d9ba922) |

**Reused Nutbox / PCS infrastructure:** Committee, CommunityFactory, SocialCurationFactory, PCS V4 CLPoolManager, Vault (see `addresses.json`).

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
