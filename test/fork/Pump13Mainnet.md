# Pump13 mainnet fork integration

This suite deploys the current Pump/Token/TagAISwapHook, a fresh NutboxRouter, and the
current Basket V4 artifacts into a **local BSC fork**. It never broadcasts transactions.

## Run

Build the sibling Basket project first, using its own dependency versions:

```sh
cd ../bsc-basket-contract
forge build --skip test --skip script
cd ../TagAI-contract-V2
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL= forge test --match-contract Pump13MainnetForkTest -vv
```

Set `BSC_RPC_URL` in the environment or this project's `.env`. An archive-capable RPC
is required. The default pinned block is **120508054**. Override explicitly with
`PUMP13_FORK_BLOCK`; report the block together with the results. `FOUNDRY_PROFILE=fork`
selects chain ID 56 and grants read access only to the sibling Basket artifact directory.
Without an RPC, tests are skipped; a skipped suite is **not** a successful fork run.

## What is real

- Mainnet stock/asset tokens, Pancake V2 factory/pairs, V3 pools/router, Infinity manager/vault.
- Mainnet IPShare, Committee, CommunityFactory, non-locking ERC20StakingFactory and Basket fee auction.
- Newly deployed current production Pump13, Token, TagAISwapHook, NutboxRouter and Basket V4 bytecode.
- Actual BNB-funded swaps. No mocked prices, replaced DEX bytecode or fabricated stock/index balances.
- The production `TagAIBuybackRouter` executes BNB-to-settlement and Basket purchases;
  both conversion stages require explicit nonzero minimum outputs.
- Test users receive native BNB with `vm.deal`. Committee whitelist additions impersonate the
  real administrator **only on the fork**, modelling permissions required at deployment.

## Router import

Production source: `0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f`.

The original 14 asset addresses in `BSCNutboxRouterConfig.assetConfigs()` serve as required discovery seeds:
ETH, BTCB, QQQB, SPCXB, AAPLB, SKHYB, SPYB, XAUt, NVDAB, TSLAB, MSFTB, HOODB, BABAB, GMEB.
They include 11 stock/ETF entries, two crypto assets and six-decimal gold.
The tests read **current pool source data and route ordering from the live registry at the
fork block**, copy referenced pools once, then recreate each asset's BNB and settlement
routes. This is not an exhaustive event scan for assets added outside that catalog.
Newer catalog entries are imported only when both routes exist at the fork block;
absent entries are logged. GOOGLB and CRCLB were added to the workspace catalog during
this work, but were not registered in the source Router at the pinned block and are
not claimed as tested stock assets here. Original mandatory assets still fail setup
if their routes disappear.

New T-A component pairs are used directly by Basket through its V2 factory; the suite
asserts that List does **not** register them as NutboxRouter price pools.

## Coverage and limits

- Asset-by-asset creation/listing and multiple independent T/index instances.
- Existing/missing IPShare, retained/renounced community owner, real LP staking token binding.
- Four components, six-decimal XAUt, 99.97%/0.01% extreme weights and index fee boundaries.
- Actual V4 seeding, V2 seeding and initial LP burn; live Router route validation and Basket V4 creation.
- Late-leg slippage failure, atomic rollback, administrator recovery, holder exit/refill/retry.
- Missing Router/Registry permissions; deadline and keeper authorization.
- Existing Token's manager/vault/hook snapshots after Pump defaults change.
- Real V4 fees, per-token buyback reserve isolation, index buyback/claim/redemption.
- External Hook topup, periodic Nutbox injection, LP deposit and immediate withdrawal.
- Pre-list component donation/sync, stale keeper bounds after a real large stock purchase,
  and consuming an unsolicited BNB balance remainder during listing.
- Split execution across V4 and a component V2 pair, both directions of T's 0.1% burn,
  and taxation when removing user-added V2 liquidity.

## Four-constituent creation limit

Pump13 now accepts **1–4** constituent assets. Both Pump validation and Token index
initialization enforce the cap. Five- and ten-asset requests must revert with
`InvalidIndexConfig` before IPShare, fees, communities, tokens or pairs are created.
The four-asset path creates its pairs within the same create transaction; no preparatory
transactions are needed. Current gas measurements are in [the gas report](Pump13GasStress.md).
The earlier ten-asset investigation is retained only as [historical evidence](history/Pump13TenComponentGasStress.md).

### First index buyback requires trade data

Basket's first mint rejects empty per-leg minimums. The production adapter forwards the
Basket payload inside the Hook caller's `abi.encode(minSettlementOut, basketTradeData)` to BasketSwapRouter. The integration case first verifies that
an empty payload rolls back and preserves the buyback reserve, then retries with valid
nonzero leg bounds and verifies actual mint/claim/redemption.
Dedicated buyback fork tests preview actual execution from a snapshot and use 99% of
the returned index output; first-mint leg bounds remain minimal for execution coverage.
This does not implement the production keeper's time-averaged pricing policy.

Buying this index traverses T-BNB again, creating a small new Hook fee. Therefore the
post-buyback BNB reserve is not necessarily zero: the test reconciles it against the
new platform fee and the Hook's actual native balance, keeping new fees for the next run.

The split-execution test uses the test contract as the coordinator. It does not certify
an independently deployed aggregator router or its allowance/callback authorization.

Printed gas measurements cover individual create/List calls, not protocol-stack setup.
Fork success covers the pinned state and tested execution paths; it does not certify future
stock-token upgrades, changing pool depth, front-end quote accuracy or keeper operations.


Current four-component verification: **32 functional fork tests passed**, plus **11 gas/aggregation/recovery tests passed** in the separate isolated gas suite; no failures or skips. See [gas results](Pump13GasStress.md) for individual transaction estimates.

Production buyback, failure recovery and deployment-script coverage are described in [the buyback report](Pump13Buyback.md).

Pump13 deployment now initializes the constituent whitelist in the Pump constructor using the same 16-asset catalog as Router bootstrap. The fresh-default-Router deployment test verifies routes and nonzero quotes for all 16, including GOOGLB/CRCLB. This is additional coverage; the live-registry import suite above still uses the 14 assets present in the old registry at the pinned block.
