# ImportHelper V3 — 双 Wrapper 登记与 Agent 配置委托

状态：2026-11-02 已部署至 BSC 并完成 BscScan 精确源码验证，**待多签激活**。地址：`0xDcCc7428338Db3a7480bEcAa9dAc2965425E0EDF`。owner 已直接设为现有 Safe，管理钱包保持原钱包。本次未修改两个 Wrapper 权限或应用地址。外部 ERC20 导入业务仍为 V10；Helper 自身版本为 3。[部署与激活记录](ImportHelperV3Deployment.md)。

## 导入行为

继承 V2 的社区创建、固定 HourlyTickCalculator、开发者收益归属、owner 两步移交、默认 TradeCuration 100% 和可选 1–6 个奖励池。保留 `createCommunityAndPool(token, existingCommunity)` 与 `createCommunityAndPools(token, configs)` ABI 及原事件；`existingCommunity` 仍必须为零。`swapWrapper()` 继续返回普通 Wrapper，新增 `agentSwapWrapper()` 返回 Agent Wrapper。

创建社区前检查两个 Wrapper，任一已经登记该 token 则拒绝重复导入。创建一个社区并设置奖励池后，按普通 Wrapper、Agent Wrapper 的顺序登记**同一个** `(token, community, creator)`。登记、所有权转移和退还多余 BNB 在一笔交易完成；任一步失败全部回滚。不会自动为导入者创建 IPShare，也不要求导入者持有 Binance Handle；交易资格仍由 Agent Wrapper 在交易时核验。

V3 只调用 Agent 的 `registerImportedToken`，因此新登记的 Agent 代币 Nutbox 费率仍为 **0**。普通 Wrapper 原有全局费率不变；两者的收费政策、待注入奖励及历史余额继续独立。V3 不提供任意目标调用、交易代理或资金转出入口。

## 构造参数与权限

```solidity
new ImportHelperV3(
    communityFactory,
    tradeCurationFactory,
    committee,
    hourlyTickCalculator,
    ordinaryWrapper,
    agentWrapper,
    managementWallet
);
```

两个 Wrapper 地址固定、必须不同且有代码，初始 owner 必须相同。Helper 初始 owner 取普通 Wrapper 的 owner，并不自动使用 pendingOwner。管理钱包初始为非零地址；计划使用现有钱包 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`。合约不硬编码该钱包，部署参数决定初始授权。

未来激活需要由对应 owner 分别执行以下操作；本文仅记录要求，本次未执行：

```solidity
ordinaryWrapper.setRegistrar(address(helperV3));
agentWrapper.setOperator(address(helperV3));
```

Agent Wrapper 只有一个 operator，第二步会将旧钱包的直接 operator 权限替换为 Helper。原钱包随后调用 **Helper 地址**上的以下接口，Helper 再调用固定 Agent Wrapper：

| Helper 接口 | 作用 |
| --- | --- |
| `registerImportedToken(token, community, deployer)` | 仅向 Agent 登记绑定，不开启收费 |
| `updateImportedMarket(token, community, deployer)` | 修正 Agent 绑定，保留底层待注入费用保护 |
| `setNutboxMarket(token, community, deployer, feeBps)` | 配置 Agent 绑定及代币费率 |
| `setTokenNutboxFee(token, feeBps)` | 只调整 Agent 费率，0 停收 |
| `syncAgentMarket(token)` | 将普通 Wrapper 的历史绑定同步给 Agent |

这些入口仅限 Helper owner 或 `managementOperator()`，共用导入入口的重入锁。普通导入者没有管理权限。社区与代币匹配、费用上限、社区变更前待注入费用必须清空等检查仍由真实 Agent Wrapper 执行，不能被 Helper 绕过。人工修改接口**仅影响 Agent 绑定**，不代替普通 Wrapper owner 的修正操作。

只有 Helper owner 可调用 `setManagementOperator(wallet)` 更换管理钱包；传零可撤销，禁止设置为 Helper 自己。管理钱包不能修改 Helper owner、奖励池配置或 Wrapper owner、operator、平台费、推荐费、收款地址、IPShare 及暂停状态。Helper 转移所有权后原管理钱包继续授权，新 owner 可撤销；Agent Wrapper owner 同样保留直接管理和更换 operator 的能力。

若任一 Wrapper 未完成授权或之后撤销授权，公共导入会明确回滚，不会仅登记其中一个 Wrapper。切换普通 Wrapper registrar 后旧 V2 的创建入口将无法完成登记；应用切换需与未来激活安排协调。

## 历史数据

`syncAgentMarket(token)` 只读取普通 Wrapper 中的现有绑定并登记到 Agent，不创建社区、不收创建费，也不改变普通 Wrapper。

- 普通 Wrapper 未登记时拒绝。
- Agent 未登记时创建同一绑定，费率保持默认 0。
- Agent 已有完全相同的社区和创建者时直接返回，保留费率、待注入奖励和注入时间。
- 社区或创建者任一不一致时拒绝，需管理者显式核验并修正，不静默覆盖。

不要重新调用导入入口迁移历史社区。需要收费时管理钱包再调用 `setTokenNutboxFee`；仅同步不代表启用收费。

## 源码与验证范围

V2 源码只增加可覆盖的查重/登记扩展点，并将 `VERSION()` 常量 getter 改为可覆盖纯函数，保持 selector 和返回类型：V2 返回 2、V3 返回 3。既有 V2 外部导入行为及接口保留；链上已部署 V2 不随本次源码变化。

本地单元测试使用真实 CommunityFactory、Community、HourlyTickCalculator、奖励池工厂、普通 Wrapper、Agent Wrapper 和 IPShare，DEX/Handle Registry 使用确定性测试替身。单元回归无 RPC 或部署广播；另已完成真实主网依赖及已部署 V3 的固定区块 fork 验证，仅在本地 impersonate Safe。本次不更新前端/API 地址。

```sh
FOUNDRY_ETH_RPC_URL='' BSC_RPC_URL='' forge test --offline \
  --match-contract '^(ImportHelperV3Test|ImportHelperV2Test|ImportHelperTest|AgentSwapWrapperTest|ImportedTokenSwapWrapperTest|AgentSwapWrapperTagAITest)$'
```

2026-11-02 本地结果：相关 6 个套件 **151 通过、0 失败**，其中 V3 14 项（含 256 轮随机退款测试）。全量离线非 fork 回归使用 `--no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest`：49 个套件 **930 通过、0 失败、2 个既有跳过**。覆盖真实双 Wrapper 绑定、单/多奖励池、权限未激活的原子回滚及社区/费用回滚、管理钱包更换/撤销、两步 owner 移交、历史同步和冲突、费率上限、待注入费用保护、退款失败，以及退款回调对 7 个导入/管理入口的重入阻断。

Solidity 0.8.26、viaIR、optimizer runs 100：V3 runtime **10,603 bytes**，低于 EIP-170 的 24,576 bytes 限制。部署前区块 `131202172` 及部署后区块 `131202536` 的真实合约 fork 各 2 项通过；外部 Multicall 17 项通过。测试不代表多签已在主网授权，当前仍待激活。
