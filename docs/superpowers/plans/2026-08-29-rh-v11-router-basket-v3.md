# RH V11 Router + 指数 V3 + Index Broker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans。规格：[`../specs/2026-08-29-rh-v11-router-basket-v3-design.md`](../specs/2026-08-29-rh-v11-router-basket-v3-design.md)。两仓：`TagAI-contract-V2` 与 `../robinhood-basket-contract`（分支 `v3`）。

**Goal:** 打开 NutboxRouter 的 Uniswap V3 成交、写入 GeckoTerminal 核实的官方股最大池、Wrapper V3/V4 quote 对齐 BSC、指数 V3 以 NutboxRouter 为 Bridge、IndexBroker 能用 native 买指数；增量部署且不重部 Nutbox/IPShare。

**Architecture:** NutboxRouter 是唯一平台路由。Basket V3 成分走直池，quote↔USDG 走 Router。IndexBroker 只买指数代币。部署拆成增量脚本 + basket `BRIDGE_ROUTER`。

**Tech Stack:** Foundry、GeckoTerminal API `network=robinhood`、RH Uniswap V2/V3/V4、USDG 6 decimals。

## Global Constraints

- 规格第 3–10 节全部适用。
- 禁止运行全量 `script/DeployRH.s.sol` 对 4663 广播。
- V3 SwapRouter：`0xCaf681a66D020601342297493863E78C959E5cb2`；Factory：`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`。
- Hub：Uni V3 USDG/WETH 0.01% `0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca`。
- 官方股地址与池以规格第 4 节表格为准；HOOD99 / QQQB / SPCXB 虚高盘禁止写入。
- BasketRegistry 复用 `0x1f997dEb6C8Ac7Bb4134Bc7c6bF23F623Cda25C6`。

---

## 文件总表

### TagAI-contract-V2

| 文件 | 职责 |
|------|------|
| `script/config/RHNutboxRouterConfig.sol` | V3 router 非零；`initialConfig` 池+路径 |
| `script/config/fetch_rh_pools.py` | GT 拉取官方股最大 Uni 池，人工确认后改 config |
| `src/router/NutboxRouter.sol` | 保持 V3 成交；构造已支持非零 V3 |
| `script/DeployRHNutboxRouter.s.sol` | 写 version11；`NUTBOX_ROUTER_OWNER` 交接 |
| `src/helper/TagAISwapWrapper.sol` | NutboxRouter 版 quoteBuy/Sell；sellTokenV3 settle |
| `src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol` | 启用 indexV3Router；买指数 ETH→USDG |
| `script/DeployRHIndexBrokerNFT.s.sol` | 读 V3 Basket 地址；whitelist；owner |
| `script/DeployRHPumpRefresh.s.sol` | **新建** 增量 Pump+Hook，复用 IPShare/Nutbox |
| `script/DeployRHImportWrapper.s.sol` | 修 `_defaultPump`；主网写 version11 |
| `deployments/4663/version11.json` | 活动地址 |

### robinhood-basket-contract

| 文件 | 职责 |
|------|------|
| `src/periphery/BasketSwapRouter.sol` | `settlementToken()` + `buyExactSettlement` 别名 |
| `src/BasketToken.sol` | `wbnb()` 别名 `weth` |
| `script/DeployProtocol.s.sol` / `UpgradeRebalance.s.sol` | 支持复用 Registry；`BRIDGE_ROUTER` |
| 测试 | 别名与 Bridge 走真实 NutboxRouter mock |

---

### Task 1: 池配置生成器 + RHNutboxRouterConfig

**Files:**
- Create: `script/config/fetch_rh_pools.py`
- Modify: `script/config/RHNutboxRouterConfig.sol`

**Interfaces:**
- Produces: `initialPricePools()` / `initialRoutes()` 与 BSC `BSCNutboxRouterConfig` 同构；hub = USDG/WETH V3 fee 100。

- [ ] **Step 1:** 脚本规则：`coingecko_coin_id` 含 `robinhood-tokenized-stock`；dex 仅 uniswap-v2/v3/v4-robinhood；对侧 USDG 或 WETH；fee&lt;5%；按 `reserve_in_usd` 最大。输出 JSON 到 stdout。

- [ ] **Step 2:** 把规格表写入 `RHNutboxRouterConfig`：`RH_V3_ROUTER` 非零；`RH_USDG`；每个资产 `_initialV3Pool` 或 `_initialV4Pool`。V4 的 `UniswapV4Source` 用 RH fork 读 PoolManager 校验 `PoolKey.toId()` 等于 GT PoolId。

- [ ] **Step 3:** 路径：`asset→USDG` 一跳；`asset→WETH` = 资产池 + hub（与 BSC asset→USDT→WBNB 相同）。WETH/USDG 只有 hub。跳过 BABA/HOOD/BTC/SKHY/XAUt。

