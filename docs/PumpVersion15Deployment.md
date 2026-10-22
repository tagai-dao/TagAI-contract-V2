# BSC Pump V15 部署与兼容性

## V15-2 内盘转账限制部署

2026-10-21 已从 `bsc-version15-2` 的源码提交 `7238096` 完成新一批主网部署并通过 BscScan 验证：

| 合约 | V15-2 地址 |
| --- | --- |
| Pump15 | `0xD1cC369f726293ce47F8F9aB5aD5AD2d9A38121c` |
| Token implementation | `0xe1Ad6DA2D7A14936cA937835a86C74718bFF7018` |
| TagAISwapHook15 | `0x2e22F2c617aa08eaF45f952Dbb4249c89e4D0cC1` |
| TagAIBuybackRouter15 | `0x73adD1A7fE3aF8D606015E0D04894c8985F91f13` |

该批新增内盘 `transfer` / `transferFrom` 限制；7 笔交易位于区块 `128960088`–`128960116`，
实际费用 `0.013839146 BNB`。Token runtime `24,570 bytes`，链上字节码与本地构建完全一致。
NutboxRouter / BasketRegistry 授权及 Pump 所有权接收仍待 owner Safe 执行。完整交易、源码哈希和验证状态见
[version15-2.json](../deployments/56/version15-2.json)，待执行 calldata 见
[version15-2-owner-actions.json](../deployments/56/version15-2-owner-actions.json)。

状态：2026-10-21 已完成 BSC 主网部署，7 笔交易全部成功；用户已报告完成多签。最新区块 `128870733` 的固定区块 Multicall 检查仍显示两项授权为 false、Pump pendingOwner 尚未接收，**待多签链上执行**。代码合并不代表权限或生产入口已切换。
核心业务规则见 [PumpVersion15.md](PumpVersion15.md)。

## 本次正式部署

| 合约 | 确认地址 |
| --- | --- |
| Pump15 | `0x97f35B4631F4FFBF8050B17fAd6579D6F60A289D` |
| 新 Token implementation | `0x8851D281f76951d41C9ff5c820D2D387f820f073` |
| TagAISwapHook15 | `0x9A60808605f291e632e9AdbBAb4E4343f43A0CC1` |
| TagAIBuybackRouter15 | `0x5375010a9ea81293FbfbB95853Ae4305429beEa0` |

部署区块 `128869397`–`128869423`，实际 gas `13,796,281`，费用 `0.013796281 BNB`。
链上 `VERSION=15`；Hook / BuybackRouter 已绑定新 Pump；新 Token runtime 与本地构建完全一致（24,372 bytes）。
最新区块 `128870733` 的 Pump owner 仍为部署账户 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，
pendingOwner 为 `0x871fb7006C5964B21695Ba20006021777A26146C`。
NutboxRouter operator、BasketRegistry creator forwarder 均尚未授权；TradeCurationFactory 的 Committee 白名单已通过。
浏览器源码验证尚未核查或提交。

正式收据及固定区块 Multicall 核验清单：[version15.json](../deployments/56/version15.json)。
Safe Transaction Builder 的 3 项批量操作归档：[version15.safe.json](../deployments/56/version15.safe.json)，对应 BSC Safe `0x871fb7006C5964B21695Ba20006021777A26146C`，每项转出 BNB 均为 0。用户已报告完成多签，后续应跟踪现有待执行交易；该归档不表示需要重复提交。尚未获得链上激活成功收据，签名状态与执行状态分开记录。
人工核对用的 target / calldata / requiredSender 清单：[version15-owner-actions.json](../deployments/56/version15-owner-actions.json)；该清单不是 Safe 导入格式。
以下部署命令保留用于复现；本次合约已部署，无需再次运行。

源码归档提交为 `886309b`；部署时的基础提交仍保留为 `2a8c13705f1b4742b23aa988486ee2eb25d26989`。部署时包含未提交改动，已核对归档提交内全部 10 项部署源码及配置的 SHA-256 与部署记录一致。发布前 V15 / Multicall 两组定向回归 48 通过、0 失败、0 跳过。

## 部署命令

在仓库 `.env` 中使用自己的 `PRIVATE_KEY_MAIN` 和 `BSC_RPC_URL`。
Foundry 自动加载 `.env`；不要将私钥写到命令行，也不要把 `.env` 提交到 Git。
`PUMP15_OWNER` 可选，默认取现有 V14 Pump 的当前链上 owner。
其他依赖及费用、keeper 配置通过固定快照的 Multicall 从 V14 读取。

先模拟（没有 `--broadcast`，不发送主网交易）：

```bash
cd "/Volumes/Extreme Pro/wangxi/work/tiptag/TagAI-contract-V2"
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCPump15.s.sol:DeployBSCPump15Script \
  --rpc-url bsc --chain 56 --legacy -vv
```

模拟成功后正式部署：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCPump15.s.sol:DeployBSCPump15Script \
  --rpc-url bsc --chain 56 --legacy --broadcast --slow -vv
