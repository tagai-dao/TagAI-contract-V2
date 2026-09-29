# Pump V14 六池版本部署核验

前期已完成代码调整、只读链上查询和本地模拟；随后按用户明确指令执行了主网部署，实际结果见下方。完整生命周期 fork 固定在 BSC 区块 **123329493**；精简部署脚本另外在最新主网状态完成不广播模拟。


## 实际主网部署（2026-09-22）

用户明确要求部署后，执行 `forge script ... --broadcast --slow --verify`。9 笔交易均成功，部署区块为 **123333750–123333787**，无待处理交易；5 个新合约（包括工厂内部部署的 TradeCuration 模板）均已通过 BscScan 源码验证。

| 合约 | 实际部署地址 |
|---|---|
| Pump V14 | `0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34` |
| TagAISwapHook | `0x2F0b231CAE7EdE4be0c52aA7eD5bAC62d1000Cc1` |
| TagAIBuybackRouter | `0x60381FCD630a4cF2002C44971d14a91bd4C78ab4` |
| TradeCurationFactory | `0x774A48Ba391a1013Ae43289eBdf871618822CD67` |
| TradeCuration 模板 | `0x2FfAa2659c760D958999262e3941163F46E9845B` |

实际 gas 合计 **10,772,291**，费用 **0.00053861455 BNB**。复用的 V13 Token 模板未重新部署。区块 **123333989** 的独立 RPC 核验确认 VERSION=14、keeper/signer/模板正确、Hook/BuybackRouter 均绑定新 Pump、交易矿池工厂已在 Pump 启用且上限 8000、最多两个可选池。

当前 Pump 和 TradeCurationFactory 的 owner 仍为部署钱包 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，pendingOwner 为多签 `0x871fb7006C5964B21695Ba20006021777A26146C`。Committee 白名单、Router operator、Registry creator forwarder 仍为 false。三个现有合约的 owner 已核实均为该多签。

真实地址、9 笔交易哈希、区块、费用及角色记录已保存到 `deployments/56/version14.json`；状态为 `deployed-pending-multisig-integrations`。完整链上核验摘要为 `previews/pump14-deployment-audit.json`。待多签执行的 5 个调用及 calldata 已准备到 `previews/pump14-multisig-calls.json`，**未提交、未执行**。源码工作区包含未提交改动，部署记录同时保存 Git HEAD 和关键源文件 SHA-256，不能只凭 HEAD 重建本次部署。

## 最终配置

- `MAX_COMPONENTS = 4`，`MAX_OPTIONAL_POOLS = 2`：创建时最多 4 个 LP 池加 2 个可选池；可选池合计不超过 80%。第三个已注册且参数合法的可选池也会被拒绝。
- Pump owner：`0x871fb7006C5964B21695Ba20006021777A26146C`，读取现有 V13 Pump 的 `owner()`；该区块 V13 没有待接受的 owner 转移。
- 上市 keeper：`0x8047FcC508446E2673195B8125d3388defc23688`，作为 Pump 状态变量初值写入；脚本核对它与 V13 的 keeper 一致。
- TradeCuration signer：`0x1c3864ea7a54ec4e3ceb27553a6f2927bbe4222e`，读取 SocialCurationFactory `0xc4674D3fBbD201Ea401a8B7e7285F956178593D8` 的 `claimSigner()`。这是部署时复制地址，以后两个工厂的 signer 轮换仍各自管理。
- Token 模板：`0xcC8f585593feAb2a27f9e699a6b578d46446c88C`，读取 V13 Pump 的 `tokenImplementation()` 并复用。
- 新部署 Pump、Hook、BuybackRouter、TradeCurationFactory；工厂构造时创建自己的 TradeCuration 模板。Token、Hook、BuybackRouter 的业务逻辑未修改，feeFree 规则未修改。

owner、signer、Token 模板仍从现有合约读取默认值，允许对应环境变量覆盖。PoolManager、Vault、Nutbox 四个基础设施地址、指数四个基础设施地址及 keeper 则已作为 Pump 状态变量初值写入；部署脚本不再调用相应 setter。基础设施环境变量及 `PUMP14_LISTING_KEEPER` 现在用于校验这些初值；值不一致会终止模拟，不会发出额外 setter 来覆盖。所有原有 owner 管理接口保留。

## 部署脚本模拟

使用实际 `.env` 中的基础设施与部署账户配置运行 `DeployBSCPump14Script`，不传 `--broadcast`。Foundry 返回 `SIMULATION COMPLETE`，**9 笔**部署和配置交易均完成模拟（此前是 15 笔）；模拟总 gas 估算 **14,341,994**，这是多笔交易的合计。

只含公开数据的摘要保存在 `previews/pump14-deployment-simulation.json`。其中地址是最新一次模拟对应 nonce 下的预测值，不是已部署地址；实际广播前应重新模拟。交易顺序已变化，不应对旧的 15 笔计划使用 `--resume`。没有将 Foundry 的敏感缓存内容复制到摘要。


