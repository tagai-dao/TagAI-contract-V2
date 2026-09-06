# 第 2 期：RH 导入补齐（ImportHelper + TagAISwapWrapper）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans。必须在第 1 期门禁通过后开始。规格 3.2。不要引入 `src/helper/ImportedTokenSwapWrapper.sol`。

**Goal:** RH 外部 ERC20 导入具备「一次登记、可复用 Community、Token 侧 Nutbox fee、报价、拒绝 Pump 代币」，同时保留 IPShare 门槛、调用方 calculator，以及 Wrapper 的 Uniswap V2/V3/V4 直连。

**Architecture:** `ImportHelper` 继续创建 Community；新增对 Wrapper 的 `registerImportedToken`。`TagAISwapWrapper` 增加市场登记、0.2% token fee、10 分钟注入、quote。ETH 侧 1%+1% 不变。买卖函数签名尽量保持，避免无故打破已有 RH 前端。

**Tech Stack:** 与总计划相同。

## Global Constraints

总计划全部适用。额外：不要把 Wrapper ETH 默认费率改成 20 bps；不要支持 Pancake 路径名。

---

## 文件

- Modify: `src/interfaces/IImportHelper.sol`
- Modify: `src/helper/ImportHelper.sol`
- Modify: `src/helper/TagAISwapWrapper.sol`
- Modify: `test/unit/ImportHelper.t.sol`
- Modify: `test/unit/TagAISwapWrapperSellsman.t.sol`
- Modify: `test/fork/RHImportWrapper.t.sol`
- Create: `test/unit/TagAISwapWrapperNutboxFee.t.sol`（本地 mock 社区 + mock 计算器，不必 fork）

参考（只读）：`git show main:src/helper/ImportHelper.sol`、`git show main:src/helper/ImportedTokenSwapWrapper.sol` 的登记 / pending 注入 / quote 逻辑。

---

### Task 1: 登记接口与拒绝 Pump 代币

**Files:**
- Modify: `src/interfaces/IImportHelper.sol`
- Modify: `src/helper/ImportHelper.sol`
- Modify: `src/helper/TagAISwapWrapper.sol`（先做 registrar 存储，交易扣 token fee 下一任务）
- Test: `test/unit/ImportHelper.t.sol`

**Interfaces:**

```solidity
// IImportHelper — Wrapper 仍用 importerOf；Helper 也通过 Wrapper 查询是否已登记
function importerOf(address token) external view returns (address);

// Wrapper
function registerImportedToken(address token, address community, address deployer) external;
function getImportedMarket(address token)
    external
    view
    returns (bool registered, address community, address deployer);
```

ImportHelper 构造函数在现有 4 个地址后增加：

```solidity
address pump_;           // 用于 createdTokens 拒绝；address(0) 仅限测试
address swapWrapper_;    // registrar
```

`createCommunityAndPool` 增加 overload：

```solidity
function createCommunityAndPool(
    address token,
    address calculator,
    bytes calldata distributionPolicy
) external payable returns (address community, address pool);

function createCommunityAndPool(
    address token,
    address calculator,
    bytes calldata distributionPolicy,
    address existingCommunity
) external payable returns (address community, address pool);
```

三参数版本调用四参数版本且 `existingCommunity = address(0)`。

四参数逻辑：

1. `token.code.length == 0` → `InvalidToken`
2. `pump != address(0) && IPump(pump).createdTokens(token)` → `PumpTokenNotImportable`
3. Wrapper `getImportedMarket` 已登记或 `importerOf[token] != 0` → `TokenAlreadyImported`
4. 现有 IPShare 门槛与费用（新建 Community 时收 Community+settings+ipshare；复用 Community 时仍创建缺失的 IPShare，Community 费全额退回）
5. `existingCommunity == 0`：现有创建流程 + `adminSetDev` + 转 owner + `importerOf[token]=creator` + `wrapper.registerImportedToken`
6. `existingCommunity != 0`：`createdCommunity`、`getCommunityToken()==token`、`rewardCalculator()==calculator`；不 `adminAddPool`；只登记

- [ ] **Step 1: 写失败测试**
  - 同一 token 第二次 import revert `TokenAlreadyImported`
  - 传入 Pump `createToken` 的地址 revert `PumpTokenNotImportable`
  - 合法 `existingCommunity` 不新增 Community，`devFund` 不变
  - 错误 calculator 的 existingCommunity revert `InvalidRewardCalculator`

- [ ] **Step 2: 实现并跑**

```bash
forge test --match-contract ImportHelperTest -vv
```

Expected: PASS。更新 `DeployRH.s.sol` 的 Helper 构造参数放到第 2 期末统一做，以免中途部署脚本编不过；若 `forge build` 因脚本失败，可先临时传 `address(0), address(wrapper)` 并加 TODO，或把脚本改动并进本任务。**推荐本任务同步改 `script/DeployRH.s.sol` 构造参数与部署顺序：当前顺序是 Pump → Hook → ImportHelper → Wrapper，第 2 期后 ImportHelper 构造需要 Pump + Wrapper，因此必须调成 Pump → Hook → Wrapper → ImportHelper，否则 Helper 拿不到 Wrapper 地址。**

---

### Task 2: Wrapper Token 侧 Nutbox fee 与 10 分钟注入

