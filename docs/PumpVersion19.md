# Pump V19 — 开放内盘买卖、禁止内盘转账

2026-11-04 用户确认：BSC 普通创建模式由 V14 切换为新 V19；Binance Agent 模式继续使用已部署 V18，RH 继续使用 V14。普通钱包无需 Binance handle；保留 V18 自动创建 IPShare 和每地址累计 1000 万枚买入上限。普通合约钱包仍受 IPShare subject 限制，不在本次支持范围内。

## 合约规则

- 独立源码 `src/pump/Pump19.sol` / `Token19.sol`，`VERSION() = 19`。V18 源码、合约地址和行为保留；现存 V14/V18 克隆不能原地升级。
- `buyToken` 和直接转 BNB 买入均不查询 HandleRegistry。卖出同样不检查 handle。
- 每代币、每地址累计最多买入 1000 万枚；创建预买计入创建者。卖出不恢复额度。超额整笔回滚，不做部分成交。
- 在 `listed=false` 的整个阶段（包括 `listingPending` 和失败上市恢复后），公共 `transfer` / `transferFrom` 拒绝普通用户转移（本代币自己的非零 Nutbox 社区地址除外），包括给其他钱包、自己、零地址、Token、Router、Vault、DEX 或其他合约；零数量也拒绝。批准 allowance 不能绕过限制，失败不会消耗 allowance。
- 买卖使用内部 `_transfer`：卖出只通过 `sellToken` 回到曲线，直接转入 Token 不会形成另一个入口。
- 公共转账例外按收款地址判断：只要 `nutboxCommunity != address(0)` 且 `to == nutboxCommunity`，任何钱包或合约、任意时间均可通过 `transfer` 或 `transferFrom` 转入；不限制为计算器调用，不受前 15 秒、listingPending 或上市恢复影响。`transferFrom` 仍须满足 allowance 和余额。创建预买的协议转发例外保留。
- 直接 ERC20 转入只增加社区余额；要登记 168 小时奖励释放计划，仍需调用 HourlyTickCalculator.inject。两种转入均允许。反狙击自动注入继续工作，临时 allowance 成功和失败都清零。转入社区不恢复累计买入额度，也不改变曲线供应量或 BNB 储备。

- 创建预买、上市注资和其他内部协议分配保留。上市成功后恢复 ERC20 转账及已有成分池税、回购和奖励规则。内盘期间任何需要公共 Token 转账的奖励提取也受同样限制，不能以奖励功能绕过。
- 自动创建 IPShare 保留失败原子回滚、EOA subject 和未来非零创建费等 V18 约束。
- Pump19 不接受非零现有模板参数，始终部署自己的新 Token19 模板，避免误用旧 V18 规则。

## 部署准备与发布边界

部署入口：`script/DeployBSCPump19.s.sol:DeployBSCPump19Script`。从实际 V18 Pump `0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24` 读取并核验版本、基础设施、费率、成分资产、owner/keeper；保持原有固定区块 Multicall 快照方式。必须新建 Pump19、Token19 模板、Hook 和 BuybackRouter，不得把 V18 地址填作 V19。

编译配置沿用 Foundry 默认 profile：Solidity 0.8.26、viaIR、optimizer runs 100、Cancun（以最终产物设置为准）。主网广播前固定源码提交、导出 Standard JSON、核对合约大小和部署模拟；不得从测试地址推断正式部署地址。

本地实现阶段未执行主网操作；当前正式部署状态以文末“BSC 主网部署完成”及 `deployments/56/version19.json` 为准。多签权限激活、数据库迁移、Graph 发布和应用发布尚未执行。前后端 V19 地址留空并拒绝返回可用创建配置；不会静默改用 V14/V18。代码发布会使默认创建等待 V19，必须完成以下接入后一起上线。

1. 广播新的 V19 四合约部署并保存成功回执、实际地址、部署区块、源码提交和散列，完成源码验证。
2. 多签授权 NutboxRouter operator、BasketRegistry creator forwarder，接收 Pump owner；核验交易执行证据及固定块链上状态。
3. 将真实 V19 地址填入 `tiptag-ui/src/config/chains.ts` 和 `tagai-api/config/chains.js`；同步 Pump19、Token19 ABI。Router/Registry 地址使用部署实际绑定；保留 V18 配置。确认后再将 `latestPumpVersion` 更新为 19。
4. Graph 增加独立 Pump19/Hook19 数据源（真实 startBlock），创建事件记为 version=19；生命周期事件布局兼容现有指数处理器，可复用 Token18 生命周期模板。保留 V14/V18 数据源，不伪造链上不存在的内盘钱包转账。共享 IPShare 数据源继续索引自动创建。
5. listing keeper 的完整 `LISTING_KEEPER_PUMPS` 白名单追加真实 Pump19，并添加真实部署区块；保留现有 V14 主 Pump 和共享游标，检查 owner/keeper 权限。V19 上市 ABI 兼容现有 keeper。
6. 多 Pump 上市交易执行器的准入表需批准 Pump19，并以固定块 Multicall 验证 `supportsToken`；不会回退旧执行器。
7. API 先于 UI 发布。验证 `/pump/v19/creation/:creator`、确认回执登记、报价、列表、上市/回购/领取，以及未勾选=V19、勾选=V18、RH=V14。

