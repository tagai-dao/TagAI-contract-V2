# TagAI Contract V2 版本与部署记录

本文档记录正式发布版本的源码提交、链上地址和部署批次，用于确认某一组线上合约对应的源码。

## 记录规则

- 新版本按时间倒序追加，最新版本放在最前面。
- `版本源码提交` 是该版本部署和验证所依据的固定提交；部署后不得在不变更版本记录的情况下改用其他提交。
- `部署记录提交` 是把最终地址、交易和验证结果写回本仓库的提交。由于提交只能在部署完成后产生，它通常晚于版本源码提交。
- 每个 `versionN.json` 是该版本可独立读取的累积快照；仍然有效的旧地址会复制到新版本，已被替换的地址保留在旧版本文件中。
- 一个版本可以复用旧合约。复用地址必须标明为“复用”，不能被误认为在该版本中重新部署。
- 正式发布记录应尽量包含部署交易、区块、最终 owner、Committee 白名单状态和浏览器验证状态。历史资料未保存的字段明确标记为待补充，不凭推测填写。

---

## 2026-10-21 — BSC Pump V16（源码升级，待重新部署）

- 分支 `bsc-version16`，从已部署并验证的 V15-2 记录提交 `2df2699` 建立。
- `Pump.VERSION` 升级为 `16`；保留 Binance Agent 内盘买入资格和内盘禁止向外部地址 `transfer` / `transferFrom` 的完整规则。
- V15-2 是不可升级部署，链上仍真实返回 `VERSION=15`。V16 将使用新的 Pump、Token implementation、Hook 和 BuybackRouter 地址，不覆盖 V15-2 历史记录。
- 规则与部署入口见 [PumpVersion16.md](docs/PumpVersion16.md) 和 `script/DeployBSCPump16.s.sol`。

---

## 2026-10-21 — BSC Pump V15-2（已部署并验证，多签激活待执行）

- 分支 `bsc-version15-2`，部署源码提交 `72380962e7d101f13f9fb5d8a0f711380770e7c9`。
- 在 V15 Binance Agent 内盘买入资格基础上，内盘 `transfer` / `transferFrom` 仅允许 Token 合约作为一端；创建交易内 Pump 转发预买是唯一系统例外，上市后恢复普通 ERC20 转账。
- 7 笔 BSC 主网交易全部成功，区块 `128960088`–`128960116`，实际消耗 `13,839,146 gas` / `0.013839146 BNB`。
- Pump `0xD1cC369f726293ce47F8F9aB5aD5AD2d9A38121c`、Token implementation `0xe1Ad6DA2D7A14936cA937835a86C74718bFF7018`、Hook `0x2e22F2c617aa08eaF45f952Dbb4249c89e4D0cC1`、BuybackRouter `0x73adD1A7fE3aF8D606015E0D04894c8985F91f13` 均已通过 BscScan 源码验证。
- 区块 `128960650` 独立核验：`VERSION=15`，Hook / BuybackRouter 绑定正确；Token runtime 为 `24,570 bytes`，链上与本地 artifact 的 Keccak-256 均为 `0xc7065b48d70a26cb5ff3628d45f1398bee68e87478adb0913ccb92fd26994e38`。
- NutboxRouter operator、BasketRegistry creator forwarder 及 Pump 所有权接收仍需 Safe `0x871fb7006C5964B21695Ba20006021777A26146C` 执行。正式记录：[version15-2.json](deployments/56/version15-2.json)；操作清单：[version15-2-owner-actions.json](deployments/56/version15-2-owner-actions.json)。

---

## 2026-10-21 — BSC Pump V15（已部署，多签待链上执行）

- 分支 `version15`，基于最新 `main`：`2a8c13705f1b4742b23aa988486ee2eb25d26989`。
- 部署源码归档提交 `886309b`，已逐项核对归档内全部 10 项源码及编译配置与部署记录 SHA-256 一致；部署时基础提交和未提交状态保留在 JSON，归档提交不替代部署时事实。
- 新 Token 普通内盘买方要求指定 BSC HandleRegistry 的 `handleOf(buyer)` 非空，覆盖显式买入和直接转入 BNB；只有创建交易内的预买免检；创建完成后包含部署者在内的每次内盘买入都要校验，不校验字符串内容或格式。
- `Pump.VERSION = 15`。部署时须使用新 Token 模板；已部署旧代币保持原实现。为满足 Token 的 EIP-170 字节码大小上限，optimizer runs 从 200 调整为 100。
- 已完成 7 笔 BSC 主网交易，部署区块 `128869397`–`128869423`，费用 `0.013796281 BNB`。Pump `0x97f35B4631F4FFBF8050B17fAd6579D6F60A289D`；Hook / BuybackRouter 与新 Pump 的绑定及 Token runtime 已于区块 `128869792` 核验。源码浏览器验证尚未核查或提交；NutboxRouter / BasketRegistry 授权及 Pump 所有权接收待 owner 执行。正式记录：[version15.json](deployments/56/version15.json)；3 项操作及 calldata：[version15-owner-actions.json](deployments/56/version15-owner-actions.json)。设计与测试说明：[PumpVersion15.md](docs/PumpVersion15.md)。
- 新增 V15 专用部署脚本，复用现有 Nutbox/Basket V4/TradeCurationFactory；固定区块 `128866480` 部署模拟及真实创建→上市→回购→领取→赎回 fork 已通过。新部署读取使用 Multicall，新增 6 项回归通过。部署命令、授权和外围入口边界见 [PumpVersion15Deployment.md](docs/PumpVersion15Deployment.md)。
- Safe Transaction Builder 的操作归档：[version15.safe.json](deployments/56/version15.safe.json)，包含上述 3 项 owner 操作；原 owner-actions 文件仅供人工核对。用户已报告完成多签，区块 `128870733` 的 Multicall 核验仍显示两项授权为 false、Pump 所有权接收待执行，尚未确认链上激活交易；不重复提交该归档。
- 发布前 V15 与 Multicall 定向回归共 48 通过、0 失败、0 跳过；原完整回归 760 通过、0 失败、2 个原有跳过，独立 Multicall 回归 6 通过，真实 BSC 全流程 fork 1 通过。

