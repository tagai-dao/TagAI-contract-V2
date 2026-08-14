# 毕业后 LP Fee + Hook 费率改造 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 毕业池启用原生 0.3% LP fee；Hook 写死 IPShare 0.3%（BNB）+ 方向性 0.3%（买抽 Token→Hook 分发，卖抽 BNB→平台）；Token 永久锁仓并提供 permissionless `collectFees()`。

**Architecture:** 不新增 LiquidityManager。Listing LP 仍由 `Token` 持有。`PoolKey.fee=3000`。Hook 不再读 `Pump.feeRatio`。内盘费率逻辑完全不动。

**Tech Stack:** Solidity 0.8.26、Foundry、PancakeSwap Infinity CL（`infinity-core`）、现有 `TagAISwapHook` / `Token` / `Pump`

**Spec:** `docs/superpowers/specs/2026-08-13-post-list-lp-fee-and-hook-fee-redesign.md`

## 全局约束

- 内盘继续使用 `Pump.feeRatio`；Hook 外盘费率不得调用 `pump.getFeeRatio()`
- Hook 常量：`IPSHARE_FEE_BPS = 30`、`DIRECTIONAL_FEE_BPS = 30`、`DIVISOR = 10000`
- 池子 `fee = 3000`（0.3%）；接受 Pancake protocol ≈0.1%
- 卖侧 IPShare 0.3% 与平台方向费 0.3% 均按**同一笔 gross BNB**计算（不嵌套相减）
- 买侧方向费按 swap **gross Token output**（delta 已含池子 LP/protocol 影响）
- `collectFees`：任何人可调；BNB→`feeReceiver`；Token→Hook；零费用时 no-op + 事件（金额为 0）
- **禁止** decrease / remove listing liquidity
- 仅影响新 listing；不做旧池迁移
- 每个 Task 结束后按用户习惯可暂缓 commit；若执行 agent 需要 commit，用中文或英文短句说明 why

## 文件职责

| 文件 | 职责 |
|------|------|
| `src/pump/Token.sol` | `fee=3000`；`collectFees()` + lock 回调扩展；事件 |
| `src/hook/TagAISwapHook.sol` | 写死费率；BNB IPShare；买 Token / 卖 BNB 方向费 |
| `src/interfaces/IToken.sol`（若已有事件/接口） | 如需对外暴露 `collectFees` 则补签名 |
| `test/unit/TagAISwapHook.t.sol` | Hook 费率与方向费单测 |
| `test/unit/TagAISwapHook.t.sol` 或 `test/unit/Token.t.sol` | `collectFees` / listing fee |
| `test/property/FeeProperty.t.sol` | 外盘断言与 `feeRatio` 解耦；内盘属性保留 |
| `test/fork/*.sol`、`test/integration/*`、`test/benchmark/*`、`test/security/*`、`test/property/HookProperty.t.sol` | `fee: 0` → `3000` 及行为对齐 |

---

### Task 1: Token listing 启用 `fee = 3000`

**Files:**
- Modify: `src/pump/Token.sol`（`_makeLiquidityPool` 内 `PoolKey.fee` 与注释）
- Modify: 所有测试里手写 `fee: 0` 的 PoolKey（至少：`test/unit/TagAISwapHook.t.sol`、`test/fork/BSCForkBase.t.sol`、`test/benchmark/GasBenchmark.t.sol`；用 `rg 'fee: 0'` 扫全仓）
- Test: fork 或 unit 中断言 listing 后 `getSlot0` 的 `lpFee == 3000`（fork 更真实；若 unit 用 Mock 则至少断言构造的 PoolKey.fee）

**Interfaces:**
- Consumes: 无
- Produces: 新 listing 的 `PoolKey.fee == 3000`

- [ ] **Step 1: 搜索并列出所有 `fee: 0` 测试构造点**

```bash
rg -n "fee: 0" test/ src/pump/Token.sol
```

- [ ] **Step 2: 改 Token listing**

把 `src/pump/Token.sol` 中：

```solidity
// fee=0 means zero native pool fee; all fees are collected by TipTagSwapHook.
```

与

```solidity
fee: 0, // No native LP fee, all fees via Hook
```

改为：

```solidity
// fee=3000 → 0.3% 原生 LP fee；Hook 另收 IPShare + 方向费（见 TagAISwapHook）
```

```solidity
fee: 3000, // 0.3% native LP fee for external LPs + locked listing position
```

- [ ] **Step 3: 同步测试里的 PoolKey.fee 为 3000**

