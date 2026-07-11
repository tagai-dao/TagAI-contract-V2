# TagAI Swap Wrapper + ImportHelper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance ImportHelper (IPShare + importerOf) and add TagAISwapWrapper (V2/V3/V4 fee-on-trade), then cover RH mainnet fork tests for import/inject/claim and wrapper trades (V2 live pair; V3/V4 pools created in-test).

**Architecture:** Two contracts. ImportHelper owns Nutbox import + `importerOf[token]`. TagAISwapWrapper reads ImportHelper + IPShare to resolve sellsman, then routes to Uni V2/V3/V4. Fork tests deploy a fresh Nutbox stack against live RH Uniswap infra.

**Tech Stack:** Solidity 0.8.26, Foundry, OpenZeppelin 4.9, Uniswap v4-core (existing), RH mainnet fork (`FOUNDRY_PROFILE=rh_fork`).

**Spec:** `docs/superpowers/specs/2026-07-11-tagai-swap-wrapper-import-design.md`

## Global Constraints

- No DFX in DeployRH / ImportHelper path.
- Sellsman: valid IPShare subject arg → else `importerOf[token]` → else `feeAddress`.
- Importer is always `msg.sender` at import (no separate `dev` param).
- V4 ad-hoc test pools use **zero hooks** (not TagAISwapHook).
- Do not commit `.env` or private keys.
- User prefers 中文 communication; code/comments can be bilingual sparingly.

## File map

| Path | Role |
|------|------|
| `src/interfaces/IImportHelper.sol` | `importerOf(address) view returns (address)` |
| `src/interfaces/IUniswapV2Router02.sol` | Minimal V2 router iface |
| `src/interfaces/IUniswapV3SwapRouter.sol` | `exactInputSingle` + `refundETH` |
| `src/interfaces/IWETH.sol` | `deposit` / `withdraw` |
| `src/helper/ImportHelper.sol` | Enhance: ipshare, fees, importerOf |
| `src/helper/TagAISwapWrapper.sol` | V2/V3/V4 wrapper |
| `script/DeployRH.s.sol` | Wire new ImportHelper ctor + deploy wrapper |
| `test/fork/RHImportWrapper.t.sol` | Mainnet fork E2E tests |
| `test/unit/TagAISwapWrapperSellsman.t.sol` | Local unit tests for sellsman resolution + fee math (mocked routers optional) |

---

### Task 1: Interfaces + ImportHelper enhancement

**Files:**
- Create: `src/interfaces/IImportHelper.sol`
- Create: `src/interfaces/IIPShareMinimal.sol` (or reuse `src/interfaces/IIPShare.sol` if it already has `ipshareCreated` / `createFee` / `createShare`)
- Modify: `src/helper/ImportHelper.sol`
- Test: `test/unit/ImportHelper.t.sol` (new, local anvil — no RH fork)

**Interfaces:**
- Consumes: `ICommunityFactory`, `ICommittee`, `IIPShare`, `Community`
- Produces: `ImportHelper.importerOf(token)`, payable `createCommunityAndPool` with IPShare side effects

- [ ] **Step 1: Write failing unit test for IPShare + importerOf**

```solidity
// test/unit/ImportHelper.t.sol — deploy Committee/CF/Calculator/SCF/IPShare locally (copy pattern from NutboxIntegration.t.sol)
// expect: createCommunityAndPool without IPShare reverts if msg.value < createFee
// expect: with enough value, ipshareCreated(creator)==true and importerOf(token)==creator
```

- [ ] **Step 2: Run test — expect FAIL (old ImportHelper has no ipshare)**

```bash
forge test --match-contract ImportHelperTest -vvv
```

- [ ] **Step 3: Implement ImportHelper**

Constructor: `(communityFactory, socialCurationFactory, nutboxCommittee, ipshare)`.

`createCommunityAndPool`:
1. Compute `ipshareCreateFee` + nutbox fees; require `msg.value >= total`.
2. If `!ipshareCreated(msg.sender)` → `createShare{value: ipshareCreateFee}(msg.sender)`.
3. Existing community + pool flow; `require(importerOf[token]==0)`; set `importerOf[token]=msg.sender`.
4. Refund dust.

- [ ] **Step 4: Tests pass**

```bash
forge test --match-contract ImportHelperTest -vvv
```

- [ ] **Step 5: Commit**

```bash
git add src/helper/ImportHelper.sol src/interfaces/IImportHelper.sol test/unit/ImportHelper.t.sol
git commit -m "feat(import): require IPShare and record importerOf on import"
```

---

### Task 2: TagAISwapWrapper (V2 + V3 + V4)

**Files:**
- Create: `src/helper/TagAISwapWrapper.sol`
- Create: `src/interfaces/IUniswapV2Router02.sol`, `IUniswapV3SwapRouter.sol`, `IWETH.sol`
- Test: `test/unit/TagAISwapWrapperSellsman.t.sol` (resolution + fee split with mock/call-capture)

**Interfaces:**
- Consumes: `IImportHelper.importerOf`, `IIPShare.ipshareCreated`
- Produces:
  - `buyToken` / `sellToken` (V2)
  - `buyTokenV3` / `sellTokenV3`
  - `buyTokenV4` / `sellTokenV4` (PoolKey + IPoolManager; wrapper implements unlock callback)

- [ ] **Step 1: Unit test `_resolveSellsman` behavior via public buy with mocked fee recipients**

Cases: valid sellsman arg; zero arg → importer; no importer → feeAddress; fee ratios applied on buy (`msg.value`).

- [ ] **Step 2: Implement wrapper**

