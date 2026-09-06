# RH V11 发布测试门禁

本矩阵用于 RH V9 → V11 迁移的发布验收。文中的 Token12 指当前 RH V11
Pump 创建的 `src/pump/Token.sol` 实现。

## 发布阶段

1. 本地确定性测试必须全部通过。
2. 部署脚本必须只部署 V11 增量组件，并复用 V9 Nutbox/IPShare。
3. 分阶段部署主网，每一步写入并校验 `deployments/4663/version11.json`。
4. 部署完成后，以专用 RH RPC fork 主网已部署地址，重复真实合约端到端测试。
5. fork、地址关系、权限和资产守恒全部通过后，才开放前端流量。

## Token12 与 IndexBroker 生命周期

| 能力 | 真实依赖范围 | 发布用例 |
| --- | --- | --- |
| Token 创建 | Pump、IPShare、CommunityFactory、Calculator、SocialCuration | `test_releaseLifecycle_tokenMarketAndBurnIndexBroker` |
| 内盘买入/卖出 | Token bonding curve、动态费用 | 同上 |
| 自动上盘 | Token、Uniswap V4 PoolManager、TagAISwapHook | 同上 |
| 外盘买入/卖出 | 真实 V4 pool、Hook、双向结算 | 同上 |
| IndexBroker 创建 | Community、Committee、IndexBrokerNFTFactory | 两个 release lifecycle 用例 |
| Burn 模板 Mint | 白名单 Mint、付费 Mint、社区代币付款 | Burn lifecycle |
| 推荐 | 推荐佣金到账、推荐计数、等级升级 | Burn lifecycle |
| Reveal/Reroll | Reveal、付费 recommit、再次 reveal | Burn lifecycle |
| 挖矿升级 | 激活、升级、转移失活、重新激活 | Burn lifecycle |
| Stake 模板 | Mint、stake、AMM 托管、换手、unstake | Stake lifecycle |
| Index 奖励 | 注入、按权重结算、领取 | 两个 lifecycle 用例 |
| Community 奖励 | Calculator 注入、Community 结算、用户领取 | Burn lifecycle |
| NFT AMM | FIFO 卖入、买回、所有权和库存变化 | 两个 lifecycle 用例 |
| Index holder fee | permissionless harvest、进入 AMM reserve | Burn lifecycle |
| AMM 买 Index | native reserve → settlement → Basket → Index 奖励 | Burn lifecycle |

该生命周期使用真实 Pump、Token、Community、Calculator、Uniswap V4
PoolManager、TagAISwapHook、NutboxRouter、IndexBroker Factory/Pool/AMM。尚未部署的
RH Basket V3 及其 Index V3 结算腿使用确定性 mock；主网部署后必须由 fork 用真实
BasketRegistry、BasketHook、BasketSwapRouter 和 Index Token 替换。

## 池与路由矩阵

| Venue | 直接 USDG | WETH/native bridge | ERC20 bridge | 买 | 卖 | Rebalance |
| --- | --- | --- | --- | --- | --- | --- |
| V2 | 已测 | 不适用 | 已测 | 已测 | 已测 | 已测 |
| V3 | 已测 | 已测 | 路由级覆盖 | 已测 | 已测 | 已测 |
| Uniswap V4 | 已测 | 已测 | 已测 | 已测 | 已测 | 已测 |
| WETH reserve | 不适用 | 直接 reserve | 不适用 | 已测 | 已测 | 已测 |

路由配置另有 RH 官方 10 个池、19 条 route 的精确编码测试，并验证每个官方资产均有
direct USDG 与 two-hop WETH 路径。V2/V3/V4 混合多跳、native 输入输出、反向路径、
最多五跳、PoolManager allowlist、V4 callback 与已 unlock 的嵌套调用均有独立测试。

## 当前确定性结果

- TagAI：426 passed，0 failed，0 skipped。
- Basket：111 passed，0 failed，0 skipped。
- Basket invariants：accounting、fee auction、rebalance 各 128,000 calls/run。
- 新增 release lifecycle：2 passed，0 failed。

原有 skip 已清零：listed Token 的 receive 路径会完成真实上盘后断言
`TokenListed`；Hook `registerPool` 使用恶意 Token runtime 验证重入被拒绝；RH 不可能出现的
“官方 Token 非 native quote”旧 BSC 场景已移除，并由两组 RH 正向用例固定验证
`currency0 = native`。

## 本地门禁命令

```bash
cd /Users/wangxi/work/tiptag/TagAI-contract-V2
FOUNDRY_ETH_RPC_URL= forge test --no-match-path 'test/fork/*' --no-match-contract RHForkListingTest -vv

cd /Users/wangxi/work/tiptag/robinhood-basket-contract
FOUNDRY_ETH_RPC_URL= forge test --no-match-path 'test/fork/*' -vv
```

主网 fork 不得使用空地址、mock bridge 或过期候选池。fork 必须从
`deployments/4663/version11.json` 读取已部署地址，检查 bytecode、owner、version、
Registry/Hook/Router/settlementToken/PoolManager 的交叉关系后，再执行资产与路由矩阵。
