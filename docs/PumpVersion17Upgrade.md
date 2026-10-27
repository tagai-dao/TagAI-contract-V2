# BSC V17 版本升级与 main 发布记录

## 发布边界（2026-10-27）

本次将 `bsc-version17` 合并到 `main`，保留独立版本提交历史。合并前 main 为
`955f10a`（V16 发布），合入版本分支末端为 `c6a2130`。
部署和 BscScan 验证使用的固定源码仍为
`f9eb071494000f3a0026dc81584a7d8ef9ef80bd`，不以 main 的合并提交替换部署来源。
本次未重新部署合约、重复执行 Safe 激活、修改旧 Token 实现或重置数据库游标。

V17 已于 2026-10-26 部署、完成四个合约源码验证并由原 Safe 激活。
2026-10-27 的只读核验与成功回执已归档；源码合并、链上激活、应用发布和子图生产切换分别记录。
原工作目录的 V16 未提交激活资料不属于本次合并，保持原样。

## V16 → V17 行为变化

| 项目 | V16 | V17 |
| --- | --- | --- |
| `Pump.VERSION()` | 16 | 17 |
| 内盘累计买入 | 无 V17 累计额度 | 每个 Token、每个买方地址累计最多 1000 万枚（18 位精度） |
| 卖出、转出、转入 | 原逻辑 | 不减少或增加累计买入计数，不恢复购买额度 |
| 创建预买 | 创建内 handle 豁免 | 保留 handle 豁免；按创建者累计，仍受 1000 万枚上限约束 |
| 普通内盘买入资格 | 买方 handle 非空 | 保持相同要求，覆盖 `buyToken` 与直接转入 BNB |
| 普通内盘转账 | 不允许用户之间互转 | 双方均无合约代码且 handle 非空时，允许 `transfer` / `transferFrom` |
| 上市后交易与奖励 | 原逻辑 | 保持既有上市、成分税、回购和奖励逻辑 |

达到 1000 万枚允许，超限整笔回滚；例如买满后转出 40 万枚，再买 10 枚仍失败。
转入不占购买额度，因此余额可以大于 1000 万枚。额度按地址及 Token 分开计算，不合并同一人的不同地址。
曲线最后一笔先按实际剩余可成交量核算额度，多余 BNB 沿用退款流程；不会为满足买方额度而做部分成交。
协议反狙击注入社区的 Token 不计入买方额度。

`transferFrom` 的代操作合约不替代持币双方资格；双方仍须满足代码长度与 handle 检查。
`listingPending` 时的钱包互转也须检查双方 handle，买卖沿用冻结规则。
带代码的智能合约钱包及 EIP-7702 委托账户不属于此处的普通钱包；代码长度无法识别尚未部署或构造中的合约地址。
买卖涉及 Token 自身、创建预买转发和社区注入的系统流程继续沿用必要例外。
Solidity 内部直接调用 HandleRegistry；外部 JS/RPC 的批量合约查询继续使用固定区块 Multicall。

## 部署地址和激活证据

| 合约 | BSC 主网地址 |
| --- | --- |
| Pump17 | `0x01B2308653c7e371B28A862444a40c12ca18b353` |
| Token17 implementation | `0x309E55BB49cE073227F8a2F67bE659dFeA3d691f` |
| TagAISwapHook17 | `0xfF107D782cb2699F617aD96a4ccA39F8D6800cc1` |
| TagAIBuybackRouter17 | `0xA906917D83D47526e4c8a212606dE63a778f4151` |
| 所有权 Safe | `0x871fb7006C5964B21695Ba20006021777A26146C` |

部署交易范围：区块 `129862551`–`129862580`；沿用 V16 基础设施、费率、keeper、16 个已批准成分及 TradeCuration 配置。
Token runtime 为 23,645 bytes，Pump runtime 为 21,023 bytes。编译设置保持 Solidity
`0.8.26+commit.8a97fa7a`、viaIR、optimizer runs 100、Cancun。
四个 Standard JSON、构造参数及 SHA-256 见 [验证清单](../deployments/56/version17-verification/manifest.json)。