凡是模拟已 listing 池的 `PoolKey`，`fee` 改为 `3000`，否则 poolId / 行为与生产路径不一致。

- [ ] **Step 4: 加/改断言（fork 优先）**

在 `test/fork/BSCForkBase.t.sol` 的 listing 成功路径后增加：

```solidity
(,,, uint24 lpFee) = ICLPoolManager(address(clPoolManager)).getSlot0(token.v4PoolId());
assertEq(lpFee, 3000, "listing pool lpFee must be 0.3%");
```

（若 `getSlot0` 返回值顺序以 infinity-core 为准：`(sqrtPriceX96, tick, protocolFee, lpFee)`。）

- [ ] **Step 5: 跑相关测试**

```bash
forge test --match-contract TagAISwapHookTest -vv
# 若有 RPC：
# FOUNDRY_PROFILE=fork forge test --match-contract BSCForkTest --fork-url $BSC_RPC_URL -vvv
```

Expected: 与 fee 相关的构造通过；fork 断言 `lpFee==3000`。

- [ ] **Step 6: Commit（可选）**

```bash
git add src/pump/Token.sol test/
git commit -m "$(cat <<'EOF'
feat: set listing pool native LP fee to 0.3%

EOF
)"
```

---

### Task 2: Token 公开 `collectFees()`（永久锁仓、只收手续费）

**Files:**
- Modify: `src/pump/Token.sol`（`collectFees`、扩展 `lockAcquired`、事件）
- Modify: `src/interfaces/IToken.sol`（若项目习惯把对外方法放接口）
- Test: `test/unit/Token.t.sol`（若无则在 `test/fork/BSCForkNutboxInject.t.sol` / 新建 `test/unit/TokenCollectFees.t.sol`）

**Interfaces:**
- Consumes: listing 时使用的 `LISTING_TICK_LOWER/UPPER`、`salt=bytes32(0)`、`v4PoolId`、`clPoolManager`、`vault`
- Produces:
  - `function collectFees() external returns (uint256 bnbAmount, uint256 tokenAmount)`
  - `event ListingFeesCollected(address indexed caller, uint256 bnbAmount, uint256 tokenAmount)`

**实现要点：**

1. `require(listed)`。
2. `vault.lock` 回调内 `modifyLiquidity`，`liquidityDelta = 0`，ticks/salt 与 listing 完全一致。
3. 使用返回的 `feeDelta`（或 `delta` 中正数部分）`vault.take` 到 Token。
4. BNB：`feeReceiver.call{value: bnbAmount}`；Token：转给 `IPump(manager).getHookAddress()`。
5. 任一步失败则整笔 revert。
6. 金额均为 0：仍 emit 事件，不 revert。
7. **不得**出现 `liquidityDelta < 0`。

扩展 `lockAcquired` 建议用枚举/op 区分 seed vs collect：

```solidity
// data = abi.encode(uint8 op, PoolKey key, int24 tickLower, int24 tickUpper)
// op: 0 = seed listing LP, 1 = collect fees only
```

- [ ] **Step 1: 写失败测试（fork 或 mock）**

核心断言示意：

```solidity
function test_collectFees_routesBnbToPlatformAndTokenToHook() public {
    // 1) list token
    // 2) 做若干 buy/sell 产生 LP fee
    address collector = makeAddr("collector");
    address platform = pump.getFeeReceiver();
    address hookAddr = pump.getHookAddress();

    uint256 platformBefore = platform.balance;
    uint256 hookTokenBefore = IERC20(address(token)).balanceOf(hookAddr);

    vm.prank(collector);
    (uint256 bnbAmount, uint256 tokenAmount) = token.collectFees();

    assertGe(bnbAmount + tokenAmount, 0);
    assertEq(platform.balance - platformBefore, bnbAmount);
    assertEq(IERC20(address(token)).balanceOf(hookAddr) - hookTokenBefore, tokenAmount);

    // 紧接着再 collect 应为 0
    vm.prank(collector);
    (uint256 bnb2, uint256 token2) = token.collectFees();
    assertEq(bnb2, 0);
    assertEq(token2, 0);
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
forge test --match-test test_collectFees_routesBnbToPlatformAndTokenToHook -vv
```

Expected: FAIL（`collectFees` 不存在或行为不对）。

- [ ] **Step 3: 实现 `collectFees` + 回调分支**

关键片段（实现时按现有 `lockAcquired` 风格嵌入，注意可读性与简短注释）：