- [ ] **Step 4:** `forge test --match-contract NutboxRouterTest -vv` 须仍通过；补 `test_RH_V3RouterNonZero_SwapPathCompiles`（构造不再把 V3 当 0）。

Run: `forge test --match-contract NutboxRouterTest -vv`
Expected: PASS。

---

### Task 2: NutboxRouter 部署脚本 + owner

**Files:**
- Modify: `script/DeployRHNutboxRouter.s.sol`

- [ ] **Step 1:** 构造传入 `v3Router() != 0`、`v3Factories=[RH_V3_FACTORY]`、`initialConfig()`。

- [ ] **Step 2:** `require(vm.envExists("NUTBOX_ROUTER_OWNER"))`；配置完成后 `if (targetOwner != deployer) router.transferOwnership(targetOwner)`；日志 `ACTION REQUIRED: acceptOwnership`。

- [ ] **Step 3:** `_writeAddresses` 只补丁 `deployments/<chainid>/version11.json` 的 `NutboxRouter` 键（已有 `_setKey`）。仅 broadcast 上下文写文件可选，用户已接受 dry-run 覆盖。

- [ ] **Step 4:** Dry-run：`forge script script/DeployRHNutboxRouter.s.sol --rpc-url $RH_RPC_URL --chain-id 4663 -vv`
Expected: 构造不 revert；日志打印 V3 router 非零。

---

### Task 3: Wrapper V3/V4 quote 对齐 BSC

**Files:**
- Modify: `src/helper/TagAISwapWrapper.sol`
- Modify: `test/unit/TagAISwapWrapperNutboxFee.t.sol`
- Test: 现有 `quoteBuyV3` revert 用例改为正路径

**Interfaces:**
- 新增（与 BSC 同形，可与旧 V2 path 重载共存）：

```solidity
function quoteBuy(address token, INutboxRouter.SourceType sourceType, bytes calldata sourceData, uint256 nativeAmountIn) external returns (uint256);
function quoteSell(address token, INutboxRouter.SourceType sourceType, bytes calldata sourceData, uint256 tokenAmountIn) external returns (uint256);
```

Wrapper 构造或 `adminSetNutboxRouter(address)` 注入 NutboxRouter。第一跳用 `NutboxSpotPrice.quote`；native↔quote 用 `INutboxRouter.quote`。`sellTokenV3` 开头调用 `_trySettleNutboxInjection(token)`。

- [ ] **Step 1:** 单测：已登记代币 V3 source 的 quoteBuy 扣 0.2% token fee；旧 `quoteBuyV3` 可改为转调或删除 revert。

- [ ] **Step 2:** 实现最小代码使测试通过。

Run: `forge test --match-contract TagAISwapWrapperNutboxFee -vv`
Expected: PASS。

---

### Task 4: 增量 Pump 部署（不重部 Nutbox/IPShare）

**Files:**
- Create: `script/DeployRHPumpRefresh.s.sol`（对照 `main:script/DeployBSCPumpRefresh.s.sol`）

- [ ] **Step 1:** 从 `deployments/4663/version9.json` 读 `Committee, CommunityFactory, HourlyTickCalculator, SocialCurationFactory, IPShare, PoolManager, WETH, feeAddress`。禁止 `new IPShare` / `new Committee`。

- [ ] **Step 2:** 部署 Token 实现、Pump（`NutboxDeployConfig` 填 RH 地址）、Hook（CREATE2 挖盐）、`adminSetHookAddress` / `adminSetNutbox` / `adminSetCalculator`。

- [ ] **Step 3:** `PUMP_OWNER`（默认 deployer）`transferOwnership`；写 version11 的 Pump/Hook/TokenImplementation + Previous* 已在 json 骨架里。

- [ ] **Step 4:** 修 `DeployRHImportWrapper._defaultPump`：4663 从 version11 读 Pump，禁止返回测试网常量。主网 `_patchAddresses` 必须写 version11。

Run: `forge build`
Expected: 成功。

---

### Task 5: Basket V3 别名 + 部署接线

**Files:**（仓 `../robinhood-basket-contract`）
- Modify: `src/periphery/BasketSwapRouter.sol`
- Modify: `src/BasketToken.sol`
- Modify: `script/DeployProtocol.s.sol`（可选：`EXISTING_REGISTRY` env）
- Test: `test/BasketHookV3.t.sol` 或新 `test/IndexBrokerCompat.t.sol`

```solidity
// BasketSwapRouter
function settlementToken() external view returns (address) { return usdg; }
function buyExactSettlement(address basket, uint256 settlementTokenIn, uint256 minBasketOut, bytes calldata hookData, address recipient)
    external returns (uint256) { return buyExactUsdg(basket, settlementTokenIn, minBasketOut, hookData, recipient); }

// BasketToken
function wbnb() external view returns (address) { return weth; }
```

