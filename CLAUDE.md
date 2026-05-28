# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TagAI Contract V2 is the **Foundry-based** smart contract repository for **Pump V9** — TagAI's community token launch system on BSC. It supersedes the legacy Hardhat-based [tagai-contract](https://github.com/tagai-dao/tagai-contract) (V1–V8).

Core flow: **Pump** creates community **Tokens** that trade on a bonding curve, then list on **PancakeSwap V4** where **TagAISwapHook** collects swap fees and injects tokens into **Nutbox** community reward pools.

## Build & Test Commands

All commands use `forge` (Foundry). Run from the project root.

```bash
# Compile
forge build

# Run all tests (unit + integration + property + security)
forge test

# Run tests with verbose output
forge test -vvv

# Run a single test contract
forge test --match-contract PumpTest

# Run a single test function
forge test --match-test testCreateToken

# Run fork tests against BSC mainnet (needs BSC_RPC_URL in .env)
FOUNDRY_PROFILE=fork forge test --match-contract BSCForkTest --fork-url $BSC_RPC_URL -vvv

# Run fuzz tests with CI profile (4096 runs)
FOUNDRY_PROFILE=ci forge test

# Run invariant tests
forge test --match-contract HookInvariant

# Gas benchmark
forge test --match-contract GasBenchmark -vvv

# Gas snapshot for a specific contract
forge snapshot --match-contract PumpTest
```

### Deployment

```bash
# Simulate (no broadcast)
source .env
forge script script/DeployBSCPumpRefresh.s.sol --rpc-url $BSC_RPC_URL --chain-id 56 -vv

# Deploy + verify on BSC
forge script script/DeployBSCPumpRefresh.s.sol \
  --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
  --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
```

## Project Structure

```
src/
├── pump/           # Core protocol: Pump.sol (factory), Token.sol (bonding curve + listing), IPShare.sol
├── hook/           # TagAISwapHook.sol — PCS V4 hook (fee routing, Nutbox injection)
├── nutbox/         # Nutbox community reward infrastructure
│   ├── Community.sol, CommunityFactory.sol, Committee.sol
│   ├── calculators/    # HourlyTickCalculator, LinearCalculator, LinearTimeCalculator
│   ├── community-token/ # MintableERC20 + factory
│   ├── dapps/          # SocialCuration + DFXStarScoreStaking (pools + factories)
│   ├── interfaces/     # Nutbox-specific interfaces
│   └── ERC1155.sol, ERC20Helper.sol
├── interfaces/     # Protocol-level interfaces (IPump, IToken, IIPShare, ICalculator, etc.)
├── mocks/          # Mock CLPoolManager + MockVault for local testing
└── DepCheck.sol    # Deployment dependency checker

test/
├── unit/           # Contract-level unit tests
├── integration/    # FullLifecycle, NutboxIntegration
├── fork/           # BSC mainnet fork tests (needs --fork-url)
├── invariant/      # HookInvariant
├── property/       # Fuzz property tests (Calculator, Fee, Hook, Token)
├── security/       # HookSecurity
└── benchmark/      # GasBenchmark

script/             # Forge deployment scripts
deployments/56/     # BSC mainnet deployed addresses (addresses.json)
```

## Key Technical Details

- **Solidity**: 0.8.26 with `via_ir = true`, optimizer runs = 200
- **Dependencies**: OpenZeppelin 4.9.6, solady 0.1.26, infinity-core (PCS V4), forge-std
- **Hook address mining**: TagAISwapHook uses CREATE2 salt mining so the lower 16 bits of its address satisfy PCS V4 hook requirements (`0x0CC1`). See `script/MineHookSalt.s.sol`.
- **Token supply per community**: 1B total — 650M bonding curve, 200M listing LP, 150M Nutbox/social
- **HourlyTickCalculator**: Rewards vest linearly over 168 hours (7 days) per injection. Uses cumulative prefix sums with binary search → O(log N) queries.
- **IPShare**: V9 reuses the live IPShare v1 deployment (`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`) — no redeployment needed.
- **Anti-snipe**: Elevated sell fees for 15 seconds post-creation; the fee BNB buys tokens on the curve which get injected into Nutbox.
- **10-minute settlement**: TagAISwapHook accumulates DEX buy volume per 10-minute period. Settlement (inject to Nutbox) happens on the first buy of the *next* period.

## Fork Testing

Fork tests require `BSC_RPC_URL` in `.env`. They use `FOUNDRY_PROFILE=fork` (sets `chain_id = 56` in foundry.toml).

Base class is `BSCForkBase.t.sol` — it deploys a fresh Pump + Token + Hook against forked BSC state, reusing existing Nutbox/PCS infrastructure.

## Foundry Profiles

| Profile | Use |
|---------|-----|
| `default` | Local dev, 256 fuzz runs |
| `fork` | BSC fork tests, chain_id=56 |
| `ci` | CI, 4096 fuzz runs, 100 invariant depth |