精简后的交易顺序：

| 序号 | 操作 |
|---|---|
| 1 | 部署 Pump，初始化现有基础设施并复用 V13 Token 模板 |
| 2 | CREATE2 部署新 Hook |
| 3 | Pump 设置新 Hook |
| 4 | 部署新 BuybackRouter |
| 5 | Pump 设置新 BuybackRouter |
| 6 | 部署 TradeCurationFactory，构造时同时创建池模板 |
| 7 | Pump 注册交易矿池工厂 |
| 8 | TradeCurationFactory 发起 owner 转移 |
| 9 | Pump 发起 owner 转移 |

本轮重新运行 693 项本地测试和 7 项 BSC fork 测试，全部通过；新增构造后地址及 keeper owner 权限测试，fork 直接核对各初始配置与已部署 V13 一致，再跑六池创建、上市和回购。Pump runtime 为 21,062 bytes，initcode 为 46,745 bytes（不含构造参数）；实际部署交易的模拟通过。

## 必须由多签完成的接入

部署钱包不能替多签签名。脚本会发起 owner 转移并输出以下待办；只有部署完成且这些操作完成后，才能切换生产入口：

1. Committee owner：`adminAddContract(TradeCurationFactory)`。
2. NutboxRouter owner：`addOperator(Pump14)`。
3. Basket Registry owner：`setCreatorForwarderApproval(Pump14, true)`。
4. V13 同一个最终 owner：分别在 Pump14、TradeCurationFactory 调用 `acceptOwnership()`。

Fork 测试在本地模拟真实 owner 执行这些操作，不将它们描述为真实主网已经完成的授权。

## 验证记录

- 完整本地回归：**693 通过、0 失败、2 个原有跳过**。
- 两项奖励比例性质测试各运行 **4096 轮**，全部通过，覆盖四成分和两个可选池、严格合计 10000 bps 及单池舍入界限。
- 末池失败回滚测试已改为第六个池失败，验证余额、手续费、IPShare、Token/Community 克隆、tick 和工厂映射恢复，并能用相同 salt/tick 重试。
- 历史 BSC 区块 120508054 的四项六池回归通过。六池普通创建 **16,100,974 gas**；64 字节指数/工厂名称、16 字节符号、非零社区/建池费、首次 IPShare 和 1 BNB 预买组合 **16,231,156 gas**。

- 最新主网基础设施（区块 123329493）运行真实部署脚本，验证 V13 owner/keeper/模板及 Social signer 默认值、Hook `0x0CC1` 地址位、多签接收 owner、Committee 白名单、Router operator、Registry forwarder、16 个默认成分的路由校验，三项全部通过；结合历史四项，本轮 **7 项 fork 测试通过、0 失败**。
- 完成上述本地授权后，六池长名称/非零费/首次 IPShare/预买创建，以及上市、实际回购、持币者领取均成功；零可选池的创建及上市也通过。

| 当前主网基础设施场景 | 冷状态创建 gas（含 intrinsic） |
|---|---:|
| 四成分＋两可选池，长名称、非零费用、首次 IPShare、预买 | 16,203,635 |
| 四个股票成分＋两可选池，同样极端参数 | 16,226,840 |
| 四成分、不选可选池、首次 IPShare、预买 | 15,550,697 |

本轮所有已测组合的最高值是历史区块的 **16,231,156**，比项目单笔预算 **16,777,216** 少 **546,060 gas（约 3.25%）**。六池方案在这些场景下满足预算，余量有限。

**当前结论：主网部署已完成；上列多签授权和 owner 接收尚未执行，完成并核验后才可切换生产入口。**

上述 gas 包括 calldata intrinsic 成本；最新部署测试扣除 intrinsic 和 CALL stipend 后设置执行上限。测试使用已实现的 TradeCuration 工厂，不能保证未来任意新矿池类型或任意长度字符串都满足相同预算。注册新类型和实际发币时仍应针对实际参数估算 gas。社区保留 owner 后的自行改池规则沿用 V13，这里的六池上限针对 Pump 创建入口。

## 复现

```bash
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
FOUNDRY_ETH_RPC_URL='' FOUNDRY_FUZZ_RUNS=4096 forge test --match-contract PumpVersion14Test \
  --match-test 'testFuzz_fourComponentsTwoOptionalIndependentAllocationOracle|testFuzz_optionalRatiosSumExactly'
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test \
  --match-contract 'Pump14DeploymentForkTest|Pump14MainnetForkTest' \
  --match-test 'test_deployment14_|test_v14Fork_' -vvv
# 实际部署脚本模拟，不广播；链上配置变动后应换用新的核验区块。
FOUNDRY_PROFILE=fork forge script script/DeployBSCPump14.s.sol:DeployBSCPump14Script \
  --rpc-url bsc --fork-block-number 123329493
```
