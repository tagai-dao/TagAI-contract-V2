# 多 Pump 交易 Router

`TagAITradeRouter` 通过 owner 管理的 Pump 注册表支持 V13、V14 和后续兼容版本。
`CommentBuyAdapter` 通过 owner 管理的 Hook 策略支持对应的上市 Hook。
买卖 ABI、事件、分腿路由、滑点、IPShare 归属和现有手续费保持不变。

## 配置边界

- Router：`setPump(pump, enabled)`，`pumpEnabled(pump)`、`supportedPumps(index)`、`supportedPumpCount()`、`supportsToken(token)`。
- 最多同时启用 32 个 Pump，删除后释放容量。查询创建归属的单个 Pump 调用限制 30,000 gas；异常 Pump 不阻塞其他 Pump。
- `supportsToken` 只表示已注册 Pump 创建了该代币，实际交易还检查上市状态、NutboxRouter、V2 Factory、PoolKey、组件 Pair 和回调来源。
- `pump()` 保留初始 Pump 地址以兼容旧 ABI；**不能再用它判断 Router 支持的全部代币**。
- Adapter：`setHookPolicy(hook, enabled, platformBps, subjectBps, buybackBps)`。
- Hook 按地址及运行时代码哈希校验，报价与实际买入均校验；相同字节码的另一个地址不会自动获准。
- 策略费率是对现有 Hook 收费的报价描述，不修改 Hook 实际收费。V13/V14 均为 30/30/30 bps。配置前必须核对实际 Hook 收费公式；总费率上限 1000 bps。
- 两个合约均使用 `Ownable2Step`。部署账户完成初始配置后，将管理权交给 TagAI 多签 owner；对方调用 `acceptOwnership()` 生效。
- owner 无法通过配置改变执行目标为任意调用或提走用户代币；撤销 Pump/Hook 会阻止对应交易，应避免误关仍在使用的版本。

未来版本须继续提供兼容的 Token 上市接口、相同 NutboxRouter/V2 Factory、现有主池和组件结构，且 Hook 使用兼容的输入收费与归属规则；此时只需注册 Pump 和 Hook。新的 DEX 类型、Token 接口或收费机制仍需要适配，不能仅凭版本号自动接受。
旧版本和外部代币继续由 Adapter 的 External 路径调用原 ImportedTokenSwapWrapper，内盘继续调用 Token，未调整费用或扩大旧版本范围。

## 部署及切换

2026-09-23 已完成 BSC 主网部署，6 笔交易全部成功，实际费用 0.00027505005 BNB：

- Router：`0xB70544BfdACaBD8718261d7A6be5208b7D2f6Ebf`
- Adapter：`0x226D3e94569c44578a892A5158F0a3Defe49B8ca`
- 复用 Vault：`0xAB2A0FF3BDbdD68E7100B6875Ac4a58db851d363`，尚未切换 Adapter。
- 已核对两个 Pump 均启用、两个 Hook 费率均为 30/30/30；新合约均等待目标多签接受管理权。
- 完整交易、角色和待执行动作记录在 `deployments/56/multi-pump-trading.json`。源码验证尚未提交，等待用户授权向 BscScan 公开源码。
- 用户已发起多签，等待签核；尚未核验链上执行完成。完整 8 项调用（含 Pump14 既有外部授权）已归档到 `deployments/56/multi-pump-trading-multisig-calls.json`。

旧 Router/Adapter 没有升级入口，需要新部署这两个合约。Pump14、Token 模板、Hook、回购 Router 和现有 Au-Pay Vault 不需要为本次改动重新部署。

专用脚本 `script/DeployBSCMultiPumpTrading.s.sol` 从现有 V11/V13/V14 部署记录读取依赖，核对两个 Pump 的基础设施和 Hook 归属，然后：

1. 部署新 Router，初始化 Pump13；注册 Pump14。
2. 部署新 Adapter，初始化 Hook13；注册 Hook14，费率仍为 30/30/30。
3. 将两份合约的管理权发起转交给 V14 记录中的 targetOwner。

默认多签配置下共 6 笔部署/配置交易，后续 owner 接受两份管理权并通过现有 Vault 的 `setAdapter(newAdapter)` 切换。脚本不会替换 Vault、迁移余额、修改授权或自动切换线上流量。

先运行无广播模拟，再按正式部署流程广播。将实际地址和交易记录另存为 `deployments/56/multi-pump-trading.json`，不要把模拟地址写入已部署版本记录。同步消费者使用的新 Router 地址/事件来源白名单；保留旧地址供历史交易核验。Au-Pay server 已优先使用 `supportsToken`，旧 Router 不具备该接口时回退单 Pump 查询；RPC 故障不能触发放行。

后续增加兼容 Pump：owner 调用 Router.setPump，再调用 Adapter.setHookPolicy；核验新版本内盘、外盘买卖、费用报价后开放流量。新增配置无需替换 Adapter 或 Vault。

## 验证命令

```sh
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test --match-contract 'CommentMarketsForkTest|MultiPumpTradingForkTest' --match-test 'testFork|test_multiPumpFork' -vv
```

分叉测试需只读 BSC_RPC_URL。覆盖真实 Pump13 外盘、V1～V6 路径代表代币、外部 V2/V3，以及当前 Pump14 源码搭配已部署 V13 Token 模板在真实 DEX 上创建、上市、配置新 Router 后经 Adapter 买入和 Router 卖出。所有测试均不广播主网交易。

2026-09-23 验证结果：本地合约测试 701 通过、2 个原有用例跳过；BSC 分叉测试 7 通过；server 评论买币测试 28 通过，相关 TypeScript 类型检查通过。三个部署脚本编译通过，ABI 与编译产物一致。Router/Adapter 运行时代码分别为 15,556 / 7,060 字节。
公共节点的历史状态查询曾失败，最终使用项目配置的支持历史状态的 RPC 完成分叉验证；未将 RPC 凭据写入文档。