```

脚本会重新读取当前快照、nonce 并为新 Hook 挖 CREATE2 salt；不复用 V13/V14 Token 模板。
以正式广播的成功收据与输出地址为准，模拟输出不是部署记录。
Foundry 将交易记录写入 `broadcast/DeployBSCPump15.s.sol/56/`。
保持 Solidity 0.8.26、viaIR=true、optimizer runs=100、EVM Cancun。

## 新建与复用

| 合约 | V15 处理 | 验证范围 |
| --- | --- | --- |
| Pump + Token implementation | 新建；构造参数强制传零模板地址 | V15 买入资格、创建预买免检、新 Token runtime |
| TagAISwapHook | 新建，绑定新 Pump；低 16 位为 `0x0CC1` | 真实 V4 上市和交易手续费 |
| TagAIBuybackRouter | 新建，绑定新 Pump | 真实 BNB→结算币→Basket 指数回购 |
| IPShare、Nutbox CommunityFactory、HourlyTickCalculator、ERC20StakingFactory、Committee | 复用现有 V14 配置 | 真实创建、预买、Community、两组成分 LP 矿池 |
| TradeCurationFactory | 复用 `0x774A48Ba391a1013Ae43289eBdf871618822CD67` | 为新 Community 创建交易策展池 |
| NutboxRouter | 复用；须授权新 Pump 为 operator | 成分兑换、路由登记、上市后买入与回购 |
| BasketRegistry、BasketHook V4、BasketSwapRouter、Basket Token Deployer V4 | 复用；须授权新 Pump 为 creator forwarder | 真实 Basket V4 创建、指数回购、奖励领取和 Basket 赎回 |

## 部署后的授权

脚本输出每项操作的 **target + calldata + owner**，不擅自修改现有基础设施的权限。
本次快照的基础设施 owner 为 `0x871fb7006C5964B21695Ba20006021777A26146C`；正式执行时以脚本输出为准。

1. NutboxRouter owner 对 `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` 执行
   `addOperator(新Pump地址)`。
2. BasketRegistry owner 对 `0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe` 执行
   `setCreatorForwarderApproval(新Pump地址, true)`。
3. 如果目标 owner 与部署钱包不同，目标 owner 对新 Pump 执行 `acceptOwnership()`。
4. 若脚本额外输出 Committee 白名单操作，由 Committee owner 执行对应的 `adminAddContract(factory)`。
   `128866480` 快照中，复用的 staking factory、calculator、trade factory 已获许可，无需新增白名单交易。

授权完成后再切换生产发行入口和 keeper/API/UI 的新 Pump/Hook/BuybackRouter 地址。
部署成功、源码验证、权限激活和前后端切换分别记录。

## 外围入口的兼容边界

- 已有多 Pump `TagAITradeRouter`：需要 owner 执行 `setPump(新Pump地址, true)` 才会接纳 V15 代币。
- 已有 `CommentBuyAdapter` 的**上市后**主池入口：还需 owner 用 `setHookPolicy` 登记新 Hook（现有费率 30/30/30 bps）。
- `CommentBuyAdapter` 的**内盘评论代买**：当前由 Adapter 自己调用 Token，Token 看到的买方是 Adapter，
  不会读取最终用户的 handle。该入口需要单独适配；不能通过给共享 Adapter 注册 handle 来代替逐用户资格检查。
- 当前仓库的 `TagAILiquidityRouter` 使用固定 `pump.createdTokens(token)` 判断代币，
  旧部署不会因多 Pump TradeRouter 的登记自动支持 V15。需要绑定 V15 的新流动性入口或后续多 Pump 适配。

因此，本次确认的是 Nutbox / Basket V4 核心兼容及直接买入路径；没有宣称所有外围入口已经完成 V15 接入。

## 验证证据

- 业务规则最新本地回归：42 个套件，760 通过、0 失败、2 个原有用例跳过。
- 新增批量读取回归：`test/unit/BSC15DeploymentConfig.t.sol`，6 通过。
  验证 Multicall 目标地址、精确子调用集合及顺序、固定区块、区块漂移和必需数据失败处理。
- 固定 BSC 区块 `128866480`：`DeployBSCPump15Script` 无广播部署模拟成功。
- 使用项目 `.env` 的实际部署账户和 RPC、最新快照 `128868378` 再次运行交付命令（无 `--broadcast`），模拟成功。
- 区块 `128866480` 的 `Pump15DeploymentForkTest.test_v15_liveNutboxBasketNFTListingAndBuyback`：1 通过、0 失败、0 跳过。
  使用真实已部署 Nutbox/Basket/NFT/DEX 合约；不 mock/etch。现有 owner 授权和 NFT 注册仅在本地 fork 内模拟。
- fork 流程验证：无 handle 的创建预买成功→部署者后续买入失败→fork 内注册真实 NFT→买入→填满内盘→
  成分 LP 与 Basket V4 上市→DEX 买入→指数回购→领取奖励→赎回 Basket。
- 7 笔主网成功收据、区块 `128869792` 的 Multicall 绑定与授权核验，以及 Token runtime 核验已记录在
  [version15.json](../deployments/56/version15.json)。准备阶段的测试与源码 hash 保留在
  [version15-readiness.json](../deployments/56/version15-readiness.json)。

复现命令（需要支持历史状态的项目 BSC RPC）：

```bash
FOUNDRY_ETH_RPC_URL='' forge test --offline \
  --match-path test/unit/BSC15DeploymentConfig.t.sol -vv
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' PUMP15_FORK_BLOCK=128866480 \
  forge test --offline --match-path test/fork/Pump15Deployment.t.sol -vv
```

Multicall 使用 BSC 官方部署清单中的
[`0xcA11bde05977b3631167028862bE2a173976CA11`](https://github.com/mds1/multicall3/blob/main/deployments.json)，
通过 `aggregate3` 分阶段读取，所有阶段与失败重试保持同一快照区块；必需调用失败即终止，不退回独立合约读取。
