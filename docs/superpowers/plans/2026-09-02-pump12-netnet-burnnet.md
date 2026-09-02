# Pump12 × NetNet × BurnNet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Robinhood Chain（4663）上实现 Pump12：内盘曲线冷启动、Uniswap v4 官方池 + 共享 Hook、BurnNet 回购墙、受控增发模块，以及可插拔 IndexFund v1。

**Architecture:** 与现有 `src/pump/`（Pump V9 + Nutbox）并行，新建 `src/pump12/`。每个社区 Token 在 Listing 时 clone Treasury / BurnNet / Desk / IndexFund；Hook 平台共享、按 `poolId` 隔离。经济比例以 `docs/PUMP12_NETNET_BURNNET_SPEC_CN.md` 为准，实现中不得改比例。

**Tech Stack:** Solidity 0.8.26，Foundry（`via_ir`），OpenZeppelin 4.9，Solady，Uniswap v4-core（`lib/v4-core`），RH fork profile `rh_fork`。

**Spec:** `docs/PUMP12_NETNET_BURNNET_SPEC_CN.md`

## Global Constraints

- 首发网络 chain ID `4663`；原生 gas 为 ETH；计价资产仅 canonical USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`（6 decimals）。
- 官方 DEX 仅为 Uniswap v4 PoolManager `0x8366a39cc670b4001a1128b8f6a443a643e40951`（部署脚本必须再核验）。
- 只支持 exact-input；exact-output 必须 revert。
- 不使用 Nutbox、Morpho、InverseBond、TaxCollector、RFV/NAV。
- Treasury 是上市后唯一 minter；模块集合 Listing 时冻结。
- Eligible USDG 只来自官方池 Hook 分给 BurnNet 的手续费；Bond / PremiumSeller / pTEAM / IndexFund / `addPendingUSDG` 全是 non-eligible。
- IndexFund 实现由 TagAI 设置，Listing 时 clone 并永久绑定；旧 Token 不迁移。
- 变现进墙：`1%` 创建者 / `99%` BurnNet；认购补墙 `A × N` 不抽 1%。
- 不要改现有 `src/pump/Token.sol`、`src/hook/TagAISwapHook.sol` 的 V9 行为。
- 用户沟通用中文；代码标识符用英文；关键不变量加简短中文注释。
- 每一层结束必须：本地 `forge test` 通过，并补该层冻结的工程常量回规范第 23 节。

---

## 为什么拆成六层

规范覆盖至少六个可独立验收的子系统。一层写完再开下一层。禁止从 pTEAM / IndexFund 倒着写。

| 层 | 交付物 | 独立验收 |
|----|--------|----------|
| 0 | 地址门禁、USDG 适配、Pump12 factory 骨架 | 非 4663 / 错 USDG 的部署脚本 revert |
| 1 | 曲线 + Listing + 永久 POL + Hook 收费 | 内盘 750M→15000 USDG；外盘三分账；POL 不可减 |
| 2 | BurnNet + anchor + poke | 七档墙、8% 上限、向下重启 24h 冻结 |
| 3 | Treasury + Staking + Distributor | credit 公式、0.45%/8h、eligible 折算 |
| 4 | BondDepository + PremiumSeller | 3% 折扣、0.25%/8h、POL clip、2× 门 |
| 5 | pTEAM + IndexBondDesk + IndexFund v1 + Factory | 无 strike、6.5%、10%/0.5%、1%/99%、插拔 |

完成一层后，若下一层细节需要更细的 TDD 步骤，再写 `docs/superpowers/plans/2026-09-02-pump12-layer-N.md`，不要提前把六层微步骤写死。

---

## File map

新建目录，不复用 V9 Token/Hook 实现：

```text
src/pump12/
├─ Pump12.sol                    # 创建 Token、内盘结束后 list
├─ Token12.sol                   # ERC20 + 曲线买卖 + 上市后关闭曲线
├─ libraries/
│  ├─ CurveMath.sol              # a,b 整数曲线
│  └─ UsdG.sol                   # 6 decimals 收付与 WAD 换算
├─ hook/
│  └─ NetNetHook.sol             # 共享 hook：fee、TWAP、pending USDG
├─ liquidity/
│  └─ PermanentLiquidityVault.sol
├─ burnnet/
│  └─ BurnNet.sol                # clone per token
├─ treasury/
│  ├─ Treasury.sol               # 唯一 minter
│  └─ TreasuryFactory.sol
├─ staking/
│  ├─ Staking.sol
│  └─ SToken.sol
├─ distributor/
│  └─ Distributor.sol
├─ bond/
│  └─ BondDepository.sol
├─ premium/
│  └─ PremiumSeller.sol
├─ pteam/
│  ├─ PTeam.sol
│  └─ IndexBondDesk.sol
└─ fund/
   ├─ IIndexFund.sol
   ├─ IndexFundFactory.sol
   └─ IndexFundV1.sol

