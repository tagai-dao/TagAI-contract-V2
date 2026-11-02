# ImportHelper V3 — BSC 部署与多签激活

2026-11-02（北京时间）：**已部署、已验证，operator/registrar 待多签执行**。应用仍使用 V2，本次未发布前端/API。

## 部署

| 项目 | 记录 |
| --- | --- |
| ImportHelper V3 | `0xDcCc7428338Db3a7480bEcAa9dAc2965425E0EDF` |
| Owner | Safe `0x871fb7006C5964B21695Ba20006021777A26146C`，构造时直接设置，无 pendingOwner |
| 管理钱包 | `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611` |
| 普通 Wrapper | `0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F` |
| Agent Wrapper | `0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577` |
| 原 Helper V2 | `0x40BACB12D79dadf045c21C999b74484816F746F7` |
| 部署源码提交 | `170d28e6662bb506442610bca991fb7ce61f004c`（功能提交 `452baa0`） |
| 部署区块 | `131202497` |
| Gas | `2,679,345`，`0.05 Gwei`，合计 `0.00013396725 BNB` |
| 编译器 | `0.8.26+commit.8a97fa7a`，viaIR，optimizer runs 100，Cancun |
| Runtime | `10,603 bytes`，链上不可变量逐项核对，排除不可变量后 runtime 与产物逐字节一致 |

[部署交易](https://bscscan.com/tx/0xc09fcd5c84ba2ac7ae67a16a134a06e114159df594cda77db2ebb7cec77e96c9) · [源码验证](https://bscscan.com/address/0xDcCc7428338Db3a7480bEcAa9dAc2965425E0EDF#code) · [完整记录](../deployments/56/import-helper-v3.json)。

北京时间 15:40:55 完成 BscScan 精确源码验证：Foundry Standard JSON / Etherscan V2 API，独立查询确认合约名、完整编译器版本、优化参数、EVM、全部 7 个构造地址及空 SimilarMatch。Standard JSON SHA-256：`50755a0efb38491225cc3c868d9633fecd0f784bd27a92c52b90e7f9d6e72cc3`，48 个源码文件及指纹见 [验证清单](../deployments/56/import-helper-v3-verification/manifest.json)。

## 多签执行

区块 `131202653` 固定区块 Multicall 确认两个 Wrapper owner 都是上述 Safe；Agent operator 仍为管理钱包，普通 Wrapper registrar 仍为 V2。部署账户不是 Safe 签名人，因此不能直接代多签调用 `setOperator`。部署成功不等于权限变更成功。

用户本次要求的 **仅设置 Agent operator** 文件：

- [import-helper-v3-operator.safe.json](../deployments/56/import-helper-v3-operator.safe.json)
- 调用 Agent Wrapper 的 `setOperator(0xDcCc7428338Db3a7480bEcAa9dAc2965425E0EDF)`，value `0`。
- [SHA-256 校验](../deployments/56/import-helper-v3-operator.safe.json.sha256)。

完整启用双登记需两项权限，另提供 [import-helper-v3.safe.json](../deployments/56/import-helper-v3.safe.json)：

1. Agent Wrapper：`setOperator(V3)`。
2. 普通 Wrapper：`setRegistrar(V3)`。

**只执行 operator 文件时双登记尚不能使用**，因为普通 Wrapper 仍只允许 V2 登记。执行完整文件前应协调前端/API 切换 Helper 地址；registrar 切换后旧 V2 新导入会回滚。两个文件有重叠操作，不应不核对当前状态就重复提交两份。

两笔原始 calldata 均以 Safe 为 sender 在同一固定区块 `eth_call` 模拟成功。另已在固定区块 fork 中按实际部署 V3 执行 Safe 授权、创建真实社区及双登记、管理钱包修改费率，2 项通过。该 fork 为本地模拟，没有主网签名或权限广播。Safe 完整批次模拟、签名阈值及待执行队列仍需在执行时核验；没有提交提案或代签。[预检和单笔模拟](../deployments/56/import-helper-v3-activation-preflight.json) · [最新状态](../deployments/56/import-helper-v3-status.json)。

## 本地验证与复核

- 相关回归：151 通过。
- 全量离线非 fork：930 通过、0 失败、2 个既有跳过。
- 外部批量合约 RPC：17 通过，验证 Multicall 目标、完整子调用及固定区块，无独立 RPC 降级。
- 部署前区块 `131202172` 和部署后区块 `131202536` 的真实合约 fork：各 2 项通过。
- [测试日志](../deployments/56/import-helper-v3-tests)。

链上权限执行后刷新：

```sh
node script/ops/import-helper-v3.cjs status
```

`ordinaryActivated`、`agentActivated` 均为 true 才代表双登记启用。初始登记 Agent Nutbox 费率仍是 0，钱包需要收费时通过 V3 的 `setTokenNutboxFee` 显式开启。历史导入通过受限 `syncAgentMarket(token)` 复用已有社区，本次未批量迁移。
