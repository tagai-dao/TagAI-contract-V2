# Pump V16 — Binance Agent 内盘与转账限制

V16 基于已部署的 V15-2 源码继续发布，但使用新的协议版本号和全新的不可升级合约地址。
已部署的 V15 / V15-2 合约保持链上 `VERSION=15`，不会被改写或伪装成 V16。

## 规则

- 创建完成后的每次内盘买入都要求指定 BSC HandleRegistry 的 `handleOf(msg.sender)` 非空。
- 只有 `Pump.createToken` 同一交易内的创建预买免除买方资格检查。
- 内盘期间，`transfer` 和 `transferFrom` 只允许 Token 合约作为转账一端；用户不能把 Token 转给其他用户、Router、Vault 或 DEX 池。
- Pump 在创建交易内把原子预买转给创建者是唯一系统例外。
- 内盘卖出不要求 handle；上市后恢复普通 ERC20 转账，并继续使用既有成分池税规则。

## 版本与部署

- `Pump.VERSION()` 返回 `16`。
- V16 必须部署新的 Pump 和 Token implementation；同时部署绑定新 Pump 的 Hook 与 BuybackRouter。
- 部署入口为 `script/DeployBSCPump16.s.sol:DeployBSCPump16Script`。
- V15-2 部署地址和交易继续保存在 `deployments/56/version15-2.json`，不得覆盖。

## BSC 主网部署

- 部署源码提交：`cb694b648482c33d4ea0f983fb6b37a7af6bbe71`。
- Pump：[`0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8`](https://bscscan.com/address/0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8)。
- Token implementation：[`0x2eD2ac896392f2C1a4585da277c2095E2C975583`](https://bscscan.com/address/0x2eD2ac896392f2C1a4585da277c2095E2C975583)。
- TagAISwapHook：[`0x2a540ee894689d1820e95Feb26a8529a7AbA0CC1`](https://bscscan.com/address/0x2a540ee894689d1820e95Feb26a8529a7AbA0CC1)。
- TagAIBuybackRouter：[`0x2f71b84808d1F6cA4A6179C2A32615C2f408817d`](https://bscscan.com/address/0x2f71b84808d1F6cA4A6179C2A32615C2f408817d)。
- 7 笔部署交易位于区块 `128964678`–`128964701`，总计 `13,839,158 gas`，费用 `0.013839158 BNB`；四个新合约均已通过 BscScan 源码验证。
- 区块 `128964948` 独立核验 `VERSION=16`、合约绑定和 Token runtime；链上 runtime 与本地 artifact 均为 `24,570 bytes`，Keccak-256 为 `0x1c639f822c0b7ef14f195ec521782453777d4d5fb803d013a05b9996ec57570d`。
- 当前状态为已部署验证、待多签激活。Safe `0x871fb7006C5964B21695Ba20006021777A26146C` 仍需添加 NutboxRouter operator、批准 BasketRegistry creator forwarder，并接收 Pump 所有权；调用清单见 `deployments/56/version16-owner-actions.json`。

## 测试

V16 继续覆盖 Binance Agent 买入资格、创建预买、直接 BNB 买入、反狙击和填满曲线，并验证：

- 内盘 `transfer` 无法向外部地址转账；
- 内盘 `transferFrom` 无法绕过且失败时不消耗 allowance；
- 买入和卖出仍可与 Token 合约正常交互；
- 上市后恢复普通转账；
- Token runtime 不超过 EIP-170 上限。
