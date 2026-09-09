# TagAILiquidityRouter BSC fork 测试报告

执行日期：2026-09-08。固定 BSC 区块：**120508054**。
本轮只运行本地测试，没有广播主网交易，没有花费真实 BNB。

## 结果

| 套件 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: |
| TagAILiquidityRouterForkTest（本轮新增） | 10 | 0 | 0 |
| TagAITradeRouterForkTest（本轮回归） | 7 | 0 | 0 |
| TagAILiquidityRouterTest | 13 | 0 | 0 |
| TagAITradeRouterTest | 26 | 0 | 0 |
| TagAIBuybackRouterTest（既有依赖回归） | 13 | 0 | 0 |
| 合计 | 69 | 0 | 0 |

两个新路由自身为 39 项单测 + 17 项 fork 测试；其余 13 项是既有回购路由。
三个单元 fuzz 用例各执行 4096 次，不把随机输入次数重复计为测试项。
本轮新增测试和文档，无需修改生产合约或 ABI。

## 新增用例

源码：[TagAILiquidityRouter.t.sol](TagAILiquidityRouter.t.sol)。

| 用例（均以 test_liquidity_ 开头） | 验证内容 |
| --- | --- |
| stockSurplusRefundAndStakeRemove | 主池买 T、Router 买 QQQB、添加 LP、剩余 QQQB 卖回 BNB；用户独立质押、解押、移除 |
| tokenSurplusRefundWithCustomIPShare | 剩余 T 从主池卖回 BNB；买卖两次 Hook 收费均进入指定 IPShare 主体 |
| sixDecimalGold | XAUt 六位精度资产完整加池、退款、质押和移除 |
| fourStockComponents | QQQB、SPCXB、AAPLB、SKHYB 四个成分池逐一执行；分别覆盖 T/资产剩余 |
| minLpRollsBackEntireZap | LP 下限高于模型预估 1 wei，整笔回滚 |
| assetRefundSlippageRollsBackEntireZap | 股票资产退款下限无法满足，买入与 LP mint 一起回滚 |
| tokenRefundSlippageRollsBackEntireZap | T 退款下限无法满足，买入与 LP mint 一起回滚 |
| tokenBuySlippageRollsBackEntireZap | 主池 T 买入下限无法满足，整笔回滚 |
| assetBuySlippageRollsBackEntireZap | 股票资产买入下限无法满足，已发生的 T 买入一起回滚 |
| changedRouteRejected | 传入不匹配的资产路由 hash，拒绝执行 |

成功用例独立模拟两笔购买，从真实 V2 储备和 LP 总量计算配比、0.1% 转账税及预计 LP；
回退模拟状态后，通过流动性合约执行，断言实际 LP 与模型逐 wei 一致。
买入、LP、余量回售使用模拟结果的约 99% 作为保护下限；不以全程 1 wei 下限冒充报价验收。

同时核对：

- LP 直接进入用户钱包，主池使用次数与退款分支一致。
- NativeRefund 事件金额等于用户实际 BNB 退款。
- ComponentPoolTaxBurned 对应实际加池税；移除所得等于扣税后的净额。
- 主池 Hook 收费与 IPShare ValueCaptured 金额、主体一致。
- 辅助合约预存的 T、股票资产和 BNB 不被消费；授权在成功后清零。
- 矿池份额记在用户本人名下，不记在流动性合约名下。
- 失败用例断言具体 revert selector，并比对用户/路由/Hook/Vault 余额、池储备、LP 总量、税接收余额和授权。
- 失败后以有效报价重试成功，排除因测试环境本身不可交易而产生的假阳性。

## 复现

先在兄弟项目生成 Basket V4 产物：

```bash
cd "/Volumes/Extreme Pro/wangxi/work/tiptag/bsc-basket-contract"
forge build --skip test --skip script
```

使用 TagAI-contract-V2 项目 `.env` 中的 BSC_RPC_URL，需要支持历史状态的 RPC：

```bash
cd "/Volumes/Extreme Pro/wangxi/work/tiptag/TagAI-contract-V2"

PUMP13_FORK_BLOCK=120508054 FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test \
  --match-contract TagAILiquidityRouterForkTest --match-test test_liquidity_ -vv

PUMP13_FORK_BLOCK=120508054 FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test \
  --match-contract TagAITradeRouterForkTest --match-test test_tradeRouter_ -vv

FOUNDRY_ETH_RPC_URL='' forge test \
  --match-path 'test/unit/TagAI*Router.t.sol' --fuzz-runs 4096
```

fork 子类继承 Pump13 回归套件，因此使用对应 test 名称前缀只运行路由测试。
RPC 未配置而跳过、DNS 失败、或命令显示 No tests found 均不能记为通过。

## 环境和验证边界

复用 [Pump13Mainnet](Pump13Mainnet.md) 环境：真实历史 BSC 资产、Pancake V2/V3/Infinity、
IPShare、Committee、CommunityFactory 和质押 Factory；当前 Pump/Token/Hook/NutboxRouter、
Basket V4 及两个新路由在 fork 中部署。股票池价格、余额和 DEX 字节码没有 mock/etch。
测试使用 vm.deal 给测试用户分配 BNB，并只在 fork 中模拟必要的管理员白名单配置。

Nutbox 路径从历史注册表导入；GOOGLB、CRCLB 在该固定区块尚未注册，未宣称覆盖它们。
这里验证的是当前源码与真实 DEX/资产的配合，不是直接对计划部署时绑定的线上 Pump/Nutbox
地址逐项验收；部署前仍应执行部署文档中的 getter 检查和脚本模拟。

LP 模型在 Solidity 测试里独立计算，不能代替前端 Worker 报价、API 地址配置和钱包 UI 的联调。
固定历史区块的成功不保证任意未来池深度或金额都能成交；保护下限不足时应回滚。
下一步可进行交易路由部署前模拟，随后由用户依次部署和验证两个路由。