---

## 2026-10-10 — BSC ImportHelper V2（已部署验证并多签启用）

- 源码归档提交：`79c65e7e5212a995ec7a47faf63ac7cba98be143`（2026-10-12）。部署发生在源码提交之前；Helper 和部署脚本的 SHA-256 均与该归档提交一致，部署时工作区状态保留在 JSON 中。
- 新增 `ImportHelperV2`：初始默认 TradeCuration 100%；支持 owner 登记矿池类型、调整默认组合，以及调用方显式选择 1–6 个矿池和合计 100% 的比例。社区 owner / dev fund 仍归导入者，继续使用 HourlyTickCalculator。
- 原 ImportHelper 保留；V2 初始 owner 直接取 Wrapper owner，管理权采用 Ownable2Step。V2 保留原创建 selector 和主池事件，新增全部矿池 linkage 事件，但不接受非零 existingCommunity。已有代币、社交策展矿池、签名领取和待注入奖励不迁移。
- 复用 Wrapper `0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F` 和 TradeCurationFactory `0x774A48Ba391a1013Ae43289eBdf871618822CD67`。Factory 白名单、社区工厂和 signer 已只读核验。
- 部署仅新增一个 helper；激活需要 Wrapper owner 多签执行 `setRegistrar(newHelper)`。已部署地址 `0x40BACB12D79dadf045c21C999b74484816F746F7`，交易 `0xd86532076cdd5db8fcace3bcc1d4ee84ac6060b5800833243ce9f66528fc28f4`，区块 `126770859`；源码已验证，链上 owner / 默认配置 / runtime artifact 已核验。多签启用交易 `0x947bfd4789f246bc4f478a4257d534bf162ed51d33243430f83a086a319a62cd`，区块 `126772104`；当前 Wrapper registrar 已切换为 V2，生产服务发布结果待补记。
- API / UI 支持新 helper 配置、通用策展矿池导入和旧收据重试；交易策展服务补充导入币买入证据和社区矿池关联，无需新增数据库迁移或 Graph 部署。
- 部署说明与验证记录：[BSC_IMPORT_HELPER_V2.md](docs/BSC_IMPORT_HELPER_V2.md)；正式快照：[import-helper-v2.json](deployments/56/import-helper-v2.json)；多签文件：[import-helper-v2.safe.json](deployments/56/import-helper-v2.safe.json)。

---

## 协议版本关系

这里的版本号对应不同的协议入口，不表示较新的编号一定替代所有较早入口。当前 BSC 新发行源码基线为 Pump V15（2026-10-21 已部署，用户已报告完成多签，最新链上快照仍待权限激活）；V14 的多签状态在下文保留为 2026-09-23 历史快照。外部 ERC20 的导入业务版本仍为 V10，2026-10-10 起链上登记入口已切换为 ImportHelperV2，服务发布状态见上方记录。V11 及更早 Pump 创建的 Token 继续使用各自部署时绑定的实现和池配置。Robinhood Chain 的独立版本不因本次 BSC 合并而升级。