## 验证命令

```sh
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --offline --match-contract PumpVersion19Test
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --offline --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
forge build --offline --skip test --skip script --sizes
```

V19 专项通过真实新 Pump19 构造与克隆创建测试，继承社区、成分池、上市、失败恢复、交易税及奖励回归；填满曲线由多个真实独立钱包买入，上市前不归集持仓。前后端 RPC 回归检查 Multicall3 目标、完整有序子调用及所有阶段相同 blockTag；V19 报价没有 `handleOf` 子调用，额度读取与 V18 保持独立。

## 2026-11-04 本地验证结果

- 合约离线完整回归：51 个套件，984 通过、0 失败、2 个原有跳过；V19 专项 53 通过，另含 V19 Hook salt 测试。
- Pump19 runtime 21,023 bytes / initcode 46,312 bytes；Token19 runtime 24,046 bytes / initcode 24,096 bytes。Pump constructor 加入空数组的四个参数编码后也在 EIP-3860 49,152 bytes 限制以内；runtime 满足 EIP-170。
- UI 定向回归 130 通过；`npm run build`（包括 vue-tsc）通过。
- API 定向回归 14 组、332 通过；V18/V19 本地 HTTP 模拟 RPC 另 2 组、2 项通过。后者检查 Multicall3 目标、完整有序子调用、固定 blockTag，且模拟节点拒绝独立合约调用和 JSON-RPC batch。
- ABI 从最终本地 Pump19/Token19 artifact 导出到 UI/API；这是待部署产物，不能视为主网地址或源码验证记录。
- 未执行真实主网 fork 或交易广播；实际基础设施集成及多签激活需在部署阶段独立验证。

## Nutbox 转入白名单（2026-11-04）

最终规则以用户最新澄清为准：不论创建后 15 秒内外，不论发送方/代操作方是钱包或合约，转入本代币自己的 Nutbox 社区均允许。移除了前一版仅限指定计算器及临时注资状态的判断与状态变量；其他收款地址仍受内盘转账限制。

测试覆盖普通钱包/合约持仓的直接转入、普通钱包/合约代操作方在前 15 秒内外的授权转入、缺少 allowance 回滚、其他收款地址拒绝、listingPending 注入、反狙击注入和上市后转账。直接转入不登记分发计划，正规 inject 正常记账；两者均不恢复购买额度、不改动曲线供应/BNB 储备。

前端转账弹窗按固定区块 Multicall 同时读取余额、listed 和链上 nutboxCommunity，按实际收款地址启用按钮，提交前复核并处理链/账户/代币变化；不信任 API 提供的白名单地址。RPC 回归检查 Multicall3 目标、完整有序子调用、固定区块及必需子调用失败。

BSC 区块 131553338（`0x7d7583a`）通过 `0xcA11bde05977b3631167028862bE2a173976CA11.aggregate3` 依次读取 V14/V18 的 `getFeeRatio()` 和 `getFeeReceiver()`，必需子调用均成功，结果两者均 `[30,30]`（每项 0.3%），平台地址均为 `0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048`。这是当前费率快照，owner 仍可后续调整。

常规内盘买卖：平台 0.3% + 推荐人 IPShare valueCapture 0.3%。创建后前 15 秒普通买入：平台 0.3% 不变，第二部分按 `30 + floor(7970 × (15-t)^2 / 225)` bps 计算，用 BNB 在曲线购买代币后注入社区（自动注入失败时沿用原 IPShare fallback）。创建原子预买和卖出不套用该动态买入费。15 秒后没有额外固定社区手续费。

最终收款地址白名单方案验证：完整合约回归 51 个套件，984 通过、0 失败、2 个原有跳过；V19 专项 53 项（含 256 轮时间/发送方类型模糊测试）。前端本轮定向 60 项通过，类型检查及生产构建通过。ABI 与最终产物一致；本轮未部署或发布。

## 部署就绪复核（2026-11-04）

保留当前业务代码；重新核验编译、合约大小与部署脚本通过。补充 `test/fork/Pump19Deployment.t.sol`，覆盖真实部署脚本、fork 内 owner 激活、创建/预买、无 handle 买卖、Nutbox 转入/注入及上市。测试已编译，未配置 RPC 时明确跳过。

