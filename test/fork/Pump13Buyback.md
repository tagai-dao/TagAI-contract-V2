# Pump13 正式回购路由与部署流程验证

本次使用生产合约 `src/router/TagAIBuybackRouter.sol`，已移除 fork 内的 `ForkIndexBuyback` 测试适配器。Hook、Pump、Token、NutboxRouter 和 Basket 的实际交易共同参与验证；无需修改现有 Pump/Token/Hook 的回购接口。

## 回购调用

任何人仍可调用 `Hook.executeBuyback(token, minIndexOut, deadline, data)`。生产适配器只接受该 Token 在创建时保存的 Hook 调用，验证 Pump 记录的指数归属，并要求接收者为该 Hook。它的 Pump、NutboxRouter、BasketSwapRouter 和结算币地址均在部署时固定。

`data` 必须编码为：

```solidity
abi.encode(uint256(minSettlementOut), bytes(basketTradeData))
```

其中 `minSettlementOut` 保护 BNB → 结算币，`minIndexOut` 保护最终收到的指数。二者必须非零；`basketTradeData` 原样转交 Basket，首次铸造需要各腿最低到账等参数。适配器按实际余额差核算，不依赖外部路由的返回值；只花本次换入的结算币，完成后清除授权。

调用数据格式与此前直接 `abi.encode(BasketTradeData)` 的测试适配器不同，keeper/调用端必须同步更新。非零最低到账本身不等于合理价格保护：公开调用者仍须提供有效报价，本次没有实现此前讨论的每秒采样、平均价格和重试调度策略。

## 结果

BSC 固定区块 **120508054**，本地 fork，无主网广播：

- **106 项**单元/安全回归全部通过，其中正式适配器新增 **13 项**，包含 256 次 fuzz；另有 5 项构造白名单专项测试。
- **32 项**基础 fork 回归通过，全部切换到正式适配器。
- **8 项**专项回购 fork 通过。
- **2 项**部署/bootstrap fork 通过：实际部署脚本完整流程，以及默认 16 资产的 Router 路由与构造白名单一致性。
- **11 项**独立交易 gas/聚合/浅池回滚测试通过。

全部无失败、无跳过。机器可读结果与源码 SHA-256 在 [Pump13ForkResults.json](Pump13ForkResults.json)。正式回购 gas：首次最高 **2,747,074**，后续最高 **2,807,876**；通过 16,600,000 执行 gas 预算。数值为测试工具估算，不是钱包最低 gasLimit。

## 专项覆盖

- 4 成分首次指数买入、后续回购、真实分红记账；任何地址触发，奖励不会转给触发者。
- 为他人领取、重复领取不重复支付，排除 V2 池、黑洞和 Hook 的奖励。
- 用快照中的真实执行结果报价，恢复状态后以 99% 最终最低到账执行并核对实际收到数量。
- 中间换币滑点失败、最终指数滑点失败：保留 Hook 储备、指数供应和奖励记账，平台费用及中间交换一起回滚，之后正确参数可重试。
- 过期、错误编码、缺少首次各腿参数、零最低到账失败；无路由时配置后重试。
- 两个不同的 4 成分代币各自累积费用和回购，储备和奖励互不混入。
- 非 Hook 直接调用、错误指数、替换接收者被拒绝；Pump 默认 Hook 修改后，旧 Token 仍使用已保存的 Hook。
- 内盘和 pending 阶段没有回购分红；刚上市但无手续费时拒绝空储备回购。
- 单元测试进一步验证回调重入、虚假路由返回值、实际到账不足、残余授权、部分消耗、外部捐赠和构造参数错误。

## 部署脚本演练

`Pump13Deployment.t.sol` 在 fork 中实际执行 `DeployBSCPump13Script.run()`，使用公开测试私钥 1 和 `vm.deal` 资金。验证 CREATE2 Hook 地址位图、Router operator、Basket creator forwarder、keeper、回购配置，再执行 4 成分创建 → 内盘结束 → 上市 → V4 购买 → 回购 → 领取分红。

脚本新增必填配置：

- `BASKET_SWAP_ROUTER_V4`：必须与 `BASKET_HOOK_V4`、`SETTLEMENT_TOKEN` 一致。
- `PUMP13_LISTING_KEEPER`：非零执行地址。
- 默认白名单直接复用 `BSCNutboxRouterConfig.constituentAssets()`，与 Router 的 16 项资产配置一致，包含新增 GOOGLB、CRCLB。Pump 构造函数一次性写入并发出事件，不再读取 `PUMP13_CONSTITUENTS`，也不再逐项发送设置交易。每个 Token 的上限仍是 4。

Pump 构造参数现为 `(ipshare, feeReceiver, address[] initialConstituents)`，验证源码时需包含这第三个参数。自定义部署可以传空数组；正式 Pump13 脚本自动传入默认列表。管理员仍可通过原接口修改后续创建的白名单。

演练中的 Router/Registry 所有权和 Committee 的工厂/Calculator 白名单已经在 fork 中准备好。真实部署仍需实际管理员落实对应权限，脚本没有权限时会打印 ACTION。此测试不代表已部署主网、已验证生产 RPC/私钥配置，或已完成线上 keeper 集成。

## 复现

先按 [基础 fork 说明](Pump13Mainnet.md) 编译 Basket V4；需要可访问指定区块的 `BSC_RPC_URL`。

```sh
FOUNDRY_ETH_RPC_URL= forge test --match-contract '^(PumpBootstrapTest|TagAIBuybackRouterTest|PumpVersion13Test|Version13SecurityTest|TagAISwapHookTest)$' -vv
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL= forge test --match-contract '^Pump13MainnetForkTest$' -vv
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL= forge test --match-contract '^Pump13(Buyback|Deployment)ForkTest$' --match-test 'test_(buyback|deployment)_' -vv
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL= forge test --isolate --match-contract '^Pump13GasStressForkTest$' --match-test test_gas_ -vv
```
