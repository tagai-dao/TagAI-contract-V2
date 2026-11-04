# BSC V19 多签激活

部署完成，V18 保留。V19 尚未激活。链 ID 56。

Pump19：`0x94c5293001C57727291fd4865107F0B34eED471F`

Token19 模板：`0x63386f6BFa34a3341509312023dDF5dcEFA14fFB`

Hook：`0x28D5dA2FD4d0AAAdb72F48540CE2Ff2426950cc1`

BuybackRouter：`0x93220081F6c98AfFC673CB2584C2e123d88a8E87`

管理多签：`0x871fb7006C5964B21695Ba20006021777A26146C`；当前 owner 是部署账户，pendingOwner 为该多签；调用 acceptOwnership 后完成交接。

## 待执行操作

1. `addOperator(address)`，参数 `[   "0x94c5293001C57727291fd4865107F0B34eED471F" ]`。目标：`0x72dc4F38A7E4159e97d826a6ab594748C6b68f17`；执行账户：`0x871fb7006C5964B21695Ba20006021777A26146C`。允许 V19 创建社区时调用 NutboxRouter。

2. `setCreatorForwarderApproval(address,bool)`，参数 `[   "0x94c5293001C57727291fd4865107F0B34eED471F",   true ]`。目标：`0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe`；执行账户：`0x871fb7006C5964B21695Ba20006021777A26146C`。允许 V19 为创建者登记 Basket。

3. `acceptOwnership()`，参数 `[]`。目标：`0x94c5293001C57727291fd4865107F0B34eED471F`；执行账户：`0x871fb7006C5964B21695Ba20006021777A26146C`。接收 V19 Pump 管理权。

4. `setPump(address,bool)`，参数 `[   "0x94c5293001C57727291fd4865107F0B34eED471F",   true ]`。目标：`0xB70544BfdACaBD8718261d7A6be5208b7D2f6Ebf`；执行账户：`0x871fb7006C5964B21695Ba20006021777A26146C`。上市后交易路由准入，保留 V18。

5. `setHookPolicy(address,bool,uint16,uint16,uint16)`，参数 `[   "0x28D5dA2FD4d0AAAdb72F48540CE2Ff2426950cc1",   true,   30,   30,   30 ]`。目标：`0x226D3e94569c44578a892A5158F0a3Defe49B8ca`；执行账户：`0x871fb7006C5964B21695Ba20006021777A26146C`。上市后评论交易 Hook 准入，保留 V18。

Safe Transaction Builder 导入 `deployments/56/version19.safe.json`（仅包含执行账户为该 Safe 的 5 项操作）；SHA-256：`259b88844edebb90474237519438a3cd56d64b09cca2cde52b7d0f9ee64080f0`。其余 owner 操作单独列在 owner-actions.json。全部 value=0；未创建提案、未签名、未执行。

操作不得关闭 V18 的 operator、forwarder、pumpEnabled 或旧 Hook policy。Committee 既有白名单复用；仅缺失时补充。

## 执行后核验

使用固定区块 Multicall 确认 Pump19.owner 为 Safe、pendingOwner 为零，NutboxRouter.operators(Pump19) 与 BasketRegistry.approvedCreatorForwarders(Pump19) 为 true；交易路由 pumpEnabled(Pump19)=true，评论交易 Hook policy 为实际 Hook 代码哈希及费率 30/30/30。检查 V18 原权限仍为 true。

源码提交：`d5c9a80c42603375f5921fb8fcf0948269ad1d31`。部署实际消耗 13724888 gas / 0.0006862444 BNB。链上 runtime 和构造绑定已核对，源码浏览器上传验证另行记录。

应用接入、Graph 数据源与 keeper 白名单尚未发布；默认创建切换需完成权限激活、真实地址接入及发布验证，Binance 模式继续使用 V18。

## 导出操作 fork 验证

在 BSC 固定区块 131574974，使用实际部署地址和 owner-actions.json 的 5 项 calldata，`Pump19ActivationForkTest` 通过（1 通过、0 失败、0 跳过）。核验激活后 Safe ownership、operator、forwarder、交易 Pump 准入和 Hook policy；V18 原状态不变。仅本地 fork 以 owner 权限逐项执行，未模拟 Safe 签名验证、未提交提案或在主网执行。报告：`deployments/56/version19-activation-fork.json`。

Standard JSON 和构造参数：`deployments/56/version19-verification/`。已本地重编译匹配字节码，尚未上传 BscScan 验证。