```solidity
event ListingFeesCollected(address indexed caller, uint256 bnbAmount, uint256 tokenAmount);

uint8 private constant LOCK_OP_SEED = 0;
uint8 private constant LOCK_OP_COLLECT = 1;

function collectFees() external nonReentrant returns (uint256 bnbAmount, uint256 tokenAmount) {
    if (!listed) revert TokenNotListed(); // 或现有等价 error

    address hookAddr = IPump(manager).getHookAddress();
    PoolKey memory poolKey = _listingPoolKey(); // 抽私有函数重建与 listing 相同的 PoolKey（fee=3000）

    bytes memory data = abi.encode(
        LOCK_OP_COLLECT,
        poolKey,
        LISTING_TICK_LOWER,
        LISTING_TICK_UPPER
    );
    vault.lock(data);

    bnbAmount = address(this).balance;
    tokenAmount = balanceOf(address(this)); // 若 Token 自身还残留 listing dust，需只转发本次 take 的增量
    // 推荐：在 lock 回调内直接路由，或回调前记录 balance 再用差额，避免把历史 dust 误转走

    emit ListingFeesCollected(msg.sender, bnbAmount, tokenAmount);
}
```

**强烈建议：** 在 collect 回调内直接：

1. `modifyLiquidity(delta=0)`
2. `take` 到 Token
3. 立刻把本次 `feeDelta` 对应的 BNB 打给平台、Token 打给 Hook  
   这样不会误转 listing 残留 dust。

seed 路径保持现有加仓逻辑；仅把 `abi.encode` 加上 `op` 前缀并更新 `lockAcquired` 解码。

- [ ] **Step 4: 跑测试通过**

```bash
forge test --match-test test_collectFees -vv
```

- [ ] **Step 5: Commit（可选）**

```bash
git add src/pump/Token.sol src/interfaces/IToken.sol test/
git commit -m "$(cat <<'EOF'
feat: add permissionless collectFees on locked listing LP

EOF
)"
```

---

### Task 3: Hook — 去掉 feeRatio，BNB 侧只收 IPShare 0.3%

**Files:**
- Modify: `src/hook/TagAISwapHook.sol`（常量、`_collectBeforeSwapFee`、`_collectAfterSwapFee`、`_distributeFees`、文件头注释）
- Modify: `test/property/FeeProperty.t.sol`（凡断言 Hook 使用 `feeRatio[0]+[1]` 的用例改为写死 30 BPS IPShare；**保留**内盘 anti-snipe / bonding `feeRatio` 用例）
- Modify: `test/unit/TagAISwapHook.t.sol` 等相关断言

**Interfaces:**
- Consumes: Task 1 的池子 fee 变更（行为独立）
- Produces:
  - `uint256 internal constant IPSHARE_FEE_BPS = 30;`
  - `uint256 internal constant DIRECTIONAL_FEE_BPS = 30;`（本 Task 可先声明，Task 4 使用）
  - BNB 侧总 Hook take = 仅 IPShare 0.3%（本 Task）；平台 BNB 改由方向费/collect 产生

- [ ] **Step 1: 写/改失败测试**

```solidity
function test_hook_bnbSideOnlyChargesIpshareBps() public {
    // exact-in buy: beforeSwap 应对 specified BNB 收取 0.3%，且全部进 IPShare valueCapture 路径
    // 平台 feeReceiver 不应因旧 feeRatio[0] 在本笔买入 BNB 侧收款
}
```

同时把 `FeeProperty` 里「platformFee = swapAmount * feeRatio[0]」这类**针对 Hook**的属性改成：

```solidity
uint256 ipshareFee = (swapAmount * 30) / DIVISOR;
uint256 platformFeeFromHookBnb = 0; // 买入 BNB 侧不再给平台
```

- [ ] **Step 2: 跑测试确认旧实现失败或断言需更新**

```bash
forge test --match-contract FeePropertyTest -vv
forge test --match-contract TagAISwapHookTest -vv
```

- [ ] **Step 3: 改 Hook 收费核心**

替换 `pump.getFeeRatio()` 逻辑，示意：

