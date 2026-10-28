# AgentSwapWrapper v1 — BSC 部署记录

日期：2026-10-28。独立组件版本 v1，不占用或替换 Pump/Token V18 的版本记录。

已部署、已验证；所有权转移已发起，**待多签执行 acceptOwnership**。尚未完成 owner 接管，不应把 pendingOwner 当成 owner。前端/API 地址未切换。

最新链上复核：区块 `130242089`，固定区块 Multicall 确认 owner / pendingOwner / operator 与下表一致，运行时代码与已验证版本匹配。证据见 [状态记录](../deployments/56/agent-swap-wrapper-v1-status.json)。

## 地址与源码

| 项目 | 地址 / 版本 |
| --- | --- |
| AgentSwapWrapper v1 | `0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577` |
| Chain ID | `56` |
| 当前 owner / 部署账户 | `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611` |
| operator（已配置） | `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611` |
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
- [BscScan 源码页](https://bscscan.com/address/0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577#code)：2026-10-28 15:25:19（北京时间）验证完成。Foundry Standard JSON 经 Etherscan V2 API 提交，随后独立 `getsourcecode` 确认名称、编译器、优化次数、EVM、构造参数及无 SimilarMatch。
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

多签执行后，通过以下命令刷新记录，确认 `owner() == Safe`、`pendingOwner() == address(0)`。operator 已按用户要求设置为 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，多签接管不会清空这一授权；后续 operator 可日常配置 Nutbox，Safe 仍可更换或撤销。

```bash
node script/ops/agent-wrapper.cjs status
```

## Operator 配置更新（2026-10-28）

- owner 尚为部署账户时，按用户明确指定调用 `setOperator(0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611)`。未取消或修改待多签接管状态。
- [设置交易](https://bscscan.com/tx/0x6c09d0771cc00f211f7cf6587d65a1384af53a93916d569ba220ea9df48137b8)，区块 `130241623`，gas `48121`，gas price `0.05 Gwei`。
- 区块 `130241625` 经固定区块 Multicall 回读，operator 已正确设置，pendingOwner 仍为目标多签。详情见 [operator 记录](../deployments/56/agent-swap-wrapper-v1-operator.json)。
- 部署、发起所有权转移和 operator 设置三笔合计 `0.00023006825 BNB`。

## 初始配置与测试

- 默认 BNB 平台费 / 推荐费各 `20 bps`，Nutbox 代币费默认关闭；未登记社区及费率。
- 部署初始 operator / registrar 均为零；随后 operator 已设置为 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，registrar 仍为零，未授权 referral Hook。若要向 TagAI 主池 Hook 传递显式推荐人，owner 需对核验过的 Hook 调用 `setReferralHook(hook, true)`。
- 普通 Wrapper、Pump/Token/Hook、ImportHelper、旧 pending 费用和 UI/API 配置均未修改。
- 本地单元与回归：113 通过；固定区块 `130240290` 的主网 fork：2 通过，真实 Registry/IPShare/DEX，无 mock/etch；管理员及 Safe 仅在 fork 中 impersonate。
- 外部 Multicall 测试：11 通过，验证目标、子调用集合、固定区块及缺失数据拒绝。

主记录：[agent-swap-wrapper-v1.json](../deployments/56/agent-swap-wrapper-v1.json)。部署前检查、交易 journal、链上状态、验证输入及接管模拟均单独保存，未覆盖旧版本记录。

## 运维与复现

从仓库根目录执行。需 Foundry / Solidity 0.8.26、Node.js 22、可解析的 ethers v6 和 dotenv。脚本读取本地 `.env`（已被 git 忽略）；只读核验需要 `BSC_RPC_URL`，部署或 owner 写操作使用 `PRIVATE_KEY_MAIN`，浏览器验证使用 `ETHERSCAN_API_KEY`。密钥不得写入文档、日志或提交。

```bash
# 只读核对链上状态，写回状态记录；多签接管后自动标记 accepted
node script/ops/agent-wrapper.cjs status

# 本地单元/回归，不自动连接 localhost fork
FOUNDRY_ETH_RPC_URL= forge test \
  --match-contract '^(AgentSwapWrapperTest|ImportedTokenSwapWrapperTest|AgentSwapWrapperTagAITest)$' -vv

# 核对外部批量合约读取的 Multicall 目标、子调用和区块
node --test script/ops/agent-wrapper.test.cjs script/ops/version18-chain.test.cjs

# 固定区块 fork；BSC_RPC_URL 需已注入当前进程
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL= AGENT_WRAPPER_FORK_BLOCK=130240290 \
  forge test --offline --match-contract AgentSwapWrapperDeploymentForkTest -vv
```

部署工具 `preflight` / `deploy` 会检查已有正式记录及 journal，避免误部署第二份；现有 v1 不应重跑。`handover` 在 pendingOwner 已存在时拒绝重复发起。`set-operator <address>` 仅在本地部署账户仍是 owner 时可广播；多签接管后，operator 的更换/撤销必须由多签调用 `setOperator`，日常社区绑定与费率调整则由已授权 operator 调用。

Nutbox 配置和集成方法见 [AgentSwapWrapper](AgentSwapWrapper.md)。此次归档不代表已切换应用路由或授权 TagAI referral Hooks。
