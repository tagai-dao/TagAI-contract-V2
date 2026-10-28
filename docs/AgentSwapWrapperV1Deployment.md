# AgentSwapWrapper v1 — BSC 部署记录

日期：2026-10-28。独立组件版本 v1，不占用或替换 Pump/Token V18 的版本记录。

已部署、已验证；所有权转移已发起，**待多签执行 acceptOwnership**。尚未完成 owner 接管，不应把 pendingOwner 当成 owner。前端/API 地址未切换。

## 地址与源码

| 项目 | 地址 / 版本 |
| --- | --- |
| AgentSwapWrapper v1 | `0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577` |
| Chain ID | `56` |
| 当前 owner / 部署账户 | `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611` |
| pendingOwner / 目标 Safe | `0x871fb7006C5964B21695Ba20006021777A26146C` |
| NutboxRouter | `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` |
| FeeReceiver | `0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048` |
| IPShare | `0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922` |
| Binance Handle Registry | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| 源码提交 | `9c0a55bfe0547c35d2b093ca2e6a242c8e08910d`，分支 `bsc-version18` |
| 编译器 | `0.8.26+commit.8a97fa7a`，viaIR，optimizer 100，EVM Cancun，metadata IPFS |
| Runtime | `19,964 bytes`；含 immutable 的链上 hash：`0x0c33dba2c3ac7e065e8e264b50630f46b78a9fb82f21dff420093e381c0e309d` |

构造参数顺序：`(nutboxRouter, feeAddress, ipshare)`。具体编码见 [构造参数](../deployments/56/agent-swap-wrapper-v1-verification/AgentSwapWrapper.constructor-args.txt)。

使用当前 V18 共用的 NutboxRouter，而不是历史普通 Wrapper 的旧 Router。已在固定区块核验 V2/V3 工厂、Infinity CL Manager 和 WBNB/USDT 双向桥接路由。

## 已确认交易与验证

- 部署：[交易](https://bscscan.com/tx/0x0934cb17fec94c0dbb094094323f6c18a06924443710cc621a0dc8c068fd740c)，区块 `130240688`，gas `4,504,804`。
- 发起所有权转移：[交易](https://bscscan.com/tx/0xfaf910117cbcf96c280e94a2c253e96724639c4fe0704666f04302b07681cacd)，区块 `130240956`，gas `48,440`。
- 两笔实际 gas price 均为 `0.05 Gwei`，合计费用 `0.0002276622 BNB`。
- [BscScan 源码页](https://bscscan.com/address/0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577#code)：2026-10-28 07:25:19 UTC 验证完成。Foundry Standard JSON 经 Etherscan V2 API 提交，随后独立 `getsourcecode` 确认名称、编译器、优化次数、EVM、构造参数及无 SimilarMatch。
- [Standard JSON](../deployments/56/agent-swap-wrapper-v1-verification/AgentSwapWrapper.standard-json.json) SHA-256：`d71e70626352d92d443d5b76b112eeef6992c2376fc88e06d190aa0dfa036a06`。包含 49 个源码文件，逐文件 SHA-256 和结果来源记录在 [验证清单](../deployments/56/agent-swap-wrapper-v1-verification/manifest.json)。
- 区块 `130240966` 的 Multicall 核验显示 owner 仍为部署账户、pendingOwner 为目标 Safe；运行时代码排除 immutable 后与编译产物精确匹配，构造依赖分别核对。

## 多签接管

目标 Safe 当前为 **2/3** 签名。导入 [Safe Transaction Builder 文件](../deployments/56/agent-swap-wrapper-v1.safe.json)，仅包含一笔交易：

```text
Chain: 56
Safe: 0x871fb7006C5964B21695Ba20006021777A26146C
To:   0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577
Value: 0
Method: acceptOwnership()
Data: 0x79ba5097
```

执行文件已以 Safe 为 sender 在固定区块做单笔 `eth_call`，模拟成功，未广播 Safe 交易。证据见 [接管模拟](../deployments/56/agent-swap-wrapper-v1-safe-simulation.json)，文件摘要见 [SHA-256](../deployments/56/agent-swap-wrapper-v1.safe.json.sha256)。

多签执行后，通过以下命令刷新记录，确认 `owner() == Safe`、`pendingOwner() == address(0)`。若需由指定运营钱包日常配置 Nutbox，再由 Safe 调用一次 `setOperator(operatorWallet)`；当前 operator 为零地址，没有替用户选择运营钱包。

```bash
node script/ops/agent-wrapper.cjs status
```

## 初始配置与测试

- 默认 BNB 平台费 / 推荐费各 `20 bps`，Nutbox 代币费默认关闭；未登记社区及费率。
- operator / registrar 均为零，未授权 referral Hook。若要向 TagAI 主池 Hook 传递显式推荐人，owner 需对核验过的 Hook 调用 `setReferralHook(hook, true)`。
- 普通 Wrapper、Pump/Token/Hook、ImportHelper、旧 pending 费用和 UI/API 配置均未修改。
- 本地单元与回归：113 通过；固定区块 `130240290` 的主网 fork：2 通过，真实 Registry/IPShare/DEX，无 mock/etch；管理员及 Safe 仅在 fork 中 impersonate。
- 外部 Multicall 测试：11 通过，验证目标、子调用集合、固定区块及缺失数据拒绝。

主记录：[agent-swap-wrapper-v1.json](../deployments/56/agent-swap-wrapper-v1.json)。部署前检查、交易 journal、链上状态、验证输入及接管模拟均单独保存，未覆盖旧版本记录。
