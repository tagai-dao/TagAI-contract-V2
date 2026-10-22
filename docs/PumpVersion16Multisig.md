# Pump V16 多签激活交易

本文件用于 Safe `0x871fb7006C5964B21695Ba20006021777A26146C` 在 BNB Smart Chain（chain ID `56`）激活已部署并通过源码验证的 Pump V16。

可直接导入 Safe Transaction Builder 的批量文件：[`version16.safe.json`](../deployments/56/version16.safe.json)。人工核对用原始操作清单：[`version16-owner-actions.json`](../deployments/56/version16-owner-actions.json)。不要导入 V15 或 V15-2 的历史多签文件。

## 执行前核对

- Pump V16：[`0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8`](https://bscscan.com/address/0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8)。
- Pump 链上 `VERSION()` 应为 `16`。
- 当前 Pump `owner()` 为部署账户 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`。
- 当前 Pump `pendingOwner()` 为本 Safe `0x871fb7006C5964B21695Ba20006021777A26146C`。
- NutboxRouter 的新 Pump operator 状态应为 `false`。
- BasketRegistry 的新 Pump creator forwarder 状态应为 `false`。
- 批量文件必须显示 3 笔调用，三笔 `value` 均为 `0`，不会转出 BNB 或 Token。

以上状态已在区块 `128964948` 核验。若执行前状态不同，应暂停并重新核验，不要盲目提交。

## 批量交易

按以下顺序执行：

| 顺序 | 目标合约 | 函数与参数 | Calldata |
| --- | --- | --- | --- |
| 1 | NutboxRouter `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` | `addOperator(0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8)` | `0x9870d7fe000000000000000000000000ee8d16f44c89b5f858e223ab77c6091e184aadf8` |
| 2 | BasketRegistry `0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe` | `setCreatorForwarderApproval(0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8, true)` | `0x30897036000000000000000000000000ee8d16f44c89b5f858e223ab77c6091e184aadf80000000000000000000000000000000000000000000000000000000000000001` |
| 3 | Pump V16 `0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8` | `acceptOwnership()` | `0x79ba5097` |

## Safe 操作步骤

1. 在 Safe 中选择 BNB Smart Chain 和 Safe `0x871fb7006C5964B21695Ba20006021777A26146C`。
2. 打开 Transaction Builder，上传 `deployments/56/version16.safe.json`。
3. 逐笔核对目标地址、calldata 和 `value=0`，确认总共只有上述 3 笔调用。
4. 使用 Safe 的模拟功能确认整个批次成功，再创建批量交易并完成所需签名。
5. 达到签名阈值后执行交易；仅签名或创建提案不等于已经上链执行。

## 执行后核验

执行成功后应满足：

- `NutboxRouter.operators(PumpV16) == true`；
- `BasketRegistry.approvedCreatorForwarders(PumpV16) == true`；
- `PumpV16.owner() == 0x871fb7006C5964B21695Ba20006021777A26146C`；
- `PumpV16.pendingOwner() == 0x0000000000000000000000000000000000000000`。

请保留 Safe 执行交易哈希。链上执行完成后，再将交易哈希和核验区块补入 V16 部署记录并把状态更新为已激活。