Safe 激活交易：
[`0x39d266525b0910c14550448477ab4bf32c3bb1768466c3793670ae0dff8dcca0`](https://bscscan.com/tx/0x39d266525b0910c14550448477ab4bf32c3bb1768466c3793670ae0dff8dcca0)，
区块 `129865835`，北京时间 2026-10-26 16:30:12。
成功回执同时包含 `OperatorAdded`、`CreatorForwarderApprovalSet(true)`、`OwnershipTransferred` 及 Safe `ExecutionSuccess`。

区块 `130036492` 的同一快照 Multicall 确认：owner 为上述 Safe、pendingOwner 为零地址、
NutboxRouter operator 和 BasketRegistry creator forwarder 均为 true；版本、模板、Hook、Buyback 绑定及额度常量正确。
完整子调用、固定区块、回执和时间见 [激活确认](../deployments/56/version17-activation-confirmed.json)。
[原 Safe 文件](../deployments/56/version17.safe.json) 保留为执行归档，不要重复导入或执行。

## 应用创建策略与历史兼容

- 普通创建保持 V14；`binanceWalletOnly=true` 的 BSC 创建由 V16 切换至 V17；RH 保持原 V14。
- 新创建的配置、地址预测、salt、预买报价、广播与回执登记必须使用 Pump17 / Token17 ABI 及可信地址。
- 应用侧停止提供 V16 新建配置，`GET /pump/v16/creation/:creator` 返回 410 / `PUMP17_REQUIRED`。
  这不是对链上旧 Pump16 的停用交易。
- 历史 V16 Token、交易、回购和已经广播的创建补登记继续按原版本处理，不把旧回执改记为 V17。
- 合约不是代理升级：V17 使用全新 Pump、Token 模板、Hook 和 BuybackRouter；既有 V14/V15/V16 代币不迁移。

配套源码已在对应仓库推送，以下是本次改动的固定提交，不表示服务已经完成生产发布：

| 仓库 | 提交 | 内容 |
| --- | --- | --- |
| [tagai-ui](https://github.com/tagai-dao/tagai-ui/commit/5c3b890cf03055d7d7c830de1e0421ac69d5199d) | `5c3b890c` | V14/V17 创建分流、V17 ABI、累计额度报价及历史兼容 |
| [tiptag-api](https://github.com/tagai-dao/tiptag-api/commit/8482a956d663a4252c11b875cc03c61c49133469) | `8482a95` | V17 创建/登记/元数据、V16 创建退役、报价和分类 |
| [tiptag-server](https://github.com/tagai-dao/tiptag-server/commit/1aa2e2bc6370206892a3b22f21a73e04c77360eb) | `1aa2e2b` | V17 上市 keeper 和 Binance 账号/社区成员同步 |
| [tiptag-graph](https://github.com/tagai-dao/tiptag-graph/commit/142711d01550a5cb070e7643e6bc2ae21e23a820) | `142711d` | V17 Pump/Hook、Token 模板及转账/交易/上市/回购索引 |

## 子图及服务切换

Studio 版本为 `v17-20261026`，deployment 为
`Qmb6aQR7oLNqEiLcNCtNgnMj2eiCNe2SQJfjigd7PCius1`。
2026-10-27 13:53（北京时间）重新查询：Studio 仍停留在区块 `46620307`，
`hasIndexingErrors=false`，尚未追平；仅该字段为 false 不能视为同步完成，需要先排查进度停滞。
生产查询仍返回 V16 deployment `QmSxrijo8DexYcX1j2HPse8cFu5KbWZasUjrhbgn5HuNMt`，
高度 `130036746`。本次未用 owner 钱包发布 The Graph Network 生产版本。
观测记录见 [发布检查](../deployments/56/version17-release-checks.json)。

切换顺序：

1. 确认本节 V17 链上激活状态，发布支持 V17 的 API，再发布前端。
2. 排查 Studio 索引进度、完成生产版本发布，核验生产 `_meta.deployment` 指向 V17 且已追平，
   再对照新旧子图与现有游标，核对 V17 Token / Trade 数据。不得清空共享游标或把代码推送当作生产切换。
3. 更新 BSC `tiptag-server` 后重启原 `start-graph` 和 `start-listing-keeper` 进程。
   若显式设置 `LISTING_KEEPER_PUMPS`，需将 Pump17 加入覆盖列表；默认配置已包含 V14/V15/V16/V17。
   不要另启一个共用 keeper 钱包的并行上市进程。
4. 上市聚合交易、CommentBuyAdapter / Vault 的准入须单独核对。V17 这三笔 Safe 激活只覆盖
   NutboxRouter、BasketRegistry 和 Pump 所有权，不代表已完成所有外围 Router / Hook 准入。

无需新增数据库表或转移用户余额、授权及奖励。出现问题时暂停新的 V17 创建，保留已广播交易的补登记和
历史 Token 交易；回退应用版本不会改变已部署 V17 合约的额度及转账规则，也不应清除共享游标或重新部署相同版本。

## 验证与归档

本次源码与部署源码 `f9eb071` 的合约、部署配置保持一致；没有为合并修改 Solidity 行为。
Safe 原始文件及 Standard JSON 均校验 SHA-256，部署源码引用保持不变。
本次 44 个 Foundry 套件：788 通过、0 失败、2 个原有跳过；V17 专项及继承测试 62 通过，
外部 Multicall 的目标、子调用和固定区块回归 5 通过。跳过项为
`test_receive_revertsWhenListed` 与 `test_reentrancy_protectedDuringRegisterPool`。
最新发布检查及 Foundry / Multicall 回归结果记录在
[version17-release-checks.json](../deployments/56/version17-release-checks.json)。

```sh
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --offline \
  --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
node --test script/ops/version17-chain.test.cjs
```

主网部署全流程与激活 fork 的既有结果仍注明 2026-10-26 的固定区块；本次只读确认真实激活状态，
没有重新发送部署、管理或多签交易。