```solidity
uint256 private constant IPSHARE_FEE_BPS = 30;
uint256 private constant DIRECTIONAL_FEE_BPS = 30; // Task 4

function _collectBeforeSwapFee(...) internal returns (int128) {
    uint256 specifiedAmount = params.amountSpecified < 0
        ? uint256(-params.amountSpecified)
        : uint256(params.amountSpecified);

    // 卖出 exact-out BNB：BNB 侧应收 IPShare + 平台方向费 = 60 BPS（见 Task 4）
    // 本 Task 先只收 IPSHARE；Task 4 再按方向把卖侧加成 60 BPS 或拆分 take
    uint256 bps = IPSHARE_FEE_BPS;
    uint256 totalFee = (specifiedAmount * bps) / DIVISOR;
    if (totalFee == 0) return 0;

    vault.take(key.currency0, address(this), totalFee);
    address token = poolToken[key.toId()];
    _distributeFees(token, 0, totalFee, hookData); // platform=0, 全给 IPShare
    emit SwapFeeCollected(key.toId(), token, 0, totalFee);
    return totalFee.toInt128();
}
```

`_collectAfterSwapFee` 同样去掉 `feeRatio`，先按 IPShare-only；**卖侧 60 BPS** 在 Task 4 一次性对齐，避免中间状态测不通就在本 Task 末尾直接把卖侧 BNB 做成 60 BPS（IPShare 30 + platform 30），买入 BNB 仍 30。

**推荐本 Task 结束态（可测）：**

| 路径 | BNB Hook 总 BPS | 拆分 |
|------|-----------------|------|
| 买（BNB 为 fee 币） | 30 | 全 IPShare |
| 卖（BNB 为 fee 币） | 60 | 30 IPShare + 30 平台 |

这样 Task 3+4 若合并卖侧拆分也可；若拆 Task，把卖侧 60 放 Task 4 前半。

- [ ] **Step 4: 更新 `_distributeFees` 注释；删除依赖 feeRatio 的注释**

- [ ] **Step 5: 测试通过**

```bash
forge test --match-contract TagAISwapHookTest -vv
forge test --match-contract FeePropertyTest -vv
forge test --match-contract HookProperty -vv
forge test --match-contract HookSecurity -vv
```

- [ ] **Step 6: Commit（可选）**

```bash
git add src/hook/TagAISwapHook.sol test/
git commit -m "$(cat <<'EOF'
feat: hardcode hook BNB IPShare fee; drop feeRatio dependency

EOF
)"
```

---

### Task 4: Hook — 方向性 0.3%（买 Token→Hook，卖已在 Task3 含平台 BNB）

**Files:**
- Modify: `src/hook/TagAISwapHook.sol`（`afterSwap` / 可能 `beforeSwap`）
- Test: `test/unit/TagAISwapHook.t.sol`、`test/integration/FullLifecycle.t.sol`、fork inject 相关

**Interfaces:**
- Consumes: Task 3 常量与 BNB 收费
- Produces: 买侧 `vault.take(currency1, hook, tokenFee)`；Token 留在 Hook 余额供 Nutbox 分发

**关键缺口（现状）：**  
exact-in 买（ETH specified）时 `afterSwap` 早退只 `_tryInject`，**不会**再收 Token 费。必须在该分支增加买侧方向费。

- [ ] **Step 1: 写失败测试**

```solidity
function test_buy_takesDirectionalTokenFeeIntoHook() public {
    // zeroForOne buy，记录 hook 的 token balance
    // afterSwap 后 hook 余额增加 ≈ boughtAmount * 30 / 10000
    // periodState 累计仍基于 bought delta（或明确：注入记账用 fee 前/后的哪一个 —— 规格：用 swap delta 的 gross token output 算方向费；
    // `_tryInject` 继续用 delta.amount1()；若方向费从买家输出再 take，需确认 inject 记账是否应从「用户实得」还是「池子输出」——
    // **本计划选定：方向费按 delta 显示的 token output 计；`_tryInject` 仍用同一 delta（与现网一致）。**
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
forge test --match-test test_buy_takesDirectionalTokenFeeIntoHook -vv
```

- [ ] **Step 3: 实现买侧 Token 收取**

在 `afterSwap` 中，当 `params.zeroForOne`（买）时：

```solidity
uint256 bought = _boughtAmountFromDelta(delta.amount1());
uint256 tokenFee = (bought * DIRECTIONAL_FEE_BPS) / DIVISOR;
if (tokenFee > 0) {
    vault.take(key.currency1, address(this), tokenFee);
    // afterSwapReturnsDelta：返回值需把 unspecified/specified 侧 hook delta 报告正确
    // 买且 ETH 已在 beforeSwap 收过：这里追加的是 currency1 的 afterSwap fee delta
}
_tryInject(token, delta.amount1());
```

