# RH V14 与 BSC V14 对照复核

日期：2026-09-30。RH 基线为 `bbbfabc`，BSC 参考为 `08a5faa5`（包含已发布 V14 与后续多 Pump Router）。此次仅补充测试和文档，没有修改生产合约、BSC 工作区或广播交易。

## 结论与对照范围

在此次核对范围内，未发现需要补迁的核心业务功能。第一轮迁移的主要不足是测试覆盖：当时 542 项本地通过包含大量旧版测试，不能把该数字等同于新版覆盖；V14 fork 当时只跑了两个 V3 股票、一个可选矿池的生命周期。

| 模块 | 对照结果 |
| --- | --- |
| Pump V14 | 四成分、最多两个可选池、可选池总比例 80%、工厂与 Committee 双重准入、累计舍入、按池收费、预买、社区所有权、keeper 上市和失败恢复均保留 |
| Token | 成分池税、上市原子性、基础设施快照、指数持币奖励与领取、LP 收费保留；曲线和 3 ETH / 1.2 亿＋余款 / 8000 万分配按 RH 已确认方案改动 |
| SwapHook | 0.9% 原生币收费、平台 / IPShare / 回购各 0.3%、周期注入及回购保留；Infinity Vault 回调改为 Uniswap V4 PoolManager 回调 |
| TradeCuration / Factory | 与 BSC 源码一致；签名、重放、收费、重入及长期账务测试在 RH 本地实现上运行 |
| BuybackRouter | 除接口导入路径外与 BSC 一致，保持单版本绑定 |
| Trade / Liquidity Router | 保留 BSC 交易、净到账、退款和 LP 行为；适配 Uniswap V4、30 bps V2 费率、按 Factory 配费、多 Pump 和可配置 Token 税率 |
| NutboxRouter | 保留 RH 已有 V2/V3/V4 路径；增加运行时执行器准入与受限 Pump operator；只读定价拆至 PriceReader |
| RH Basket | 按约定复用 RH Basket V3 业务实现，仅新部署实例绑定新 Router；不迁入 BSC Infinity Basket V4 |
| 复用基础设施 | IPShare、Committee、HourlyTickCalculator 的业务实现一致；Community / Factory 的相关差异主要是 RH 已有公开 getter，未发现阻断迁移的语义差异 |

## 本次补齐的测试

- 将 BSC 的 31 项 TradeRouter、13 项 LiquidityRouter 测试适配到 RH：单次回调认证、数据篡改、遗漏回调、重复回调、部分输入、双向成分池、五腿拆单、路由变化、滑点、伪造成交返回值、转账税、拒收退款、重入及预存余额隔离。
- 增加可配置税率的 LP 模糊测试，独立验证实际净入池数量、最小所需毛额和退款。
- 四成分＋两个可选池的随机权重，按每池独立上下界验证舍入，检查指数权重不受矿池奖励比例影响。
- 第六个池失败后检查手续费、余额、IPShare、Token / Community 部署、工厂记录和 tick 全部回滚；相同 salt 可重试。
- 真实 Community 奖励释放及两个 TradeCuration 池实际提取；可选池收费不足回滚、重复工厂、停用 / 撤销白名单、80% 总上限、不同矿池类型和社区 owner 放弃。
- Pump 更换 Manager、Hook、Factory、Basket 后，旧 Token 继续使用原快照，新旧 Token 均可上市交易。
- 真实 Uniswap V4 的 exact-input / exact-output 买卖四种组合，验证结算和费用；通过真实 donate / collect 验证 LP 收费及重复领取不重复支付。IPShare 内部另收协议费和 subject 费用，账务断言包含该原有行为。

## RH fork 结果

本轮完整本地回归：41 个套件，**597 通过、0 失败、2 个旧 fork 用例跳过**，相较首轮新增 55 项本地测试。5 项模糊测试分别运行 4096 轮；强化 TradeCuration 账务不变量执行 512 × 128 = 65,536 次状态调用，开启 `fail_on_revert=true`，0 次回滚，另通过 365 天长期释放测试。

固定区块 `76298453`，3 项测试通过：

1. NVDA / TSLA 完整上市、主池交易、回购、指数首次铸造、持有人领取和 Basket 卖出。
2. 全部九个默认股票（NVDA、SPCX、GME、TSLA、AMZN、MSFT、QQQ、SPY、AAPL）校验原生币 / USDG 路由，并实际完成 ETH 买入和卖回。
3. NVDA / TSLA / SPY / AAPL 混合 V3/V4 路由，四成分＋两可选池，64 字节名称、16 字节符号、非零社区 / 建池费、首次 IPShare 和 1 ETH 预买；上市后逐个币股池双向交易，并用真实 V2 Factory 加减流动性。

| 冷状态测量（包含 calldata intrinsic gas） | gas |
| --- | ---: |
| 六池创建，含上述极端参数 | 13,241,391 |
| 四股票上市 | 6,674,518 |

创建采用与 BSC 复核相同的项目测试预算 `16,777,216`，上市测试预算为 `10,000,000`；这不是对 RH 官方交易限制的声明，也不保证未来任意矿池实现或任意参数都满足预算。授权均为本地 fork 模拟。

旧区块 `76263063` 本轮被公共 RPC 报告部分历史状态不可用，因此改用新的固定区块；旧测试记录仍有效，但复现历史快照需要能读取该状态的 RPC。

## 复现和剩余边界

```bash
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*' --summary
FOUNDRY_ETH_RPC_URL='' FOUNDRY_FUZZ_RUNS=4096 forge test \
  --match-contract 'RHVersion14Test|TagAITradeRouterTest|TagAILiquidityRouterTest'
FOUNDRY_ETH_RPC_URL='' FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=128 \
  FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-contract TradeCurationAccountingInvariantTest
RUN_RH14_FORK=true RH14_FORK_BLOCK=76298453 FOUNDRY_ETH_RPC_URL='' \
  forge test --match-contract RHVersion14ForkTest -vv
```

正式上线前还需要针对实际 keeper、签名者、owner 与最终部署地址重跑部署模拟，完成并核验多签准入和 owner 接收，接通 keeper / 前后端 / 索引的 V14 ABI。新 Router 可配置接入的是保留兼容接口的新版本；旧 RH V11 Token 缺少 `getPump()` 和成分池接口，不能仅登记旧 Pump 就直接纳入该 Router。

本次测试不构成完整安全审计，也没有穷举所有九个股票的权重组合；以后新增矿池、Factory、Manager 或收费模型，仍须针对新实现做兼容与 gas 回归。
