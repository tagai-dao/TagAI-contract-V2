# BSC 主分支发布：Pump V19 与 Binance Handle NFT 模板

日期：2026-11-04（北京时间）。本次按用户明确选择，将当前 `bsc-version19` 全部已提交的 V19 内容与本次 NFT 工作一起合入 `main`。

## 合并范围与来源

- 合并前 main：`af06a05`（V18 / AgentSwapWrapper / ImportHelper V3 发布）。
- 合并来源：`bsc-version19` / `c50314ee19af0aa242628e8270128fbb095ffc16`；非快进合并保留 7 个来源提交。
- V19 原始分支基准：`6c59774`；保留此前 6 个 V19 业务、部署及归档提交。
- 新增 NFT Mint Handle 校验、Burn/Stake 单元及回调测试、部署/验证/固定区块证据、Safe 注册文件和运维入口。
- 版本对应的真实部署基准、源码摘要和 Standard JSON 沿用原记录，不改写旧部署来源。
- 其他工作尚未提交的 AtomicArbitrage 文件保留在工作区，不纳入本次提交。

## 合约与状态

| 组件 | 地址 | 已记录状态 |
| --- | --- | --- |
| Pump V19 | `0x94c5293001C57727291fd4865107F0B34eED471F` | 已部署，待源码浏览器验证及 Safe 激活 |
| Token19 模板 | `0x63386f6BFa34a3341509312023dDF5dcEFA14fFB` | 已部署，随 V19 记录保留 |
| V19 Hook | `0x28D5dA2FD4d0AAAdb72F48540CE2Ff2426950cc1` | 已部署，待 V19 权限操作 |
| V19 BuybackRouter | `0x93220081F6c98AfFC673CB2584C2e123d88a8E87` | 已部署，随 V19 记录保留 |
| Handle NFT Burn 模板 | `0x1cceCdED84c825e413F1849FdF55423D07Dc9ab6` | 已部署、BscScan 精确验证，待 Factory 注册 |
| Handle NFT Stake 模板 | `0x156C2A877069b0e50dC5A74C7d1612d70144B4C6` | 已部署、BscScan 精确验证，待 Factory 注册 |

V19 普通内盘买卖无需 Handle，公共内盘转账仅允许转入该 Token 自己的 Nutbox Community，保留累计买入上限及自动创建 IPShare。Binance 模式保留 V18。

NFT 两种模板则要求每次 `mint` 的实际调用者拥有非空 Binance Handle；白名单无豁免，校验在扣款和消耗额度前执行。已有 NFT 池保持旧实现；注册新模板也不会自动升级旧池。

V19 记录使用固定区块 `131574974` 的部署后证据；NFT 最新归档快照为区块 `131589995`，两个新模板 `supportedNFTTemplate` 均为 false。本次 Git 发布没有重新部署合约或执行链上权限操作，也不把历史 fork 模拟视为主网激活。

## 文档与后续操作

- [V19 业务及部署](PumpVersion19.md)、[V19 Safe 五项激活说明](PumpVersion19Multisig.md)、[V19 Safe 文件](../deployments/56/version19.safe.json)。V19 源码验证、owner 接收、Router/Registry 与交易准入、前后端/Graph/keeper 接入及发布均独立完成。
- [NFT 业务](../src/nutbox/dapps/index-broker-nft/README.md)、[NFT 部署及源码验证](IndexBrokerHandleTemplatesDeployment.md)、[NFT Safe 两项注册文件](../deployments/56/index-broker-handle-templates.safe.json)。Factory 为原 `0x835E047D4BE6548E95F2Cbb9Ac02d62EFa2508A0`，两笔注册分别模拟成功，待 2/3 Safe 签署执行；执行后使用固定区块 Multicall 回读确认。
- NFT 和 V19 的 Safe 文件属于不同操作包，不能把其中一份执行成功视为另一份也已完成。旧 V18 权限和旧 NFT 模板继续保留。
- [机器可读发布清单](../deployments/56/main-release-2026-11-04.json)记录本次来源和验证结果。应用仓库、数据库、Graph 和生产服务不在本次 Git 合并中发布。

## 合并验证

- 完整离线非 fork 合约回归：51 个套件，**991 通过、0 失败、2 个既有跳过**。排除另项工作尚未提交的 `AtomicArbitrageTest`。
- 运维脚本回归：**45 通过、0 失败**，覆盖 V19 部署 payload、权限配置、Multicall 目标、有序子调用、固定区块、必需数据失败及 NFT Factory/Safe 查询。
- V19 与 NFT 所有正式部署记录中的源码 SHA-256 逐项核对一致；真实部署来源与 Standard JSON 均保留。
- 发布文件检查未发现本地私钥、API Key、密码或 RPC 凭据。检查只记录结果，不输出凭据。
- [合约与运维测试日志](../deployments/56/main-release-2026-11-04-tests)及精确命令保存在发布清单。

使用已有部署时的 fork 证据，本次不重复发送链上交易。所有本次批量合约读取均沿用固定区块 Multicall，并保留目标、子调用和快照证据。
