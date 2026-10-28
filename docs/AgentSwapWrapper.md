# AgentSwapWrapper（BSC，2026-10-28）

状态：源码与本地测试；未部署，未切换任何前端/API 地址，也未广播链上交易。

## 确定的行为

- 独立 Agent 入口，不替换已部署的普通 `ImportedTokenSwapWrapper`。
- 每笔 `buyToken` / `sellToken` 都读取 BSC Binance Handle Registry 的 `handleOf(msg.sender)`；空 Handle 拒绝交易。IPShare 已存在也不能跳过 Handle 检查，不使用 `tx.origin` 或可信转发豁免。
- 只为实际调用钱包 `msg.sender` 创建 IPShare。`recipient`、推荐人、平台地址及 Wrapper 都不会被顺带创建。普通钱包和 IPShare 兼容的 EIP-7702 钱包可用；尚无 IPShare 的普通合约钱包会被 IPShare 自身的 EOA 规则拒绝。现有评论 Adapter 不能冒充最终用户调用这个入口。
- 已创建则跳过；未创建时以零 value 调用 `createShare` 并验证创建结果。创建费非零明确拒绝，不从交易本金、卖出收入或旧余额支付。暂停、创建失败、DEX 失败、滑点失败均回滚整笔交易，包括刚创建的 IPShare。
- 默认平台费 `20 bps = 0.2%`、推荐费 `20 bps = 0.2%`，买入从 BNB 输入收取，卖出从兑换所得 BNB 收取。两者沿用原有 owner 配置及上限。
- **不收 Nutbox 代币费用**。构造时 `nutboxTokenRatio=0`；owner 也不能设置非零值；代币侧费用计算被固定为零，即使该代币已登记 Community，报价、成交及事件中的 Nutbox 费用仍为零，不累计社区注入余额。
- 推荐人已有 IPShare 时沿用 `valueCapture`，没有时沿用原 Wrapper 的直接 BNB 支付策略。调用者把自己作为推荐人时，由于其 IPShare 已自动创建，这笔推荐费将进入 IPShare；IPShare 自己的 subject/protocol 费用规则仍生效。
- 报价入口公开，不要求 Handle，也不会为报价用户创建 IPShare。买卖仍由完整的重入锁与暂停检查保护。

## 交易范围

买卖 ABI 与普通 Wrapper 一致，池信息仍由调用者明确提供，不要求先导入代币或绑定 Community：

| sourceType | 来源 | 限制 |
| --- | --- | --- |
| `0` | V2 Pair / Router02 | 按实际余额处理转账税；路由必须实现兼容接口 |
| `1` | Pancake/SwapRouter02 V3 | 买入支持带税输出；带税输入卖出仍拒绝 |
| `3` | Pancake Infinity CL | 包含 TagAI 代币上市主池；精确输入及完整 PoolKey |

原生 BNB / WBNB 报价直接交易；其他报价资产需要构造时指定的 NutboxRouter 已有可执行的 BNB 桥接路由。该 Router 在这里用于兑换路由，不代表收取 Nutbox 费用。

当前版本是选定单池交易加报价资产桥接，没有把 `TagAITradeRouter` 的多池拆单计划合并进来。未实现 Uniswap V4、非兼容 DEX、任意自定义 Hook calldata 或所有特殊 ERC20 行为。

### TagAI 上市 Hook

TagAI V14/V18 的主池是可指定的 Infinity CL 池。原有主池 Hook 仍收其协议费、保留回购及社区奖励机制；本 Wrapper 不会删除或重复代扣那部分费用。新 Wrapper 的平台/推荐 BNB 费用在它们之外，报价与 minimum 必须采用最终净到账。

为保留显式推荐归属，owner 使用 `setReferralHook(hook, true)` 登记兼容 Hook。配置记录地址及代码 hash；代码变化拒绝继续使用这项归属配置，需重新审阅。登记后交易传递 `abi.encode(sellsman)`，零地址由原 Hook 使用创建者回退；未登记的外部 Hook 收到空数据，保留原有兼容行为。归属上下文在交易结束清空，公开报价不会复用上次交易的推荐人。

可在部署后核验并登记的现有地址：

- V14 Hook：`0x2F0b231CAE7EdE4be0c52aA7eD5bAC62d1000Cc1`
- V18 Hook：`0x4dA421377b1dbf739f409919a07EAa7284BE0Cc1`

## 构造与集成

构造函数：`AgentSwapWrapper(nutboxRouter, feeAddress, ipshare)`。Binance Registry 固定为 `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`，部署时必须存在代码。其余构造依赖也会检查。

1. 单独部署及验证新合约，核验 IPShare 创建费、路由、默认费率、Handle Registry 和 owner；需要时完成 owner 两步交接及 Hook 归属配置。此文档不表示这些操作已经执行。
2. UI/API 使用独立的 Agent Wrapper 配置和交易模式，不覆盖普通 `importedTokenSwapWrapper` 配置。普通钱包交易入口保持原样。Agent 卖出需要授权新地址。
3. 报价优先使用实际调用钱包的完整买入/卖出模拟，包含自动创建、Wrapper 费用、DEX/Hook 费用及代币转账税。纯 quote 不能替代交易模拟或证明调用者有 Handle。
4. 继续发出兼容的 `Trade` 和 `ImportedTokenTrade` 事件；后者在这个合约里同样可表示 TagAI 上市币交易。API 回执校验需独立识别新目标，不能要求交易代币 `isImport=true`。Server 交易策展可信地址列表需追加新地址，并保留旧地址处理历史交易。
5. 本合约不需要新的 ImportHelper 或旧市场绑定迁移即可交易。如果希望注册 token 的创建者作为零推荐人的默认归属，可沿用登记能力，但登记不会开启 Nutbox 代币费用。旧 Wrapper 的 pending 注入余额仍留在旧合约处理。
6. 不需要更改或重新部署既有 Token/Pump/Hook；不会让外部 DEX 绕过此入口的交易自动创建 IPShare。

## 源码复用与验证

`ImportedTokenSwapWrapper` 仅增加默认空的交易前后扩展点、默认空的 Hook 数据扩展点，以及可覆盖的费用计算/配置方法。Agent 子类实现准入、创建和零 Nutbox 费；普通 Wrapper 的默认买卖、费用、回调及 ABI 保留。已部署合约字节码不会被这些源码修改改变。

运行本地测试时清空默认 localhost fork 配置：

```bash
FOUNDRY_ETH_RPC_URL= forge test \
  --match-contract '^(AgentSwapWrapperTest|ImportedTokenSwapWrapperTest|AgentSwapWrapperTagAITest)$' -vv
```

测试使用真实 IPShare 代码覆盖创建、初始 10 股自质押、暂停/收费失败与回滚、首次和后续调用、普通合约钱包/EIP-7702、推荐收益及重入。包含 V2 税币、V3、Infinity CL，及实际 TagAI Token/Hook/IPShare 的上市主池买卖集成（PoolManager 采用确定性测试定价）。这不是对线上流动性或真实 DEX 成交的主网 fork 验证；部署前仍需针对目标池做固定区块 fork 验证。

2026-10-28 本地验证：96 项测试通过（新 Agent 28 项、普通 Wrapper 回归 37 项、TagAI 上市集成及继承生命周期回归 31 项）；其中新 Agent 的两项 fuzz 各运行 256 轮。Agent 运行时代码 18,006 bytes，低于 EIP-170 的 24,576 bytes 限制。测试中的首次调用/同笔测试内暖状态重复调用执行 gas 分别约 548,942 / 167,012；这些值包含测试调用路径及冷暖差异，不是主网交易 gas 报价。