Port fee logic from `WrappedUniV2ForTagAI.sol` (BSC) adapted to OZ 4.9 `Ownable` (no `Ownable(msg.sender)` ctor arg — use default).

V4 path: implement `IUnlockCallback` on wrapper; `buyTokenV4` settles native ETH exact-in for token; `sellTokenV4` pulls ERC20, swaps to ETH. Use `CurrencySettler` patterns from `Token.sol` / `RHForkBase`. Document that `PoolKey.hooks` may be zero for generic pools.

- [ ] **Step 3: Unit tests pass (sellsman + fee); V2/V3/V4 compile**

```bash
forge test --match-contract TagAISwapWrapperSellsman -vvv
forge build
```

- [ ] **Step 4: Commit**

```bash
git add src/helper/TagAISwapWrapper.sol src/interfaces/IUniswap*.sol src/interfaces/IWETH.sol test/unit/TagAISwapWrapperSellsman.t.sol
git commit -m "feat(wrapper): add TagAISwapWrapper with V2/V3/V4 fee-on-trade"
```

---

### Task 3: DeployRH wiring

**Files:**
- Modify: `script/DeployRH.s.sol`
- Modify: `_writeAddresses` JSON keys: add `TagAISwapWrapper`, keep ImportHelper; ImportHelper ctor gains `ipshare`

- [ ] **Step 1: Update deploy script**

```solidity
ImportHelper importHelper = new ImportHelper(communityFactory, scf, address(committee), address(ipshare));
TagAISwapWrapper wrapper = new TagAISwapWrapper(address(importHelper), address(ipshare), weth, deployer);
```

Resolve `weth` by chainId: mainnet `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`; testnet via env `RH_WETH` or constant once known.

- [ ] **Step 2: `forge build` + dry simulate**

```bash
FOUNDRY_PROFILE=rh_testnet forge script script/DeployRH.s.sol:DeployRHScript -vvv
```

Expected: compiles and simulates (may need RPC).

- [ ] **Step 3: Commit**

```bash
git add script/DeployRH.s.sol
git commit -m "feat(deploy): wire ImportHelper ipshare and TagAISwapWrapper"
```

---

### Task 4: RH mainnet fork E2E — Import + Nutbox + Wrapper V2/V3/V4

**Files:**
- Create: `test/fork/RHImportWrapper.t.sol`

**Constants (RH mainnet):**

| Name | Address |
|------|---------|
| TOKEN | `0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31` |
| V2_PAIR | `0xd95e8e2cd04c207625c6f23c974d365a5f3a91d3` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| V2_FACTORY | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| V3_FACTORY | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| V3_NPM | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| POOL_MANAGER (V4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| V3_SWAP_ROUTER | Discover from Uniswap RH deployments / `cast` in setUp; if missing, use SwapRouter02 from periphery deploy in test |
| V2_ROUTER | Discover or deploy `UniswapV2Router02(factory, WETH)` in setUp for fork |

- [ ] **Step 1: Scaffold fork test base**

`setUp`: `vm.createSelectFork(RH_RPC_URL)`; deploy Committee/CF/HourlyTick/SCF/IPShare/ImportHelper/Wrapper; `vm.deal(tester, 100 ether)`; `deal(TOKEN, tester, 1_000_000 ether)` (adjust decimals via `IERC20Metadata.decimals()`).

- [ ] **Step 2: `test_import_inject_claim`**

Import → inject → warp 2h → EIP-712 claim (claimSigner = deployer/owner of SCF).

- [ ] **Step 3: `test_wrapper_v2_buy_sell`**

Use live pair liquidity; path `[WETH, TOKEN]` / `[TOKEN, WETH]`.

- [ ] **Step 4: `test_wrapper_v3_buy_sell`**

Create pool via V3 factory + NPM mint full-range; then wrapper V3 buy/sell.

- [ ] **Step 5: `test_wrapper_v4_buy_sell`**

`initialize` PoolKey (ETH/TOKEN or WETH/TOKEN, hooks=0, fee/tickSpacing chosen); add liquidity; wrapper V4 buy/sell.

- [ ] **Step 6: Run**

```bash
FOUNDRY_PROFILE=rh_fork \
RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
FOUNDRY_ETH_RPC_URL= \
forge test --match-contract RHImportWrapper -vvv
```

Expected: all four tests PASS (skip only if RPC unavailable — use `vm.skip` when fork fails).

- [ ] **Step 7: Also run existing fork suite**

```bash
FOUNDRY_PROFILE=rh_fork RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com FOUNDRY_ETH_RPC_URL= \
forge test --match-path test/fork -vvv
```

- [ ] **Step 8: Commit**

```bash
git add test/fork/RHImportWrapper.t.sol
git commit -m "test(fork): ImportHelper + TagAISwapWrapper V2/V3/V4 on RH mainnet"
```

---

### Task 5: Spec/plan polish + Makefile target (optional)

- [x] Add `make test-rh-import-wrapper` invoking Task 4 command.
- [x] Commit docs if any path drift.

---

## Spec coverage check

| Spec requirement | Task |
|------------------|------|
| ImportHelper IPShare + fees | 1 |
| importerOf | 1 |
| Wrapper V2/V3/V4 + sellsman rules | 2 |
| DeployRH wiring | 3 |
| Fork import/inject/claim | 4 |
| Fork V2 live pair | 4 |
| Fork create V3/V4 pools + wrap trade | 4 |
| No DFX | 3 (already removed) |

## Placeholder scan

None intentional. V2/V3 router addresses resolved at test runtime (documented).
