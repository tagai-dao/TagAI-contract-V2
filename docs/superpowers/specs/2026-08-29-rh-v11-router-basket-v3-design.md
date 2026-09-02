# RH V11 Router + 指数 V3 + Index Broker 全盘设计

日期：2026-08-29
仓库：`TagAI-contract-V2`（Pump / Wrapper / NutboxRouter / IndexBroker）+ `robinhood-basket-contract`（指数 V3，分支 `v3`）
前序：三期 V10/V11 发行栈已在本仓落地；本规格**替换**第 3 期里的「方案 B / 空 initialConfig」，并接管指数仓适配。

## 1. 目标

在 RH 主网一次性发布：新 Pump/Hook/导入、平台 NutboxRouter（Uniswap V2+V3+V4）、V3 指数协议（Bridge 走 NutboxRouter）、Index Broker NFT。已有 IPShare 与 Nutbox 全套合约不重部。

## 2. 角色（不可混）

| 组件 | 职责 | 不负责 |
|------|------|--------|
| NutboxRouter | 平台官方池注册表；V2/V3/V4 询价与 exact-in；指数 Bridge（quote↔USDG）；Wrapper 多跳；Broker 社区币定价 | 不扫指数成分直池；不托管 |
| Basket V3 | 成分直池（V2/V3/V4/WETH）；用户用 USDG 买/卖指数 | 不关心 Broker；Bridge 只调 NutboxRouter |
| IndexBroker | 社区币铸 NFT；手续费 native→USDG→买指数；外部币创建时带定价池 | 不走 SwapWrapper 成交 NFT；不管成分腿 |
| TagAISwapWrapper | 用户买卖导入币（含 V3/V4 quote） | 不是 Broker 的成交通道 |

## 3. 硬约束

1. 不重部 version9 的 Committee / CommunityFactory / IPShare / calculators / staking / locking / NFTMining / BasketRegistry。
2. NutboxRouter 必须同时成交 Uniswap V2、V3、V4 池（V3 执行器 ≠「Router 产品版本」）。
3. DEX allowlist 只认 Uniswap V2/V3/V4 Factory 与 RH PoolManager；Pancake/Ramses/Bankr 等不进官方池。
4. 初始池必须是 CoinGecko 认证的 Robinhood Tokenized Stock（或 WETH/USDG），取该代币在 Uniswap 上、报价为 USDG 或 WETH、TVL 最大且费率 < 5% 的池。禁止用搜索结果里虚高 TVL 的仿盘（如 QQQB/SPCXB 数十亿美元盘）。
5. 指数买路径：`native → USDG → BasketSwapRouter.buyExactUsdg`（可用 `buyExactSettlement` 别名）。
6. 配置写完再 `transferOwnership`（Ownable2Step），与 BSC 一致。
7. USDG 在 RH 上是 **6 decimals**（`0x5fc5…1168`），不是 18。

## 4. 池选择规则（GeckoTerminal `network=robinhood`）

1. 用 CoinGecko `platforms.robinhood` 或 GeckoTerminal `coingecko_coin_id` 含 `robinhood-tokenized-stock` 锁定代币地址。
2. `GET /networks/robinhood/tokens/{addr}/pools`，只保留 dex ∈ `{uniswap-v2,v3,v4}-robinhood`。
3. 另一侧必须是 USDG 或 WETH（或 native）。
4. `pool_fee_percentage < 5`。
5. 按 `reserve_in_usd` 取最大。
6. V4 池 GT `address` 是 PoolId；写入 NutboxRouter 前必须用 RH RPC 还原 `PoolKey`（fee / tickSpacing / hooks）并校验 `toId()`。

Hub（必选）：

| 用途 | DEX | 池 | 费 | TVL（约） |
|------|-----|-----|----|-----------|
| USDG/WETH | Uni V3 | `0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca` | 0.01%（fee=100） | $6.4M |

已核实官方股（2026-08-29 GT）：

| 标的 | 代币 | 最大合规池 | 类型 | 费 | TVL |
|------|------|------------|------|----|-----|
| NVDA | `0xd0601ce1…d9eec` | `0xd4eb2120…ea14a3` | V3 vs USDG | 0.05% | $3.9M |
| SPY | `0x117cc213…4c0c` | PoolId `0xfe2a80bb…1526cd` | V4 vs USDG | 0.3% | $2.1M |
| HOOD* | 待官方 coin id | 勿用 HOOD99 `0x97a0…` | — | — | — |
| SPCX | `0x4a0e65a3…5eea` | `0xc6128433…60029` | V3 vs USDG | 0.05% | $0.88M |
| GME | `0x1b0e319c…153e` | `0x0a067568…64e9d` | V3 vs USDG | 0.3% | $0.42M |
| AAPL | `0xaf3d76f1…93f9` | PoolId `0xc748f467…898fdb` | V4 vs USDG | 0.3% | $0.40M |
| TSLA | `0x322f0929…e3e2d` | `0xf4acdaee…889e3` | V3 vs USDG | 0.3% | $0.15M |
| AAPL 备选 | 同上 | `0x783c9bbb…34b7ed` | V3 vs USDG | 0.3% | $0.13M |
| AMZN | `0x12f190a9…1cf54` | `0x8ac92da7…4179ef` | V3 vs USDG | 0.3% | $90k |
| MSFT | `0xe93237c5…2e74` | `0xeb60bcd1…e1510` | V3 vs USDG | 0.3% | $55k |
| QQQ | `0xd5f38791…de68` | `0xd60a5d14…5597d` | V3 vs USDG | 0.05% | $18k |
| BABA | `0xad25ac6c…a1c4` | 最大 Uni 池 30% 费 / TVL~$14k | **不合格，部署时跳过** | | |
| ETH | WETH 即包装原生币 | 不单独建池；Router 1:1 wrap | Venue.WETH | | |
| BTC / SKHY / XAUt | 无合格官方 Uni 池或未认证 | 部署后 `addPricePool` | | | |

