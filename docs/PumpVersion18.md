# Pump V18 — 内盘交易自动创建 IPShare

2026-10-28：基于 V17 更新源码，`Pump.VERSION()` 返回 `18`。本次没有部署、广播或更改主网配置。现有 V17 Token 是固定模板克隆，不会因本次源码修改而改变行为。

## 交易行为

- 内盘 `buyToken`、直接转 BNB 买入、`sellToken` 在成交前查询交易者的 `ipshareCreated`。不存在时调用 `createShare(trader)`，已经存在则跳过创建。
- 普通交易使用 `msg.sender`，不使用 `tx.origin`。Pump 创建时的原子预买使用实际创建者 `indexCreator`，不为 Pump 或 Token 合约创建 IPShare；Pump 原有的创建者 IPShare 初始化流程保留。
- 自动创建发生在推荐人检查之前，因此用户首次交易可以将自己作为 sellsman。其他推荐人仍须已创建 IPShare。
- 创建和买卖在同一交易内完成。创建失败或后续 handle、额度、滑点、转账、费用结算失败，整笔交易回滚，不留下 IPShare 或费用变化。三个交易入口的重入保护继续生效。
- 买入 handle 校验、累计 1000 万枚上限、反狙击规则保持；卖出不新增 handle 要求。普通转账不触发 IPShare 创建。上市等待期和上市后先按原规则拒绝内盘买卖，不创建 IPShare。
- IPShare 自身只允许普通 EOA 和符合其检查的 EIP-7702 委托地址作为 subject。尚无 IPShare 的普通合约调用交易会因 `Subject must be EOA` 失败；不会跳过创建。普通合约的内盘转账限制仍保留。

## 当前创建费用

2026-10-28 11:54:33（北京时间），在 BSC 主网固定区块 **130212794**，经两阶段 Multicall3 查询：

| 项目 | 查询结果 |
| --- | --- |
| 查询配置的 Pump17 | `0x01B2308653c7e371B28A862444a40c12ca18b353` |
| Pump 当前 IPShare | `0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922` |
| `createFee()` | `0 wei` |
| `getPrice(10 ether, 0)` | `0 wei` |
| `paused()` | `false` |

**当前创建不收 BNB 创建手续费，初始 10 份 IPShare 自动质押到用户自己名下；交易仍消耗 Gas，内盘买卖本身仍按原规则收费。**

源码中 `createFee` 默认值也是 0；owner 可通过 `adminSetCreateFee` 设置，最高为 `0.01 ether`（在 BSC 为 0.01 BNB）。`createShare` 要求支付 `getPrice(minHoldShares, 0) + createFee`；当前前项为 0，不应仅凭注释认定永久免费。

V18 自动创建发送 **0 BNB**。若以后开启 IPShare 创建费，未创建 IPShare 的用户交易会透传 `InsufficientPay()` 并整笔回滚，不从买入金额、卖出收入或曲线储备扣除该费用。用户先自行支付创建费创建 IPShare 后可继续交易；已有 IPShare 的地址不会重复支付创建费。IPShare 暂停时也会透传失败。

完整查询目标、子调用 calldata、顺序、固定 blockTag 和区块哈希保存在 [主网费用查询记录](../deployments/56/version18-ipshare-fee-check.json)。所有阶段均使用 `0xcA11bde05977b3631167028862bE2a173976CA11` 的 `aggregate3`，校验快照及必需子调用，不回退为独立 RPC。

## 验证与发布边界

`test/unit/PumpVersion18.t.sol` 覆盖两个买入入口、卖出首次创建、已有 IPShare 跳过、实际 caller 与 origin 区分、创建预买归属、自推荐、填满曲线、反狙击、失败回滚、非零创建费不动用储备、暂停、合约 subject 限制和创建回调重入，并继承上市、成分池税、回购及奖励回归。V17 测试继续验证累计额度和转账规则；合约发送方转账测试改用预置余额，以独立检查转账限制。

```sh
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --offline \
  --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
node --test script/ops/version17-chain.test.cjs
forge build --offline --skip test --skip script --sizes
```

本次本地回归：45 个套件，**839 通过、0 失败、2 个原有跳过**；其中 V18 专项及继承回归 51 通过。Multicall 传输回归 5 通过，校验目标地址、完整子调用顺序、固定区块、必需数据和失败处理。Solidity 0.8.26、viaIR、optimizer runs 100 下，Token runtime 为 **24,205 bytes**，Pump 为 **21,023 bytes**，均符合 EIP-170 的 24,576 bytes 上限。本次未运行主网 fork 或部署测试。

V18 发布还需专用部署配置、全新 Token 模板及配套 Pump/Hook/Buyback 绑定、激活和应用版本接入。本次仅完成源码与本地验证；历史 V17 部署记录和脚本不作为 V18 发布记录，不应使用 V17 脚本直接广播当前 V18 源码。