**Delta 会计：**  
Hook 已启用 `afterSwapReturnsDelta`。对「ETH 已在 beforeSwap 收取」的买路径，当前返回 `0`；增加 Token take 后，必须返回对应的 `int128` afterSwap delta（按 PCS Infinity 约定：hook 取走 output 时减少用户所得）。对照 `infinity-core` 文档/现有 afterSwap 卖路径实现，保证 vault 结算平衡。

若单测用 Mock 不校验 vault 平衡，fork 测试必须覆盖真实结算。

卖侧：确保 BNB 上 `IPSHARE + DIRECTIONAL` 同基数：

```solidity
uint256 ipshareFee = (bnbAmount * IPSHARE_FEE_BPS) / DIVISOR;
uint256 platformFee = (bnbAmount * DIRECTIONAL_FEE_BPS) / DIVISOR;
uint256 totalFee = ipshareFee + platformFee;
vault.take(currency0, address(this), totalFee);
_distributeFees(token, platformFee, ipshareFee, hookData);
```

- [ ] **Step 4: 测试通过（unit + 至少一条 fork/integration swap）**

```bash
forge test --match-contract TagAISwapHookTest -vv
forge test --match-contract FullLifecycle -vv
```

- [ ] **Step 5: Commit（可选）**

```bash
git add src/hook/TagAISwapHook.sol test/
git commit -m "$(cat <<'EOF'
feat: add directional hook fee (buy token, sell BNB)

EOF
)"
```

---

### Task 5: 全量回归与 gas 基准

**Files:**
- Modify: 剩余 `test/**` 中过时的 `fee: 0`、旧 0.6% BNB 双边假设
- Modify: `test/benchmark/GasBenchmark.t.sol`（记录 swap / collectFees gas）

- [ ] **Step 1: 全仓扫描残留假设**

```bash
rg -n "fee: 0|feeRatio\[0\]|getFeeRatio\(\)|0\.6%|platformFee.*30.*30" test/ src/hook/
```

逐处按新模型改掉（内盘测试保留 feeRatio）。

- [ ] **Step 2: 跑全量本地测试**

```bash
forge test
```

Expected: PASS

- [ ] **Step 3: 跑 fork（有 RPC 时）**

```bash
FOUNDRY_PROFILE=fork forge test --match-path test/fork --fork-url $BSC_RPC_URL -vvv
```

Expected: listing `lpFee==3000`；buy/sell/collect/inject 路径通过。

- [ ] **Step 4: Gas benchmark**

```bash
forge test --match-contract GasBenchmark -vvv
```

记录相对改前的 swap gas 变化（允许因多一次 token take 上升）。

- [ ] **Step 5: Commit（可选）**

```bash
git add test/
git commit -m "$(cat <<'EOF'
test: align suite with post-list LP and hook fee model

EOF
)"
```

---

### Task 6: 文档与 Pump 注释（可选小改）

**Files:**
- Modify: `src/pump/Pump.sol`（`feeRatio` 旁注释：仅内盘）
- Modify: `src/hook/TagAISwapHook.sol` 顶部 NatSpec
- Modify: `CLAUDE.md` 中「10-minute settlement / fee」相关一句（若与事实不符）

- [ ] **Step 1: 更新注释，避免后人再以为 Hook 读 feeRatio**
- [ ] **Step 2: `forge build` 确认无编译问题**
- [ ] **Step 3: Commit（可选）**

---

## Spec 覆盖自检

| Spec 要求 | Task |
|-----------|------|
| `PoolKey.fee=3000` | Task 1 |
| Token 锁仓 + `collectFees` permissionless | Task 2 |
| BNB→平台、Token→Hook | Task 2 |
| Hook 不读 feeRatio；IPShare 0.3% BNB | Task 3 |
| 买 Token 0.3%→Hook；卖 BNB 0.3%→平台 | Task 3–4 |
| 同基数 gross BNB | Task 3–4 |
| 内盘 feeRatio 不变 | Task 3/5（明确不改 Token bonding 逻辑） |
| 无 LiquidityManager / 无撤池 | 全程 |
| 测试计划 1–7 | Task 1–5 |

## 占位符扫描

无 TBD/TODO；卖侧 60 BPS 在 Task 3/4 边界已写明推荐结束态。

---

## 执行方式

计划已保存到 `docs/superpowers/plans/2026-08-13-post-list-lp-fee-and-hook-fee-redesign.md`。

两种执行方式：

1. **Subagent-Driven（推荐）** — 每个 Task 开新子 agent，Task 间复查  
2. **Inline Execution** — 本会话按 Task 连续实现，设检查点  

你要哪一种？说「开始写代码」并选 1 或 2 即可。