\*HOOD 搜索命中的最大 Uni 池是未认证 HOOD99，禁止写入 initialConfig。

路径：每个资产 → USDG 一跳；再经 hub 到 WETH。与 BSC「资产→USDT→WBNB」同构，结算币换成 USDG。

## 5. NutboxRouter（本仓）

- `RH_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2`（Basket fork 已验证，无 deadline 字段）。
- `RH_V3_FACTORY` 保持 `0x1f7d7550…`。
- `initialConfig()` 写入第 4 节核实池 + hub + 双向 route。
- 继续 `uniswapV4Managers=[PoolManager]`，`pancakeV4CLManagers=[]`。
- 嵌套 `isUnlocked` 已存在，供 BasketHook/Executor 调用，禁止删。

## 6. TagAISwapWrapper quote

对齐 BSC `ImportedTokenSwapWrapper`：`quoteBuy/quoteSell(token, sourceType, sourceData, amount)` 走 NutboxRouter 多跳 + 第一跳，再扣 ETH 费与 0.2% token 费。V3/V4 不再 `UnsupportedQuote`。现有 V2 `quoteBuy(path)` 可保留为兼容重载。`sellTokenV3` 补 `_trySettleNutboxInjection`。

## 7. 指数 V3（basket 仓）

已有：`IBridgeRouter` = NutboxRouter 子集；`DeployProtocol` 已读 `BRIDGE_ROUTER`；`tokenVersion=3`；成分 Venue V2/V3/V4/WETH。

本轮 basket 改动：

1. `BasketSwapRouter` 增加 BSC 兼容：`settlementToken() → usdg`，`buyExactSettlement` 转调 `buyExactUsdg`。
2. `BasketToken` 增加 `wbnb() → weth`（IndexBroker / 旧接口）。
3. 部署：复用链上 `BasketRegistry 0x1f997d…`（owner `0x871fb7…` 调 `setRegistrarApproval` 给新 Hook）。新建 DeployerV3、Executor（`bridgeRouter=NutboxRouter`）、Hook、SwapRouter；RouteRegistry/FeeAuction 可新建或复用现网 hub。
4. 不重部 Registry；旧 V1 篮子继续旧 Hook。
5. `OWNER` 交接与现脚本一致；Executor 无 owner。

## 8. IndexBroker（本仓）

- 官方 Pump 币：Uniswap V4 上市池自动激活（已做）。
- 外部币：创建时提供 Uniswap V2/V3/V4 源；定价走 NutboxRouter；NFT 买卖仍转社区币。
- 买指数：`indexV3Router` 用同一 V3 SwapRouter，fee=100 的 USDG/WETH 池，`WETH → USDG`，再 `buyExactSettlement/Usdg`。禁止 `address(0)`。
- Factory 读 version11 里 V3 的 `BasketSwapRouter` / `DefaultIndexToken` / `BasketVersion=3`。
- `addPump(新Pump)`；Committee `adminAddContract(Factory)`。
- 旧 V9 Token 不能官方自动激活（无 `listingHook`）；可当外部币手动给 `fee=0` 的 V4 源。

## 9. 部署顺序

```text
复用 version9 Nutbox + IPShare + BasketRegistry
  → Pump + Hook + Wrapper + ImportHelper（增量脚本，禁止全量 DeployRH）
  → NutboxRouter（initialConfig + V3 executor）→ transferOwnership
  → Basket V3 Executor/Hook/SwapRouter/Deployer（BRIDGE_ROUTER=NutboxRouter）
      Registry owner：setRegistrarApproval(newHook)
  → IndexBroker Factory/模板 → addPump、whitelist、transferOwnership
  → version11.json 回填；status=production
```

环境变量与 BSC 对齐：`PUMP_OWNER`、`NUTBOX_ROUTER_OWNER`、`INDEX_BROKER_OWNER`、basket `OWNER`。Ownable2Step 需对方 `acceptOwnership`。

## 10. 明确不做

- 不把假盘 / 非 Uniswap / 非官方 tokenized stock 写入构造期配置。
- 不重部 IPShare、Committee、CommunityFactory。
- 不让 IndexBroker 调用 TagAISwapWrapper 做 NFT 成交。
- 不把 Pancake V4 CL 加进 RH allowlist。