| 版本 | 状态 | 功能定位 |
| --- | --- | --- |
| V1–V7 | 历史版本 | 早期 bonding curve、IPShare 和 PCS Hook 迭代，源码与历史地址位于旧版 [`tagai-contract`](https://github.com/tagai-dao/tagai-contract) 仓库。 |
| V8 | 已被新发行入口替代 | 面向 Agent 社区，bonding curve 上市前只允许 Agent 交易，并为 Nutbox Community 自动分配 15% 供应量。 |
| V9 | 历史发行入口 | 通过 Pump 创建新社区代币，支持开放 bonding curve 交易、反狙击、PCS V4 上市、TagAISwapHook 和 Nutbox 奖励注入；既有 Token 保持原实现。 |
| V10 | 外部代币导入业务版本 | 通过 Helper 将已有 ERC20 接入不可增发 Community；旧 Helper 默认 SocialCuration，现已启用的 ImportHelperV2 默认 TradeCuration 100%，支持多池选择和比例。不创建 Token、bonding curve、PCS V4 池或 Hook。 |
| V11 | 历史发行入口，既有 Token 继续使用 | 更新 Pump、Token implementation 和 TagAISwapHook，并增加 Index Broker NFT、NFT AMM、指数回购与指数挖矿。该批部署及验证记录见下文。 |
| V13 | 既有发行入口，已创建 Token 继续使用 | 成分 LP 矿池、keeper 原子上市、Basket V4 指数创建与回购分红，以及独立交易 / 流动性路由；不自动迁移旧 Token。 |
| V14 | 已部署，源码已合并 main；权限状态见历史快照 | 创建代币时可选交易策展矿池；复用 V13 Token 模板；配套多 Pump Router / Adapter 支持由 owner 配置后续兼容版本。 |
| V15 | `version15` 分支，已部署，用户已多签、待链上执行 | 内盘买方须有指定 BSC HandleRegistry 的非空 handle；只有创建交易内的预买免检，部署者后续买入也需校验。 |
| V16 | `bsc-version16` 分支，待部署 | 继承 V15 买入资格，并禁止内盘用户把 Token 转给其他地址、Router、Vault 或外部 DEX 池。 |

---

## V14 — BSC 交易策展与多 Pump 交易路由（部署：2026-09-22 / 2026-09-23；源码发布：2026-09-29）

### 2026-09-29 源码合并与发布记录

| 项目 | 记录 |
| --- | --- |
| 发布分支 | `bsc-version14` 合并至 `main`，使用非快进合并保留版本历史 |
| 发布标签 | `version14`，annotated tag，指向包含本节记录的合并提交 |
| 合并前 main | `70a9f7466d7a15b0898b6e1cc63c1624c13db6c3` |
| 已归档的版本分支提交 | `015f68b8a50c683867e829ec23139d51384bfc44` |
| 纳入的版本提交 | `b0be01b`（Pump14 / 交易策展与部署记录）、`4302d35`（注释）、`7caabdc`（多 Pump Router / Adapter 与部署记录）、`015f68b`（版本历史） |
| 发布范围 | Pump14 可选矿池、TradeCuration、多 Pump Router / Adapter、配套 ABI、部署脚本、测试、地址及角色记录 |

本次发布保留 V13 Token 模板复用、可选池合计最高 80%、最多 4 个成分 LP 池加 2 个可选池，以及既有 `feeFree` 规则。部署源码提交、部署地址和交易记录保持原值；`version14` 标签用于固定本次主分支源码归档，不替代已部署字节码的来源记录。

本次为源码合并，没有重新部署合约、切换 Vault Adapter 或执行管理权交易。下文的 owner、pendingOwner、授权和浏览器验证状态均为 **2026-09-23 历史快照**，本次未重新核验其当前链上状态，也不据此判定现在仍待签核。此前测试报告保留原日期；本次验证结果单独记录如下。

2026-09-29 实际验证：Foundry `1.6.0-v1.7.0`、Solidity `0.8.26`，本地回归 **40 个套件、701 通过、0 失败、2 个原有用例跳过**。Fuzz 每例 256 轮；不变量按仓库默认配置执行。跳过项为 `test_reentrancy_protectedDuringRegisterPool` 和 `test_receive_revertsWhenListed`。本次未重跑主网 fork 测试，下文 2026-09-23 的 fork 结果仅作为历史记录。

```bash
FOUNDRY_ETH_RPC_URL='' forge test --offline \
  --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
```

合并后的代码、测试、ABI 和部署快照与归档分支完全一致，仅 `VERSION_HISTORY.md` 增加本次发布记录；合并无冲突，差异空白检查通过。

### 2026-09-22 / 2026-09-23 部署记录

| 项目 | 记录 |
| --- | --- |
| 状态（2026-09-23 快照） | Pump14 与配套 Router / Adapter 已部署；当时用户已发起多签，等待签核，尚未核验链上执行完成 |
| 网络 / 发布分支 | BNB Smart Chain（chain ID `56`）/ `bsc-version14` |
| Pump14 版本源码与部署记录提交 | `b0be01b3105c0acb8f7dcd21586930c6b7db8fa2`；已逐项核对该提交源码与 V14 部署快照 SHA-256 一致 |
| 多 Pump Router / Adapter 版本源码与部署记录提交 | `7caabdc90ce7b256da49a2f6c76992abde0295d0` |
| 部署时基础提交 | Pump14：`70a9f7466d7a15b0898b6e1cc63c1624c13db6c3`；Router / Adapter：`4302d3561566291b02d41e3396e5444983eb1dd4`。部署时均包含未提交改动，以各部署记录的源码 SHA-256 和上述归档提交定位源码 |
| 部署快照 | [Pump14](deployments/56/version14.json)、[多 Pump Router / Adapter](deployments/56/multi-pump-trading.json) |
| 多签待办 | [8 项调用及 calldata](deployments/56/multi-pump-trading-multisig-calls.json)，全部通过区块 `123532032` 的只读模拟；助手未提交或执行多签交易 |
| 目标 owner | `0x871fb7006C5964B21695Ba20006021777A26146C` |

### 本次功能与兼容范围

- Pump14 创建代币时可选交易策展矿池，可选池合计奖励比例上限 80%；剩余份额按指数成分权重分配给 LP 质押矿池。不选可选池时沿用 V13 分配方式。
- 最多 4 个成分 LP 池加 2 个可选池，共 6 池；TradeCuration 按社区创建，使用与 SocialCuration 相同的官方 signer，`feeFree` 保持原社交策展语义。
- 复用 V13 Token implementation；Hook 和 BuybackRouter 为 Pump14 新部署。keeper、signer 和角色快照记录在 V14 地址 JSON 中。
- 新 TagAITradeRouter 支持 owner 管理多个兼容 Pump，已配置 Pump13、Pump14；新 CommentBuyAdapter 支持按地址和代码哈希配置 Hook。V13/V14 费率均为 30/30/30 bps，未改变现有收费。
- 后续 Pump 沿用兼容 Token 接口、基础设施和收费规则时，可通过配置接入；新交易机制仍需适配。旧代币和外部代币保留现有分流路径。
- 本次未重新部署 Vault，用户余额和授权留在原 Vault；待 owner 执行 `setAdapter(newAdapter)` 后切换 Au-Pay 入口。

### 主网地址与部署批次

| 合约 | 地址 | 部署 / 复用 |
| --- | --- | --- |
| Pump14 | `0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34` | 2026-09-22，区块 123333750 |
| Token implementation | `0xcC8f585593feAb2a27f9e699a6b578d46446c88C` | 复用 V13 |
| TagAISwapHook14 | `0x2F0b231CAE7EdE4be0c52aA7eD5bAC62d1000Cc1` | 2026-09-22，区块 123333753 |
| TagAIBuybackRouter14 | `0x60381FCD630a4cF2002C44971d14a91bd4C78ab4` | 2026-09-22，区块 123333761 |
| TradeCurationFactory | `0x774A48Ba391a1013Ae43289eBdf871618822CD67` | 2026-09-22，区块 123333767 |
| TradeCuration implementation | `0x2FfAa2659c760D958999262e3941163F46E9845B` | Factory 内部创建 |
| 多 Pump TagAITradeRouter | `0xB70544BfdACaBD8718261d7A6be5208b7D2f6Ebf` | 2026-09-23，区块 123531055 |
| 多 Pump CommentBuyAdapter | `0x226D3e94569c44578a892A5158F0a3Defe49B8ca` | 2026-09-23，区块 123531065 |
| Au-Pay CommentTradeVault | `0xAB2A0FF3BDbdD68E7100B6875Ac4a58db851d363` | 复用，不迁移用户余额或授权 |

Pump14 批次共 9 笔交易，创建 5 个合约，费用 0.00053861455 BNB；新 Router / Adapter 批次共 6 笔交易，创建 2 个合约，费用 0.00027505005 BNB。完整交易哈希和 gas 记录见对应部署快照。

### 管理权、授权与验证状态

链上快照显示 Pump14、TradeCurationFactory、新 Router、新 Adapter 的 owner 仍为部署账户 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，pendingOwner 为上述多签。待办包括四份合约接受管理权、Committee 授权 TradeCurationFactory、NutboxRouter 添加 Pump14 operator、Basket Registry 授权 Pump14 creator forwarder，以及最后切换 Vault Adapter。用户随后已发起多签；**发起 / 签核不等于链上执行成功**，执行后需重新核验并更新状态。

Pump14 批次的 5 个新合约已记录 BscScan 源码验证完成；新 Router / Adapter 的源码验证尚未提交，等待用户授权向 BscScan 公开源码，不能将部署成功记作源码验证通过。

2026-09-23 多 Pump 配套改动验证：本地合约测试 701 通过、2 个原有用例跳过；真实 BSC 分叉测试 7 通过（包括旧代币、外部代币和 Pump14 搭配 V13 Token 模板的创建、上市、买入、卖出）；server 相关测试 28 通过。三个部署脚本编译通过，ABI 与产物一致。交易策展 server/API/前端实现及迁移需另行发布，并在多签执行后做生产端到端验证。

详细说明：[Pump14 部署检查](docs/PumpVersion14DeploymentReadiness.md)、[多 Pump 交易路由](docs/MultiPumpTrading.md)。

---

## V13 — BSC 源码发布（2026-09-09）

| 项目 | 记录 |
| --- | --- |
| 发布分支 | `version13` 合并至 `main`，保留合并历史 |
| 发布标签 | `version13`，annotated tag，指向包含本节版本记录的合并提交 |
| 合并前 main | `d579d39c7ae1e18c9e9670acce9f9a001fad7739` |
| 已归档的版本分支提交 | `b109f1abfc6b08538bbc09ef908975ca71f3b935` |
| 首次 V13 源码记录 | `fe926f9`（Pump / Token V13 发布提交） |
| 部署快照 | [`deployments/56/version13.json`](deployments/56/version13.json) |
| 协议与既有测试报告 | [`docs/PUMP_TOKEN_HOOK_V13.md`](docs/PUMP_TOKEN_HOOK_V13.md) |
| 路由部署记录 | [`docs/BSC_V13_ROUTERS_DEPLOY.md`](docs/BSC_V13_ROUTERS_DEPLOY.md) |

### 主要变更与兼容范围

- 创建时确定 1–4 个成分和权重，为每个成分创建 T–资产 V2 Pair 及 Nutbox LP 质押矿池；矿池名称仍为 `V2 LP Staking`。
- 曲线满额后进入 pending，由 owner / keeper 提交逐腿最低到账及 deadline，原子完成 V4 / V2 注入、路由注册和 Basket V4 指数创建；失败整笔回滚。
- 上市后 Hook 费用分配、成分池 Token 转账销毁、指数回购与持有人分红按 V13 规则执行。
- `TagAITradeRouter` 执行前端计算的多池交易，保留 IPShare subject；`TagAILiquidityRouter` 支持双资产及 BNB 加池、余量回售退款。LP 质押 / 解押仍是独立用户操作。
- V11 及更早 Token、既有 Hook / PoolKey / Community 不自动迁移。本次未修改矿池命名、重新部署合约或执行链上授权。

### 已记录的 BSC 地址

以下为仓库已有部署快照，不表示本次重新部署或重新完成链上验证。

| 合约 | 地址 |
| --- | --- |
| Pump13 | `0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa` |
| Token implementation | `0xcC8f585593feAb2a27f9e699a6b578d46446c88C` |
| TagAISwapHook | `0xaC29EaEb5764A83f7Ed03240EA2aF54018210cc1` |
| NutboxRouter | `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` |
| TagAIBuybackRouter | `0x7f10EB00FffDdE548F13E38871b04b0967Aa2fDB` |
| TagAITradeRouter | `0x7D5480C10A98b0Feb4e5fA77aF3F01aE3a5E86F4` |
| TagAILiquidityRouter | `0x2868FDdf7F86041557257c55a79A382536401752` |

`version13.json.sourceCommit` 的 `d579d39...` 是部署时工作区的基础提交，**不是包含全部部署改动的干净源码快照**。本次保留该历史字段，不将它改写为发布 tag；部署复现仍需结合协议文档第 16 节的源码哈希和原部署产物。发布 tag 用于固定当前已提交的源码及文档，不替代部署字节码核验。

历史部署记录中的多签授权 / ownership 待办和 Verified 标记仍按当时记录保留，本次没有复核其当前链上状态。两个辅助路由的部署交易和区块已归档，源码验证状态不从 receipt 成功推断。

### 配套仓库与发布检查

本版本依赖 `bsc-basket-contract` 的 Basket V4 部署，但截至此次归档，该仓库的 V4 源码分支尚未推送；按用户确认，本次只合并 TagAI V13，不为 Basket 创建 tag，也不把现有 Basket V3 main 标记为 V4。

本次仅执行本地编译 / 测试，不广播交易。默认测试命令被既有 `script/Deploy.s.sol` 对缺失的 `src/mocks/MockCLPoolManager.sol`、`src/mocks/MockVault.sol` 导入阻断；定向测试使用 `--skip script`，不把脚本编译或全量测试记作通过。既有主网 fork 报告保留为历史结果，本次未重跑依赖 Basket V4 产物的 fork 测试。

本次实际验证：Solidity 0.8.26，fuzz 每例 256 次。4 个核心单元套件共 81 项通过；V13 安全套件 40 项通过（包含继承的 29 项 Pump 测试），均无失败或跳过。执行命令：

```bash
FOUNDRY_ETH_RPC_URL='' forge test --offline --skip script \
  --match-path 'test/unit/*.t.sol' \
  --match-contract 'PumpVersion13|TagAITradeRouter|TagAILiquidityRouter|TagAIBuybackRouter' \
  --fuzz-runs 256
FOUNDRY_ETH_RPC_URL='' forge test --offline --skip script \
  --match-path 'test/security/Version13Security.t.sol' --fuzz-runs 256
```

---

## V11 — BSC 正式版本

V11 使用累积部署快照。`version11.json` 从 V10 继承仍然有效的合约地址，并记录本次新部署的 Pump、Token implementation、TagAISwapHook 和 Index Broker NFT 合约组。

| 项目 | 记录 |
| --- | --- |
| 状态 | Pump V11 已上线；升级后的 Index Broker NFT 合约已部署、完成 BscScan 源码验证和主网 Fork 测试，Factory 在最终 Owner 交接前保持未授权状态 |
| 网络 | BNB Smart Chain（chain ID `56`） |
| 来源版本 | V10 |
| 版本源码提交 | [`a573440387b079252bb936bcfa2ae14d52cacdc6`](https://github.com/tagai-dao/TagAI-contract-V2/commit/a573440387b079252bb936bcfa2ae14d52cacdc6) |
| Index Broker NFT 升级源码提交 | [`cac9b4e8e4c5e6ecc0fbbf2f3b046b5af1435442`](https://github.com/tagai-dao/TagAI-contract-V2/commit/cac9b4e8e4c5e6ecc0fbbf2f3b046b5af1435442) |
| Pump 部署记录提交 | [`9a7f9f77441304e2f27744fa8773786ca74015f9`](https://github.com/tagai-dao/TagAI-contract-V2/commit/9a7f9f77441304e2f27744fa8773786ca74015f9) |
| Index Broker 部署记录提交 | [`43aa618e4f221720a849dbe6d52506849730bbf4`](https://github.com/tagai-dao/TagAI-contract-V2/commit/43aa618e4f221720a849dbe6d52506849730bbf4) |
| 部署日期 | Pump V11：2026-08-14；NutboxRouter 与 NFT 升级：2026-08-18 |
| 部署账户 | [`0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`](https://bscscan.com/address/0x78c2af38330c5b41ae7946a313e43cdceeaf8611) |
| 目标管理地址 | [`0x871fb7006C5964B21695Ba20006021777A26146C`](https://bscscan.com/address/0x871fb7006c5964b21695ba20006021777a26146c) |
| 部署快照 | [`deployments/56/version11.json`](deployments/56/version11.json) |
| Pump/Token/Hook 详细更新 | [`docs/PUMP_TOKEN_HOOK_V11.md`](docs/PUMP_TOKEN_HOOK_V11.md) |
| Index Broker NFT 详细说明 | [`src/nutbox/dapps/index-broker-nft/README.md`](src/nutbox/dapps/index-broker-nft/README.md) |

### Pump、Token implementation 与 Hook

| 合约 | BSC 主网地址 | 部署交易 / 区块 |
| --- | --- | --- |
| Pump | [`0x8fEF5b4c0f761a0cc447800e3019B089ac306F28`](https://bscscan.com/address/0x8fef5b4c0f761a0cc447800e3019b089ac306f28) | [`0x4e450e...36307`](https://bscscan.com/tx/0x4e450e816c1e752172fc60568f636a2dcc4b019ef2b86c56d31220ccaff36307) / `115869783` |
| Token implementation | [`0xfD40C112F39D372786265a032C546D05Feec4D66`](https://bscscan.com/address/0xfd40c112f39d372786265a032c546d05feec4d66) | 由 Pump 构造函数在同一交易中创建 / `115869783` |
| TagAISwapHook | [`0x9E38747072F326b4e614EfF6FdCA8529db090cc1`](https://bscscan.com/address/0x9e38747072f326b4e614eff6fdca8529db090cc1) | [`0xaf2a6f...cf98c2`](https://bscscan.com/tx/0xaf2a6fe984638464dda75399c55e3ebcac512f18bf2ab4ec507adc936c7aee58) / `115869796` |

Hook CREATE2 salt 为 `5845`，权限位图为 `0x0cc1`。三个地址均已完成 BscScan 源码验证。

本次 Pump/Token/Hook 的主要变化：

- 新上市池启用原生 0.3% LP Fee，上市流动性继续永久保存在 Token 合约仓位中；
- 任何地址可调用 `Token.collectFees()`，BNB LP Fee 的 0.5% 奖励调用者、其余发送平台，社区 Token LP Fee 进入原上市 Hook；
- Token 在上市时固定 Hook 和 Pool 参数，Pump 后续更换默认 Hook 不会改变旧池；
- Hook 上市后不再读取 Pump 的内盘 `feeRatio`：买入收取 BNB 侧 0.3% 给 IPShare 和社区 Token 输出侧 0.3% 给 Nutbox；卖出按同一 BNB 毛金额分别收取 0.3% 给 IPShare、0.3% 给平台；
- Hook 注入预算改为实际 Token 余额，可由初始 150M、买入 Token Fee、LP Token Fee 和外部转账持续补充；
- 修正公开第一笔买入绕过 anti-snipe、窗口内触发上市、Calculator 选择及失败授权残留；
- Pump 在创建 Community 后把 `devFund` 设置为 Token 创建者，并向创建者发起 Community 管理权交接。

完整资金流、兼容范围和安全不变量见 [`Pump、Token 与 TagAISwapHook V11 更新说明`](docs/PUMP_TOKEN_HOOK_V11.md)。

### Index Broker NFT 合约组

| 合约 | BSC 主网地址 | 部署交易 / 区块 |
| --- | --- | --- |
| StonkBrokerRenderer | [`0xd4B6120f566CDecD88b7Be6f994a6c7493F8a068`](https://bscscan.com/address/0xd4b6120f566cdecd88b7be6f994a6c7493f8a068) | [`0x03bf54...128bf`](https://bscscan.com/tx/0x03bf54163e7379b91fbd300e994861f5508ec7c58ad0ce165793eb40d38128bf) / `115870623` |
| StonkBrokerFaceRenderer | [`0x42f24CfAaaE018c24f44820bfA9C0694981551CC`](https://bscscan.com/address/0x42f24cfaaae018c24f44820bfa9c0694981551cc) | Renderer 构造函数内部创建 / `115870623` |
| StonkBrokerBodyRenderer | [`0xA6269124844addc89A62CBb760b0b58a28977b42`](https://bscscan.com/address/0xa6269124844addc89a62cbb760b0b58a28977b42) | Renderer 构造函数内部创建 / `115870623` |
| StonkBrokerAccessoryRenderer | [`0xc76717354091DcFb177c3B4e162aBC4Fca202D87`](https://bscscan.com/address/0xc76717354091dcfb177c3b4e162abc4fca202d87) | Renderer 构造函数内部创建 / `115870623` |
| NutboxRouter（平台共享） | [`0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f`](https://bscscan.com/address/0x04e2d43ba38e3f3f0d0dab3a30d1b58bfe9b659f) | [`0xf7dc70...27246`](https://bscscan.com/tx/0xf7dc700379de2c8003838b35f393804a4834840aa4bcf88d7e9b2a5518a27246) / `116637869` |
| IndexBrokerNFTBurn template | [`0x1D875946C87a650AF2Aa5B04427D44E647a480B9`](https://bscscan.com/address/0x1d875946c87a650af2aa5b04427d44e647a480b9) | [`0x73d7a4...7361a`](https://bscscan.com/tx/0x73d7a4026fef4d3e661875e76803392c52d28a06df686f1febc0c85f0c07361a) / `116652658` |
| IndexBrokerNFTStake template | [`0xc24Ff0009fF1AaD70eF8714ee32ebc8f6b7983a5`](https://bscscan.com/address/0xc24ff0009ff1aad70ef8714ee32ebc8f6b7983a5) | [`0x874a2e...15d05`](https://bscscan.com/tx/0x874a2ece2eca36ee87facc6a09dc1980b3f135cd4f4ce43b1945f0e96da15d05) / `116652661` |
| IndexBrokerNFTAMM template | [`0x698680412e34db49CdBa62c46a0Faad31D05ce0A`](https://bscscan.com/address/0x698680412e34db49cdba62c46a0faad31d05ce0a) | [`0x7aa9a4...1405`](https://bscscan.com/tx/0x7aa9a457cdb5863d4ad725e4050fdee0133cb240e14a251a027b27ed2f8a1405) / `116652664` |
| IndexBrokerNFTFactory | [`0xB1708D2F3A504846a47cdB2e4Dfb48b3ea1c9b5F`](https://bscscan.com/address/0xb1708d2f3a504846a47cdb2e4dfb48b3ea1c9b5f) | [`0x472ac6...ffdb`](https://bscscan.com/tx/0x472ac65e4f2ba424b9965377b2deea90511f131d0f2b3d087c6e14c6f55fffdb) / `116652670` |

以上当前地址均已完成 BscScan 源码验证，并在 BSC 区块 `116653696` 完成部署后 Fork 生命周期测试。Renderer 及三个子 Renderer 沿用原部署；旧 `IndexBrokerNFTPriceOracle` 和未公开的旧 Factory、Pool、AMM 地址已被共享 NutboxRouter 与本表新地址取代。Index Broker NFT 的铸造模式、动态模板、白名单、AMM、DEX 价格源、指数回购、社区/指数双挖、揭图和 Renderer 接口，统一以 [`Index Broker NFT 矿池说明`](src/nutbox/dapps/index-broker-nft/README.md) 为准。

---

## Pump V9 / ImportHelper V10 — V11 之前的 BSC 基线

这是合并 Index Broker NFT 以及 Pump、Token、Hook 下一次升级之前，`main` 分支上的完整生产基线。V9 和 V10 是并行入口：V9 用于发行新社区代币，V10 用于导入已有 ERC20。

| 项目 | 记录 |
| --- | --- |
| 状态 | V11 发布前的生产基线；历史地址继续服务既有 Token 和外部代币导入 |
| 网络 | BNB Smart Chain（chain ID `56`） |
| 完整基线提交 | [`06933725e6bc684a1e9c59da8a03c787e23e3a75`](https://github.com/tagai-dao/TagAI-contract-V2/commit/06933725e6bc684a1e9c59da8a03c787e23e3a75) |
| 源码分支 | `main` |
| 基线记录日期 | 2026-08-14 |
| V9 部署快照 | [`deployments/56/version9.json`](deployments/56/version9.json) |
| V10 部署快照 | [`deployments/56/version10.json`](deployments/56/version10.json) |
| 历史标签 | `version9` → [`a5e58f75cf98cf12adf68cb6f7bbb9932ea8af50`](https://github.com/tagai-dao/TagAI-contract-V2/commit/a5e58f75cf98cf12adf68cb6f7bbb9932ea8af50) |

> `version9` 标签早于 NFT Mining 和 Basket Mining 的提交，因此该标签不能单独代表本节列出的完整线上基线。完整基线以 `06933725e6bc684a1e9c59da8a03c787e23e3a75` 为准。

### 部署账户

| 项目 | 地址 |
| --- | --- |
| 历史部署账户 | [`0xf0a27ec9bb8AC28007cB474fC1ea0A9396fe6991`](https://bscscan.com/address/0xf0a27ec9bb8ac28007cb474fc1ea0a9396fe6991) |

### Pump V9 核心合约

本批地址由提交 [`149ba65b6bded78c7c59b1792f0c6837fbedb8f9`](https://github.com/tagai-dao/TagAI-contract-V2/commit/149ba65b6bded78c7c59b1792f0c6837fbedb8f9) 写入部署记录；该提交同时包含对应的 Pump/Hook 源码调整。仓库记录日期为 2026-05-25。

| 合约 | BSC 主网地址 | 备注 |
| --- | --- | --- |
| Pump | [`0x327a473c763bcf0d60CCd6811F832332939110D5`](https://bscscan.com/address/0x327a473c763bcf0d60ccd6811f832332939110d5) | V9 工厂 |
| Token implementation | [`0x69B1B0635220e5f16A36Ad44c3B2B1FB9ca65e16`](https://bscscan.com/address/0x69b1b0635220e5f16a36ad44c3b2b1fb9ca65e16) | Pump 创建 Token 使用的实现 |
| TagAISwapHook | [`0x78443e75aD3D70DAAab0De33d2D5Dea0cBae0cC1`](https://bscscan.com/address/0x78443e75ad3d70daaab0de33d2d5dea0cbae0cc1) | PCS V4 Hook；CREATE2 salt 为 `1105` |

### ImportHelper V10

本批地址及源码由提交 [`33d26e54c5ad5bb2cef859bab0cb9eed9cf641f5`](https://github.com/tagai-dao/TagAI-contract-V2/commit/33d26e54c5ad5bb2cef859bab0cb9eed9cf641f5) 记录。仓库记录日期为 2026-06-01。

| 合约 | BSC 主网地址 |
| --- | --- |
| ImportHelper | [`0xF346A700830633bB27a46fC1e7eAAE49F593A4c6`](https://bscscan.com/address/0xf346a700830633bb27a46fc1e7eaae49f593a4c6) |

ImportHelper V10 与 Pump V9 的用途不同：它只为已有 ERC20 创建绑定该代币的不可增发 Community，设置调用者为 `devFund`，挂载默认 100% 奖励比例的 SocialCuration Pool，并把 Community 所有权交给调用者。它不部署 ERC20、Pump Token、bonding curve、PCS V4 流动性池或 TagAISwapHook。

### NFT Mining 与 Basket Mining

本批地址及源码由版本源码提交 [`06933725e6bc684a1e9c59da8a03c787e23e3a75`](https://github.com/tagai-dao/TagAI-contract-V2/commit/06933725e6bc684a1e9c59da8a03c787e23e3a75) 记录。仓库记录日期为 2026-08-03。

| 合约 | BSC 主网地址 |
| --- | --- |
| NFTMiningPoolFactory | [`0x21155400f915A239ca2228243cFE3761caF60128`](https://bscscan.com/address/0x21155400f915a239ca2228243cfe3761caf60128) |
| NFTMiningPoolTemplate | [`0x0a937898800444497175316f925a2aE1CA83E592`](https://bscscan.com/address/0x0a937898800444497175316f925a2ae1ca83e592) |
| BSCNFTMiningRenderer | [`0x9e2878532240d79470bf4dE615eAc2A1E85546C9`](https://bscscan.com/address/0x9e2878532240d79470bf4de615eac2a1e85546c9) |
| BasketTVLMiningPoolFactory | [`0x6B1B18336E774164dF01EfDC0901559909f2d074`](https://bscscan.com/address/0x6b1b18336e774164df01efdc0901559909f2d074) |
| BasketTVLMiningPoolTemplate | [`0xcbe3A0441D2f60dCc09A707C7F9B2dA42C3b8af1`](https://bscscan.com/address/0xcbe3a0441d2f60dcc09a707c7f9b2da42c3b8af1) |
| BasketStakePoolTemplate | [`0x34E5fC87f95816c3144EA16a8EDD52F2Df9D1D28`](https://bscscan.com/address/0x34e5fc87f95816c3144ea16a8edd52f2df9d1d28) |

### 复用的 Nutbox、Basket、IPShare 与 PCS V4 基础设施

以下地址是 V9 依赖或复用的正式合约，不是上述三个部署批次中新部署的合约。

| 合约 | BSC 主网地址 |
| --- | --- |
| Committee | [`0xe10F967DD356504EDB731612789D0D0f0ba2929f`](https://bscscan.com/address/0xe10f967dd356504edb731612789d0d0f0ba2929f) |
| CommunityFactory | [`0x5597e814399906095ecaA5769A40394F58E5E0Cf`](https://bscscan.com/address/0x5597e814399906095ecaa5769a40394f58e5e0cf) |
| BasketRegistry | [`0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe`](https://bscscan.com/address/0x5b45ad2c3a2b8b8989579162c4fae2d64598cefe) |
| HourlyTickCalculator | [`0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d`](https://bscscan.com/address/0x6ccec02e7d371fed954d7d16ecb7f2f57cccf54d) |
| SocialCurationFactory | [`0xc4674D3fBbD201Ea401a8B7e7285F956178593D8`](https://bscscan.com/address/0xc4674d3fbbd201ea401a8b7e7285f956178593d8) |
| DFXStarScoreStakingFactory | [`0x77Fb65140B746e639bB512c2C25604d1924aE774`](https://bscscan.com/address/0x77fb65140b746e639bb512c2c25604d1924ae774) |
| DFXStarScoreStaking | [`0x2D91b9a98A49C8dd2CF68Be2F8ABbFB3a78C2eae`](https://bscscan.com/address/0x2d91b9a98a49c8dd2cf68be2f8abbfb3a78c2eae) |
| IPShare | [`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`](https://bscscan.com/address/0x95450aad4cc195e03bb4791b7f6f04ac6d9ba922) |
| PancakeSwap V4 CLPoolManager | [`0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b`](https://bscscan.com/address/0xa0ffb9c1ce1fe56963b0321b32e7a0302114058b) |
| PancakeSwap V4 Vault | [`0x238a358808379702088667322f80aC48bAd5e6c4`](https://bscscan.com/address/0x238a358808379702088667322f80ac48bad5e6c4) |

### 历史记录缺口

当前仓库只保存了以上地址，没有保存全部部署交易哈希和部署区块。以下信息后续如能从广播文件、部署钱包或区块浏览器可靠恢复，应补充到本节：

- 每个部署批次的交易哈希和区块号；
- 各 Ownable 合约当前 owner，以及两步所有权是否已完成接收；
- NFTMiningPoolFactory、BasketTVLMiningPoolFactory 等合约的 Committee 白名单交易；
- BscScan 源码验证状态及对应验证参数。