src/interfaces/pump12/          # 对外接口，供测试和模块互调
test/unit/pump12/
test/fork/pump12/               # FOUNDRY_PROFILE=rh_fork
script/DeployPump12RH.s.sol
```

现有 `src/pump/`、`src/hook/TagAISwapHook.sol`、Nutbox **只读参考**，禁止为 Pump12 改它们的经济行为。

---

### Task 0: 骨架、USDG 门禁、部署拒绝条件

**Files:**
- Create: `src/pump12/libraries/UsdG.sol`
- Create: `src/pump12/Pump12.sol`（先只做 create/list 空壳 + 地址校验）
- Create: `script/DeployPump12RH.s.sol`
- Create: `test/unit/pump12/UsdG.t.sol`
- Create: `test/unit/pump12/DeployGuard.t.sol`

**Interfaces:**
- Consumes: 规范 §3、§24 地址。
- Produces:
  - `UsdG.WAD = 1e18`（Token 侧 18 decimals 价格）
  - `UsdG.toWad(uint256 raw6) returns (uint256)` = `raw6 * 1e12`
  - `UsdG.toRaw6(uint256 wad) returns (uint256)`（固定舍入方向：对外付款向下、对协议入账向上，在测试里钉死）
  - `Pump12` constructor 校验 `block.chainid`、USDG `decimals()==6`、`PoolManager` 有代码。

- [ ] **Step 1:** 写 `UsdG.t.sol`：`1e6 raw → 1e18 wad`；`1 wad unit` 转回 raw6 的舍入边界。
- [ ] **Step 2:** `forge test --match-contract UsdGTest` 先失败。
- [ ] **Step 3:** 实现 `UsdG.sol` 与 `DeployPump12RH.s.sol` 的 `require(block.chainid == 4663)`（fork/模拟用 `vm.chainId`）。
- [ ] **Step 4:** `DeployGuard` 测试：错 chainId、USDG decimals≠6、PoolManager 无代码 → revert。
- [ ] **Step 5:** Commit `chore: add Pump12 USDG helpers and deploy guards`

**本层完成标准：** 本地单测通过。还不接曲线。

---

### Task 1: 曲线 + Token12 内盘 + Listing 永久 POL + NetNetHook 收费

**Files:**
- Create: `src/pump12/libraries/CurveMath.sol`
- Create: `src/pump12/Token12.sol`
- Create: `src/pump12/Pump12.sol`（补 createToken / buy / sell / list）
- Create: `src/pump12/liquidity/PermanentLiquidityVault.sol`
- Create: `src/pump12/hook/NetNetHook.sol`
- Create: `src/utils/HookMiner.sol` 已存在，复用挖 `0x0CC1` 类权限位（按 v4 Hooks library 实际需要的 beforeSwap/afterSwap/returns-delta 位重算，不得照搬 Pancake `0x0CC1` 口头值）。
- Create: `test/unit/pump12/CurveMath.t.sol`
- Create: `test/unit/pump12/Token12Curve.t.sol`
- Create: `test/unit/pump12/NetNetHookFee.t.sol`
- Create: `test/fork/pump12/RHListing.t.sol`

**Interfaces:**
- Consumes: Task 0 `UsdG`；v4 `IPoolManager`、`IHooks`、`StateLibrary`、`SqrtPriceMath`。
- Produces:
  - `CurveMath.cost(s, delta) → usdgWad` 使 `cost(0, 750e24) == 15000e18`（WAD）对应 `15000e6` raw，允许规范所述最小舍入误差，测试用精确 raw 断言。
  - `Token12.buy(minTokens) payable-or-USDG` / `sell`；内盘 fee：`TagAI 10% of f` + `creator c of f`，不扣 BurnNet。
  - `Pump12.list(token)` 原子：关曲线、`initialAnchor = curveEndPrice`、铸/转 250M+15000 USDG 进全域仓位、注册 hook、`nextPokeAt = listTime + 8 hours`。
  - `PermanentLiquidityVault` 无 decrease/transfer/collect。
  - `NetNetHook`：`f` 按 USDG 毛额；买入 beforeSwap 扣输入；卖出 afterSwap 扣毛输出；三分账内部记账可拉取；exact-output revert。
  - `addPendingUSDG(poolId, amount)` permissionless，non-eligible。

冻结并写回规范 §23 的本层项：`aRaw`、`bRaw`、`sqrtPriceX96`、全域 ticks、liquidity delta、Hook 权限位。

- [ ] **Step 1:** `CurveMath.t.sol` 断言 `costRawUSDG(0, 750_000_000e18) == 15_000e6`。
- [ ] **Step 2:** 实现整数 `aRaw/bRaw`（不得把规范里的人类可读近似值当部署常量）。
- [ ] **Step 3:** Token12 内盘买卖 + 最后一笔 fill-to-cap 退款测试。
- [ ] **Step 4:** 本地 mock PoolManager 或 fork：Listing 后基础仓位 liquidity 不可减；`polTokenInventory` 用 `SqrtPriceMath` 而非 `balanceOf`。
- [ ] **Step 5:** Hook 测试：两种 token 排序、三分账之和 = 实收 raw、创建者恶意收款合约不能让 swap revert（拉取模式）。
- [ ] **Step 6:** `FOUNDRY_PROFILE=rh_fork forge test --match-path test/fork/pump12/RHListing.t.sol -vvv`
- [ ] **Step 7:** 把标定值写入规范 §23；Commit `feat: add Pump12 curve, listing POL, and NetNetHook fees`

**本层完成标准：** 一条 Token 可在 RH fork 上完成内盘→上市→官方池 exact-input 买卖并正确分账。BurnNet 仓位可以还是空实现（pending 只记账）。

---

### Task 2: BurnNet + Anchor + poke/harvest

**Files:**
- Create: `src/pump12/burnnet/BurnNet.sol`
- Create: `src/pump12/burnnet/BurnNetFactory.sol`
- Modify: `NetNetHook.sol`（pending/active、eligible 子账、TWAP observations、reserve snapshot）
- Create: `test/unit/pump12/BurnNetPoke.t.sol`
- Create: `test/unit/pump12/Anchor.t.sol`
- Create: `test/fork/pump12/RHBurnNet.t.sol`

**Interfaces:**
- Consumes: Listing 后的 `poolId`、`PermanentLiquidityVault` ticks 不得与 BurnNet 档位混淆。
- Produces:
  - `poke()` 每 8 小时最多一次；顺序：结算 → burn → 更新/重启 anchor → 激活 pending。
  - 正常上调：`newAnchor = max(old, min(TWAP, old * 1.08))`。
  - 向下重启：`generation++`，`mintFrozenUntil = now + 24 hours`。
  - 七档相对 anchor：5/10/15/20/30/40/50%；L1/L2/L3 初始 8/12/80，随后 kappa。
  - `harvest()` 在 TWAP 无效时仍可纯结算。
  - Eligible 与 non-eligible 按仓位固化比例消耗，不可重分类。

冻结：每档 tick 宽度、keeper bounty。

- [ ] **Step 1:** 单测七档未成交 / 部分成交 / 穿越 / 连续重启。
- [ ] **Step 2:** 24h mint freeze 期间 Bond/Premium/pTEAM/Desk 入口尚未存在时，先在 BurnNet 上留 `mintFrozenUntil()` view 供后层读取。
- [ ] **Step 3:** TWAP 窗口不足、过期、同 timestamp 多次 swap 只更新最新 tick。
- [ ] **Step 4:** RH fork 布置墙并 poke。
- [ ] **Step 5:** Commit `feat: add Pump12 BurnNet poke, harvest, and anchor`

**本层完成标准：** 手续费和 `addPendingUSDG` 能变成墙上挂单；成交 Token 被 burn；eligible 子账不会被 non-eligible 污染。

---

### Task 3: Treasury + Staking + Distributor

**Files:**
- Create: `src/pump12/treasury/Treasury.sol` + `TreasuryFactory.sol`
- Create: `src/pump12/staking/Staking.sol` + `SToken.sol`
- Create: `src/pump12/distributor/Distributor.sol`
- Create: `test/unit/pump12/Distributor.t.sol`
- Create: `test/unit/pump12/StakingRebase.t.sol`

**Interfaces:**
- Consumes: `Hook.validTWAP(poolId)`、`reserveSnapshot`、`initialAnchor`、`actualBurn`。
- Produces:
  - `Treasury.mint(to, amount)` 仅授权模块。
  - `emissionAnchor = max(initialAnchor, currentAnchor)`。
  - `rate = 0.45% * clamp((P-1)/(1.75-1), 0, 1)` per 8h；`P = TWAP / emissionAnchor`；`TWAP <= emissionAnchor` → 0。
  - credit：`37.5M + eligibleTradeFeeUSDG / initialAnchor + actualBurn`（Token 18 decimals 整数）。
  - `stakingWarmupEpochs = 0`；rebase 快照语义。
  - 无质押者不 mint。

- [ ] **Step 1:** credit 与零排放边界测试。
- [ ] **Step 2:** 饱和归零、anchor 上下移动不重估同一笔 eligible 折算。
- [ ] **Step 3:** 进入/退出 sToken 跨 epoch 边界。
- [ ] **Step 4:** Commit `feat: add Pump12 treasury, staking, and distributor`

**本层完成标准：** 只有官方池 eligible 手续费和真实 burn 能延长排放；Bond 尚未存在所以用 mock `addPendingUSDG` 证明 non-eligible 不加 credit。

---

### Task 4: BondDepository + PremiumSeller

**Files:**
- Create: `src/pump12/bond/BondDepository.sol`
- Create: `src/pump12/premium/PremiumSeller.sol`
- Create: `test/unit/pump12/BondDepository.t.sol`
- Create: `test/unit/pump12/PremiumSeller.t.sol`

**Interfaces:**
- Consumes: `Treasury`、`Hook.validTWAP`、`BurnNet.addPendingUSDG`（或内部入账）、`polTokenInventory`。
- Produces:
  - Bond：`price = max(TWAP * (1-3%), anchor)`；用户 USDG 100% 进 BurnNet；2 天线性归属；8h ≤ 0.25% `epochStartSupply`；30d ≤ 5% `periodStartSupply`；基数期初快照。
  - PremiumSeller：`TWAP > 2 * anchor`；clip = `polTokenInventory * 0.25%`；间隔 1h；卖入官方池；所得 100% BurnNet；不吃 credit。
  - 两者在 `mintFrozenUntil` 期间 revert。

- [ ] **Step 1:** Bond 折扣贴锚、额度快照不被期内增发放大。
- [ ] **Step 2:** PremiumSeller 拒绝 `balanceOf` / BurnNet 仓位当 clip 基数。
- [ ] **Step 3:** Commit `feat: add Pump12 bond depository and premium seller`

---

### Task 5: pTEAM + IndexBondDesk + IndexFund v1

**Files:**
- Create: `src/pump12/pteam/PTeam.sol`
- Create: `src/pump12/pteam/IndexBondDesk.sol`
- Create: `src/pump12/fund/IIndexFund.sol`
- Create: `src/pump12/fund/IndexFundFactory.sol`
- Create: `src/pump12/fund/IndexFundV1.sol`
- Create: `test/unit/pump12/PTeamDesk.t.sol`
- Create: `test/unit/pump12/IndexFundV1.t.sol`
- Create: `test/fork/pump12/RHIndexFund.t.sol`

**Interfaces:**
- Consumes: Task 1–4；`IBasketToken.claimHolderFeesFor`；官方 IndexRegistry / 路由（地址列入部署参数，不得写死未核验值）。
- Produces:
  - `PTeam.exercise(n)`：团队付 0；`TWAP >= 1.2 * A`；`listTime+24h`；累计 ≤ 10% `totalSupply`；Desk 未售 ≤ 0.5%。
  - Desk：`D = max(TWAP * 0.935, 1.2 * A)`；`remittance = A * N` 100% BurnNet；`proceeds = (D-A)*N` → `indexFund.onDeskProceeds`；2 天归属；无撤回。
  - `IIndexFund.onDeskProceeds(uint256 usdgRaw6) external` 仅 Desk。
  - V1：自动买创建时 Index ID；`sellIndex` / `claimHolderFees` 仅创建者；换 USDG 后 `1%` 创建者、`99%` BurnNet；包装原生币不得停留。
  - `IndexFundFactory.setIndexFundImplementation(impl)` 仅 TagAI；只影响之后 Listing。
  - 已绑定 Token 不能迁移。

- [ ] **Step 1:** 无 strike、10%、0.5%、1.2×、24h 门。
- [ ] **Step 2:** 认购失败（指数买失败）整笔回滚，BurnNet 也不入账。
- [ ] **Step 3:** 卖出/领分成 1%/99%；认购 `A*N` 不抽。
- [ ] **Step 4:** 换 IndexFund 实现后，旧 clone 行为不变，新 Listing 用新 impl。
- [ ] **Step 5:** RH fork 买真实 Basket、claimHolderFees → WETH → USDG。
- [ ] **Step 6:** Commit `feat: add Pump12 pTEAM desk and pluggable IndexFund v1`

**明确不做：** IndexFund v2（创建者自选标的）。只把 `IIndexFund` 和 Factory 留好。

---

## 跨层不变量（每层回归）

实现任何一层后，下列测试必须继续绿：

1. Eligible 不能从 Bond / Premium / Desk / Fund / `addPendingUSDG` 产生。
2. 创建者恶意收款合约不能卡住官方池 swap。
3. 共享 Hook 下两个 `poolId` 账本不串。
4. 部署脚本拒绝错误 chain / USDG / PoolManager。

对应规范 §22 的条目按层勾选，不要攒到最后一次性补。

---

## Spec coverage

| 规范章节 | 计划任务 |
|----------|----------|
| §3–6 曲线、创建、内盘费 | Task 1 |
| §7 Listing | Task 1 |
| §8 永久 POL / polTokenInventory | Task 1、4 |
| §9 Hook 费 + addPendingUSDG | Task 1 |
| §10 TWAP | Task 1–2 |
| §11–12 Anchor / BurnNet | Task 2 |
| §13–14 Treasury / Distributor | Task 3 |
| §15 Bond | Task 4 |
| §16 PremiumSeller | Task 4 |
| §17 pTEAM / Desk / Fund | Task 5 |
| §19–21 边界与事件 | 各层实现时带事件，Task 5 收齐 |
| §22 测试清单 | 各层 Step 的测试 + 跨层回归 |
| §23 工程常量 | 各层结束写回规范 |
| §24 RH 基线 | Task 0 部署门禁 + 每层 fork |

IndexFund v2、RWA、创建者自选买币：**不在本计划范围。**

---

## 开工顺序

先做 Task 0 → Task 1。Task 1 在 RH fork 上市跑通之前，不要开始 Task 2。