**Files:**
- Modify: `src/helper/TagAISwapWrapper.sol`
- Test: `test/unit/TagAISwapWrapperNutboxFee.t.sol`

**Interfaces:**
- `uint16 public nutboxTokenRatio = 20;`  // 0.2%，与 main 导入 token fee 对齐；可 `adminSetFeeRatio` 扩展为三参数
- `mapping(address => uint256) public pendingNutboxInjection`
- `mapping(address => uint256) public lastNutboxInjectionAt`
- `function flushNutboxInjection(address token) external returns (uint256)`

规则（对齐 main Wrapper，长在现有 buy/sell 函数里）：

1. 未登记 token：不抽 token fee（保持现在只抽 ETH）。
2. 已登记 token：从 **用户得到的 token 毛输出**（买）或 **用户打入的 token**（卖）扣 `nutboxTokenRatio`，累计 `pendingNutboxInjection`。
3. 每笔交易先尝试 settle：若 `block.timestamp >= last + 600` 且 pending>0，对登记 Community 的 `rewardCalculator().inject`。失败则保留 pending，交易继续。
4. `flushNutboxInjection` 同样受 10 分钟限制。
5. ETH 侧 `_takeFeesFromEth` 默认 100/100 不准改默认值。

买入时 token 先进 Wrapper 再扣 fee 再转用户（V2 `swapExactETHForTokens` 当前 `to` 是用户——必须改成 `to=address(this)`，扣 fee 后再转 `to`，否则抽不到 token fee）。这是 ABI 行为变化：用户最终到账变少。测试与 fork 测试的 `amountOutMin` 要按扣费后数量。

V3/V4 同样：recipient 先是 Wrapper，再净额转出。

**V4 路径特别说明**：`buyTokenV4`/`sellTokenV4` 走 `unlockCallback`，token 输出由 PoolManager `take` 到 callback 指定的 recipient。要在 callback 里把 swap 输出的 token 先 take 到 Wrapper、扣 0.2% 再转用户。不能像 V2 那样靠 router `to` 参数——V4 的 `take` 目标在 callback 内决定。实现时：
- 买入 V4：callback 里 `take(currency1, address(this), grossOut)`，再 `transfer(user, grossOut - tokenFee)`，`pendingNutboxInjection += tokenFee`。
- 卖出 V4：用户已先把 token 进 Wrapper（`transferFrom`），扣 0.2% 后剩余进 pool swap，ETH 输出按现有 ETH 费路径。
- 若 V4 token-fee 抽取在 callback 内的结算顺序过于复杂，可本任务先对 V4 路径**不抽 token fee**（仅 ETH 费），并在 `quoteBuy`/`sell` 注释与前端文档标明 V4 暂无 Nutbox token fee，门禁不阻塞。但 V2/V3 必须抽。

- [ ] **Step 1: 本地测试（mock ERC20 + mock calculator + 假登记）**
  - 未登记：买卖前后 Wrapper token 余额不累积 Nutbox fee
  - 已登记买：用户少收 0.2%，pending 增加
  - warp 600s 后下一笔把 pending inject 到 calculator
  - inject revert 时 pending 保留、用户兑换仍成功

- [ ] **Step 2: 实现后跑**

```bash
forge test --match-contract TagAISwapWrapperNutboxFeeTest --match-contract TagAISwapWrapperSellsmanTest -vv
```

Expected: PASS。Sellsman 解析顺序保持：显式 sellsman → importer → feeAddress。

---

### Task 3: quoteBuy / quoteSell

**Files:**
- Modify: `src/helper/TagAISwapWrapper.sol`
- Test: 同上及 `test/fork/RHImportWrapper.t.sol`

对 V2：用 router `getAmountsOut`，再扣 ETH 费与 token 费。  
对 V3：若 fork 里已有 quoter 地址则用；没有则本任务只保证 V2 quote，V3/V4 quote 可返回理论值或 `UnsupportedQuote`——**不要为 quote 去搬 NutboxRouter**。  
文档在 Helper 注释写清：V4 quote 第 2 期可以暂不支持，前端继续用独立 quoter；若实现成本低（只读 slot0）可做，但不阻塞门禁。

门禁最低要求：V2 `quoteBuy` / `quoteSell` 与真实 swap 同向、误差可解释为费后。

---

### Task 4: RH fork 回归与税币

**Files:**
- Modify: `test/fork/RHImportWrapper.t.sol`

- [ ] 更新 fork 测试：导入后买到账为扣 0.2% token fee 的净额。
- [ ] 保留现有 V2/V3/V4 路径测试。
- [ ] V2 fee-on-transfer：按余额差结算（可参考 main `ImportedTokenSwapWrapper` 税币测试意图，接到现有 RH V2 路径上）。V3 卖出税币若当前已 revert，保持。

```bash
FOUNDRY_PROFILE=rh_fork forge test --match-path test/fork/RHImportWrapper.t.sol -vv
```

无 RPC 时在本机标为发布前必跑，不要用 BSC fork 代替。

---

### Task 5: 第 2 期门禁

```bash
forge build
forge test --match-contract ImportHelperTest --match-contract TagAISwapWrapperSellsmanTest --match-contract TagAISwapWrapperNutboxFeeTest -vv
```

Expected: PASS。`git diff src/pump src/hook` 应只有第 1 期已合并的改动，本期内不要再改发行栈。

不要部署。进入第 3 期。