主网 fork 尚未成功完成：公共 BSC 节点在区块 131557033 返回 missing trie node；项目配置 RPC 在区块 131557330 的预演长时间等待后主动停止；项目配置 Alchemy 在启动 fork 前 ECONNRESET。以上均不作为合约逻辑通过或失败的证据，不能将本地 984 项通过视为真实主网集成验证。未广播任何主网交易，未执行真实 owner 激活。

当前结论：本地检查通过，正式主网广播前仍需可读取固定区块完整状态的 RPC 完成预演。编译参数、大小、实际源码 SHA-256 和检查边界见 `previews/pump19-deployment-readiness-2026-11-04.json`。

## 主网 fork 预演通过（2026-11-04）

已在 BSC 固定区块 **131557330**（hash `0x2267830d70eee753c3f81b6cbe193d08b3f6100219ceb4ea49067b85cebef8e2`）完成 `Pump19DeploymentForkTest`：**1 通过、0 失败、0 跳过**。测试使用公开测试密钥 1，仅在本地 fork 内部署和执行 owner 操作，没有读取真实部署私钥或广播主网交易。当前业务合约及部署脚本的 SHA-256 与此前检查记录一致。

真实基础设施验证覆盖：部署四合约及模板绑定、owner 接收、Router operator/Registry forwarder、创建预买及矿池、前 15 秒买入与自动注入、无 handle 卖出及直接 BNB 买入、普通转账拒绝、Nutbox 直接转入及 inject、多钱包遵守累计额度填满曲线、PancakeSwap V4/V2 上市、Basket 创建、上市后恢复转账。

连接问题通过临时只读 curl 转发器及关闭 Foundry 代理自动检测解决。所有 fork 状态读取固定在同一区块，转发器拒绝广播方法与非 Multicall eth_call；早期公共节点和直连失败记录仍保留，不将其计作逻辑失败。只读 RPC 的 `eth_getAccountInfo` 能力探测被转发器拒绝，Foundry 随后以普通账户状态读取完成兼容处理，不涉及独立合约 eth_call 回退。

结果、RPC 方法审计和完整成功日志位于 `previews/pump19-deployment-readiness-2026-11-04.json`、`previews/pump19-mainnet-fork-131557330-rpc-audit.json`、`previews/pump19-mainnet-fork-131557330.log`。四合约的 61 份真实编译源码逐一核对并记录于 `previews/pump19-readiness-source-manifest.json`。日志中地址均为 **fork 模拟地址，不能用于主网或应用配置**；Foundry 报告的测试函数 gas 为 37,282,139，覆盖创建及后续生命周期；部署和权限激活在 setUp 中执行，不计入该数值，不能当作部署 gas 估算。

当前结论：合约已通过部署与主网集成预演，可以进入正式部署流程。广播前仍需固定正式源码版本并核验实际部署账户、nonce、余额和 gas；实际部署、源码验证、多签权限激活与应用发布分别记录。此前“主网 fork 未完成”的描述属于前序复核状态，现以本节结果为准。

## BSC 主网部署完成（2026-11-04）

7 笔交易均成功，nonce 705–711，区块 131574789–131574877。部署账户 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`；gas price 0.05 Gwei，实际共 13724888 gas / 0.0006862444 BNB。账户部署后 nonce 712，无待处理交易，余额 0.00211109547238798 BNB。

- Pump19：`0x94c5293001C57727291fd4865107F0B34eED471F`
- Token19 模板：`0x63386f6BFa34a3341509312023dDF5dcEFA14fFB`
- Hook：`0x28D5dA2FD4d0AAAdb72F48540CE2Ff2426950cc1`
- BuybackRouter：`0x93220081F6c98AfFC673CB2584C2e123d88a8E87`

正式业务源码提交：`d5c9a80c42603375f5921fb8fcf0948269ad1d31`。固定块 131574974 已核验四个 runtime（Hook/Buyback 的 immutable 字段结合 getter 核对），Pump/Token 与本地产物逐字节一致；V18 既有配置和权限保留。

导入 `deployments/56/version19.safe.json`，同一 2/3 Safe 执行 5 项操作；详见 `docs/PumpVersion19Multisig.md`。实际部署地址及导出 calldata 已通过一次真实代码 fork 激活演练（1 通过、0 失败），未模拟 Safe 签名、未提交提案、未在主网激活。

Standard JSON 已导出至 `deployments/56/version19-verification/`，完整 solc 0.8.26 本地重编译验证了字节码含 metadata 一致；尚未上传浏览器验证。前后端地址接入、Graph/keeper 更新及发布需在权限激活后继续，Binance V18 保留。
