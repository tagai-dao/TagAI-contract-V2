# Pump V17 多签激活

V17 已部署到 BSC 主网，四个新合约均已完成 BscScan 源码验证；当前待多签激活。见 [部署记录](../deployments/56/version17.json) 和 [源码验证清单](../deployments/56/version17-verification/manifest.json)。

Safe：`0x871fb7006C5964B21695Ba20006021777A26146C`（chain ID 56，2/3 多签）。
Pump：[0x01B2308653c7e371B28A862444a40c12ca18b353](https://bscscan.com/address/0x01B2308653c7e371B28A862444a40c12ca18b353#code)。

- 可导入文件：[version17.safe.json](../deployments/56/version17.safe.json)
- 人工核对：[version17-owner-actions.json](../deployments/56/version17-owner-actions.json)
- 固定区块核验：[version17-activation-preflight.json](../deployments/56/version17-activation-preflight.json)
- SHA-256：`0bbb6e33ecd7c9cf70ea3621767e7571f590ea1aac0b5775d78244e9cce867c3`；[校验文件](../deployments/56/version17.safe.json.sha256)

## 执行前状态

于区块 `129862871`，经链上 Multicall 核验：

- `Pump.VERSION() == 17`；当前 owner 为 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，pendingOwner 为上述 Safe。
- NutboxRouter 的 V17 operator 为 `false`，BasketRegistry 的 V17 creator forwarder 为 `false`。
- Router 与 Registry 的 owner 均为上述 Safe；所需 Committee 白名单已就绪，不需要新增白名单调用。
- Safe nonce 快照为 `43`。导入文件不锁定 nonce，不应覆盖其他排队交易。

## 3 笔激活调用

全部 `value=0`，不转出 BNB 或 Token；执行仍消耗网络 gas。

| 顺序 | 目标 | 函数 | Calldata |
| --- | --- | --- | --- |
| 1 | `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` | `addOperator(address)` | `0x9870d7fe00000000000000000000000001b2308653c7e371b28a862444a40c12ca18b353` |
| 2 | `0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe` | `setCreatorForwarderApproval(address,bool)` | `0x3089703600000000000000000000000001b2308653c7e371b28a862444a40c12ca18b3530000000000000000000000000000000000000000000000000000000000000001` |
| 3 | `0x01B2308653c7e371B28A862444a40c12ca18b353` | `acceptOwnership()` | `0x79ba5097` |

## Safe 操作

1. 选择 BNB Smart Chain 和上述 Safe，确认浏览器源码验证已完成。
2. 在 Transaction Builder 导入 `version17.safe.json`，核对正好 3 笔调用、目标、calldata 和 `value=0`。
3. 检查是否已有同一 V17 Pump 的待执行提案，避免重复创建；在 Safe 中模拟整个批次。
4. 由所需 Safe owner 完成签名后执行。创建提案或凑齐签名不等于链上已激活。

这三笔导出 calldata 已在区块 `129862871` 的实际主网合约 fork 中按顺序模拟通过，owner 变为 Safe、pendingOwner 清零、operator 与 creator forwarder 均变为 `true`。测试模拟的是 Safe 地址的目标调用权限和状态变化，不包含 Safe owner 签名验证。没有向主网提交激活交易，也没有创建提案或签名。

## 执行后核验

使用同一固定区块的外部 Multicall 核验：

- `Pump.owner() == 0x871fb7006C5964B21695Ba20006021777A26146C`；
- `Pump.pendingOwner() == address(0)`；
- `NutboxRouter.operators(0x01B2308653c7e371B28A862444a40c12ca18b353) == true`；
- `BasketRegistry.approvedCreatorForwarders(0x01B2308653c7e371B28A862444a40c12ca18b353) == true`。

保留 Safe 执行交易哈希，再将部署记录更新为已激活。V16 合约及其权限保持原状态。

最终交付前已于区块 `129864787` 再次通过固定区块 Multicall 确认仍待激活：owner 为部署账户、pendingOwner 为原 Safe，两个权限标记均为 `false`；Safe nonce 仍为 `43`。此检查不会固定或预留 Safe nonce。
