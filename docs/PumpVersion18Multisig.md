# Pump V18 多签激活（待执行）

V18 已于 2026-10-28 部署到 BSC 主网；四个合约已通过 BscScan 精确源码验证；多签尚未执行。

- Safe：`0x871fb7006C5964B21695Ba20006021777A26146C`，BSC chain ID 56，2/3 多签。
- Pump：[0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24](https://bscscan.com/address/0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24#code)。
- [Transaction Builder 导入文件](../deployments/56/version18.safe.json)；[人工核对操作](../deployments/56/version18-owner-actions.json)。
- Safe 文件 SHA-256：`bb14e1ce68ec3d88882128ce6c135eaf318145e30bcb1596dae8bc0ed63a1ceb`；[校验文件](../deployments/56/version18.safe.json.sha256)。
- [固定区块核验](../deployments/56/version18-activation-preflight.json)；[实际部署合约激活 fork 证据](../deployments/56/version18-activation-fork.json)。

最新固定区块 `130217901` 的 [状态复核](../deployments/56/version18-activation-status.json) 确认仍待激活；源码验证完成不代表多签已执行。

## 已确认的执行前状态

区块 `130215504`，通过 Multicall3 `aggregate3` 同一快照核验：

- `Pump.VERSION() == 18`；owner 为部署账户 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，pendingOwner 为上述 Safe。
- 新 Pump 的 NutboxRouter operator、BasketRegistry creator forwarder 均为 false。
- Router、Registry 的 owner 均为原 Safe；必要 Committee 白名单已经就绪，无需本次新增。
- Safe nonce 快照为 `44`。文件不锁定或预留 nonce，导入时应核对当前队列，避免重复提案。

## 三笔调用

所有调用 `value=0`。执行仍需网络 Gas。

| 顺序 | 目标 | 函数 | Calldata |
| --- | --- | --- | --- |
| 1 | `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` | `addOperator(address)` | `0x9870d7fe0000000000000000000000003b174db24a44d7172c1f4fb8ab387f3931681c24` |
| 2 | `0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe` | `setCreatorForwarderApproval(address,bool)` | `0x308970360000000000000000000000003b174db24a44d7172c1f4fb8ab387f3931681c240000000000000000000000000000000000000000000000000000000000000001` |
| 3 | `0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24` | `acceptOwnership()` | `0x79ba5097` |

## 操作和执行后核验

1. 确认浏览器源码验证完成，选择 BSC 和上述 Safe，核对当前是否已经存在同一 V18 Pump 的激活提案。
2. 在 Transaction Builder 导入 `version18.safe.json`，核对三笔调用、目标、calldata 和 `value=0`，模拟整个批次。
3. 由所需 Safe owner 签名后执行。当前没有创建 Safe 提案、提交签名或广播激活。
4. 保存成功执行交易哈希；使用固定区块 Multicall 核验 `Pump.owner()==Safe`、`pendingOwner()==address(0)`、`NutboxRouter.operators(Pump)==true`、`BasketRegistry.approvedCreatorForwarders(Pump)==true`，再更新版本记录为已激活。

这三笔原始 calldata 已在区块 `130215504` 的实际主网合约 fork 中顺序模拟通过，检查了权限、所有权接收和两项授权状态转换。该模拟没有验证 Safe owner 签名，也不代表主网已激活。旧 V17 合约及权限保持原状态。