- [ ] **Step 1:** 单测：`settlementToken()==usdg`；`wbnb()==weth`；`buyExactSettlement` 与 `buyExactUsdg` 同一事件/余额。

- [ ] **Step 2:** `DeployProtocol`：`BRIDGE_ROUTER` 必须 `code.length>0` 且 `wrappedNative()==WETH`。若 `EXISTING_REGISTRY` 非零，跳过 `new BasketRegistry`，不在脚本里 `transferOwnership` Registry（已是 `0x871fb7…`）；广播后打印 `setRegistrarApproval(newHook, true)` 需 Registry owner 执行。

- [ ] **Step 3:** 在 basket 仓 `forge test --match-contract BasketHookV3`。

Expected: PASS。

---

### Task 6: IndexBroker 买指数打开 V3

**Files:**
- Modify: `src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol`（去掉「方案 B 则 revert」；`indexV3Router==0` 仅当未配置）
- Modify: `src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol`（构造允许非零 V3）
- Modify: `script/DeployRHIndexBrokerNFT.s.sol`
- Modify: `test/unit/IndexBrokerNFT.t.sol`：增加 native 买指数（mock V3 + `buyExactSettlement`）

- [ ] **Step 1:** Factory 部署传入 `indexV3Router=RH_V3_ROUTER`，`indexV3Fee=100`（与 hub 0.01% 一致）。`getPool(WETH, USDG, 100)` 必须有代码。

- [ ] **Step 2:** `buyIndexWithNativeReserve`：`exactInputSingle{value}` tokenIn=WETH tokenOut=USDG fee=100，再 `basketSwapRouter.buyExactSettlement`。USDG 6 decimals：`minSettlementOut` 由调用方传入，合约不做 18→6 换算。

- [ ] **Step 3:** 脚本读 version11：`NutboxRouter`、`Pump`、`CommunityFactory`、`BasketRegistry`、以及 basket 仓写入的 `BasketSwapRouter` / `DefaultIndexToken` / `BasketVersion=3`。缺一则 revert，不再静默 skip Factory。

- [ ] **Step 4:** `INDEX_BROKER_OWNER`；`factory.addNFTTemplate` 后 `ICommittee(committee).adminAddContract(factory)`（需 Committee owner 密钥或打印待办）；`factory.addPump(v11Pump)`；`transferOwnership`。

Run: `forge test --match-contract IndexBrokerNFTTest -vv`
Expected: PASS；官方激活仍为 `UNISWAP_V4`。

---

### Task 7: version11 + README + 发布清单

**Files:**
- Modify: `deployments/4663/version11.json` 增加 `USDG`、`BasketSwapRouter`、`DefaultIndexToken`、`BasketVersion`、`BasketTokenDeployerV3` 键（部署后填）。
- Modify: `README.md`、`src/router/README.md` 删除方案 B / addresses.json。
- Modify: `src/nutbox/dapps/index-broker-nft/README.md` 官方激活改为 Uniswap V4；买指数改为 USDG。

发布清单（人工）：

1. `DeployRHPumpRefresh` broadcast
2. ImportHelper + Wrapper + `adminSetNutboxRouter`
3. `DeployRHNutboxRouter`
4. Basket V3（`BRIDGE_ROUTER=NutboxRouter`）+ Registry `setRegistrarApproval`
5. `DeployRHIndexBrokerNFT`
6. 各 `acceptOwnership`
7. 前端：Broker 外部币带 `SourceType`+`sourceData`；Wrapper 用新 quote ABI

- [ ] **Step 1:** `forge test --no-match-path 'test/fork/**'`
Expected: 全绿。
- [ ] **Step 2:** `FOUNDRY_PROFILE=rh_fork forge test --match-contract RHImportWrapper -vv`（需 RPC）。

---

## 规格覆盖自检

| 规格项 | 任务 |
|--------|------|
| GT 最大合规池写入构造 | T1 |
| Uniswap V3 成交 | T1–T2 |
| Broker 只买指数 | T6 |
| Router 支持 V2/V3/V4 池 | T1 |
| 外部币给池、不经 Wrapper 成交 NFT | 已有 AMM；T6 不改此路径 |
| 不重部 IPShare/Nutbox | T4 |
| V3/V4 quote 同 BSC | T3 |
| 配完转 owner | T2 T4 T5 T6 |
| 指数 V3 Bridge=NutboxRouter | T5 |
| USDG 6 decimals | T6 注释 + 调用方 minOut |

## 执行方式

Plan 已保存。两种执行：

1. **Subagent-Driven（推荐）** — 每任务新开子代理，任务间复查
2. **本会话 Inline** — 按 T1→T7 顺序改两仓代码

选哪个？
