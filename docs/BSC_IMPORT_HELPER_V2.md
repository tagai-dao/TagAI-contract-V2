# BSC ImportHelper V2：可配置矿池导入

## 版本状态与变更边界

- 设计日期：2026-10-10；源码版本常量 `VERSION = 2`。
- 状态：已在 BSC 主网部署、验证并完成多签启用（2026-10-10）；待 API/UI/worker 发布。最新核验区块：126772205。
- 2026-10-10 首版方案为固定创建交易策展矿池。同日按产品确认，最终方案扩展为 owner 登记矿池类型、调用方选择多个矿池及比例；初始默认仍为交易策展 100%。首版固定方案没有部署。
- 导入的是已有 ERC20，既有 Token、Wrapper、签名人、奖励计算器及矿池不迁移。前端/API 的导入代币业务版本仍为 V10，与 Helper 合约自身 V2 编号无关。

## 默认行为与可选行为

| 调用方式 | 新社区的矿池 |
| --- | --- |
| 原兼容入口 `createCommunityAndPool(token, address(0))` | 使用调用时 owner 配置的默认组合；初始为 TradeCuration 100% |
| 新入口 `createCommunityAndPools(token, configs)` | 完全按调用方提交的合法组合创建；不额外追加默认矿池 |
| 示例：TradeCuration 7000 / SocialCuration 3000 | 同时创建两个池，最终份额分别为 70% / 30% |

每次导入创建一个不可增发 Nutbox Community；community token 为导入币，owner / dev fund 为导入者，calculator 固定为 HourlyTickCalculator。新社区中矿池的比例总和必须等于 10,000（100%）。这些是社区矿池份额，不是交易手续费率。

兼容入口的第二个参数必须为零；V2 不接受复用任意已有社区。已经被 Wrapper 登记的代币不能重复导入。空显式配置不会自动回退默认配置，直接拒绝，避免创建无矿池社区。

## 管理权限与矿池注册

Helper 构造时直接把 owner 设置为当时 `ImportedTokenSwapWrapper.owner()`，BSC 当前为下方 Safe。不是由部署者临时持有再转交。后续 owner 变更采用 Ownable2Step；Wrapper owner 后续变更不会自动改变 Helper owner。

`adminSetPoolFactory(factory, name, maxRewardRatio, enabled)`：

- 仅 Helper owner 可调用。登记后矿池类型可以供新导入选择。
- 启用时 factory 必须有代码、已在 Nutbox Committee 白名单中，名称长度为 1–64 bytes，比例上限为 1–10,000。
- Helper 白名单与 Committee 白名单两层校验，创建时再次检查；owner 不能仅靠 Helper 登记绕过 Committee。
- 最多登记 32 个不同 factory；禁用后仍保留在枚举列表中，重启同一个 factory 不占新位置。
- 构造时只启用现有 TradeCurationFactory，上限 100%。SocialCuration 或其他矿池由 owner 按需启用。

`adminSetDefaultPools(configs)`：仅 owner 可更新默认组合，影响之后的兼容入口调用。每项包含 `factory`、`rewardRatio`、`meta`。`tradeCurationFactory` 是初始交易工厂的 immutable 地址，不代表后续的默认组合。`getDefaultPools()` 返回完整当前组合；`defaultPoolCount()` 返回默认矿池数；`poolFactoryList(i)` / `poolFactoryCount()` 支持读取登记列表。

禁用默认正在使用的 factory、降低其比例上限或移除 Committee 白名单后，旧默认配置的创建会失败；合约不会悄悄选择另一种矿池。建议先设置合法的新默认组合，再禁用旧 factory。已创建社区不会因这些配置更新被改写。

## 创建规则、费用与原子性

1. 每次选择 1–6 个矿池，factory 地址不得重复；每项比例必须大于零且不超过登记上限，总和严格为 10,000。
2. 每项 `meta` 最多 4096 bytes，并原样传给矿池 factory。具体参数有效性由该 factory 检查，例如 TradeCuration 要求为空。
3. 创建费 = Committee 社区创建费 + Committee 设置费 × 矿池数量。多付的 BNB 退回导入者。
4. 创建各池时中间比例暂为零，最后一次添加时一次性设置完整比例。全部矿池创建完毕后才登记 Wrapper 并移交社区 owner。
5. 创建入口使用 ReentrancyGuard。任一 factory 失败、Wrapper 登记失败或退款失败，整个交易回滚，已创建的社区/矿池和已付费用一并回滚。

本规则与 Pump14 的 factory 登记及选择思路一致，但没有 Pump14 的成分 LP 剩余份额：导入币的全部矿池必须合计 100%，单池允许 100%，不套用 Pump14 可选池 80% 上限。

## 事件与索引约定

- `PoolFactorySet(factory,name,maxRewardRatio,enabled)`：owner 的类型登记/启停历史。
- `DefaultPoolsSet(factories,ratios,metadata)`：默认配置的完整变更历史。
- `ImportedPoolCreated(token,community,pool,factory,rewardRatio,position)`：每个新矿池各发一次，position 从 0 连续递增。
- 兼容 `CommunityCreated(token,community,pool,creator,calculator)`：其中 pool 为组合中的第一个池；不能用这个单字段推断社区只有一个矿池。
- `ImportedCommunityRecorded` 保持原格式。

API 验证 Helper 的全部 linkage 与真实矿池 Factory 创建事件，以及 Community 最终比例。多池需数量/地址/factory/顺序一致、份额合计 100%，不能遗漏次要池。验证后一次数据库事务写入全部 Nutbox 池，并为 TradeCuration 补充专用读模型；实际存在 SocialCuration 时才填写 `community.social_pool_address`。旧 Helper 单池收据仍兼容。

当前 API 即时导入验证支持已有 SocialCuration 和 TradeCuration 两类。未来登记新矿池类型时，Helper 通用接口无需重新部署，但必须先补齐该类型的 API 事件解析、参数校验和索引模板，再面向平台用户开放；仅登记 factory 不会自动产生新的服务端处理器。

API / worker 按验证过的 community + token 查找交易策展池，无需 Pump14 optional-pool 记录。官方 Wrapper 的买入事件、实际净代币到账、交易发送者和接收者共同证明买入；卖出、转账和伪造事件不计 power。

## 现有基础设施快照（2026-10-10）

| 合约/角色 | 地址 |
| --- | --- |
| 原 ImportHelper | `0xcCB0f9a9db22cCC29fDd315180F89747118ec296` |
| ImportedTokenSwapWrapper | `0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F` |
| Wrapper owner / V2 初始 owner / Safe | `0x871fb7006C5964B21695Ba20006021777A26146C` |
| CommunityFactory | `0x5597e814399906095ecaA5769A40394F58E5E0Cf` |
| TradeCurationFactory | `0x774A48Ba391a1013Ae43289eBdf871618822CD67` |
| TradeCuration claim signer | `0x1C3864ea7a54eC4E3cEb27553A6F2927bBe4222e` |
| SocialCurationFactory（可由 owner 启用） | `0xc4674D3fBbD201Ea401a8B7e7285F956178593D8` |
| Committee | `0xe10F967DD356504EDB731612789D0D0f0ba2929f` |
| HourlyTickCalculator | `0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d` |

TradeCurationFactory 的 Committee 白名单、所属 CommunityFactory 和 signer 已只读核验。部署前快照中 Wrapper registrar 为旧 Helper；多签启用后已切换为 V2，实际交易与核验区块见文末正式部署记录。

## 部署、启用与后续审计记录

1. 使用 `script/DeployBSCImportHelperV2.s.sol` 仅部署新 Helper；脚本从 `.env` 读取 `PRIVATE_KEY_MAIN`，Forge 验证读取 `ETHERSCAN_API_KEY`。无 `--broadcast` 的执行只是本地模拟；脚本打印 Wrapper 激活目标、owner 和 calldata，不自动改 registrar。
2. 部署后记录真实新地址、部署哈希/区块、源码提交、构造参数、字节码/浏览器验证、初始 owner 和默认配置。不要把模拟地址填入生产配置。
3. Safe 在既有 Wrapper 上调用 `setRegistrar(newHelper)`，value = 0。Helper 初始 owner 已在构造时设置为 Safe，无需额外 acceptOwnership 交易。若启用初始配置之外的 factory / 默认组合，需要相应 owner 配置交易。
4. API / UI 的代码默认地址已改为正式 V2 地址，无需新增 env。如果已有 `BSC_IMPORT_HELPER` / `VITE_BSC_IMPORT_HELPER` 覆盖值，应同步改为 V2 地址。API 保留旧 Helper 的收据白名单。发布 API/UI 并更新交易策展 worker。
5. 现有前端保持使用默认入口，并根据新 Helper 的 `defaultPoolCount()` 计算创建费；owner 将默认组合改为多个池后，前端费用自动按池数变化。显式选择入口已在合约开放，当前创建界面不新增手动矿池组合编辑器。
6. 记录多签执行哈希/区块、Wrapper registrar 与 Helper owner 的最终值、API/UI 发布版本及首次新导入验收交易。

只复用现有两种策展类型时，不新增 Graph data source / template，不新增数据库迁移；继续使用 V42/V43 表。Wrapper、Pump、Token、Hook、Vault 和 calculator 无需重新部署。

## 验证记录

- 合约：旧 Helper 与 V2 合计 24 项通过。包含退款 fuzz（256 次）、双池比例 fuzz（256 次）、仅 owner 配置、更新默认组合、禁用/撤销白名单/比例上限、空列表/重复工厂/比例为零/总和不足或超额、6 池成功与 7 池拒绝，以及后续池失败的整笔回滚。
- BSC fork：区块 126769917，2 项通过；复用真实基础设施验证默认交易池＋真实 INTCB 买入奖励扣取，以及 70% TradeCuration / 30% SocialCuration 双池与 Safe 管理权。测试未发送主网交易。
- API：41 项通过，包含历史单池、新双池 linkage、次要社交池识别、事件缺失/伪造/重复、最终比例不一致、单事务持久化，以及奖励接口回归。
- 交易策展 worker：前一阶段独立临时 MySQL 全链路 22 项通过；本阶段未改动 worker 算法。
- UI：类型检查与生产构建通过；默认多池数量改变时按实际数量计算设置费。

2026-10-12 提交前在已合并 RH 更新的代码上回归：API 6 个测试文件共 44 项通过；worker 26 项通过，2 项因未提供 MySQL 测试配置跳过，TypeScript 检查通过。此前 BSC 独立临时 MySQL 全链路的 22 项通过记录仍保留；跳过项目不视为本次再次通过。

### 本次源码指纹

以下 SHA-256 对应本次验证和部署的代码，已于 2026-10-12 归档到源码提交 `79c65e7e5212a995ec7a47faf63ac7cba98be143`，两份文件指纹均与该提交一致。此次部署早于归档提交，部署时工作区含未提交代码的事实保留在部署 JSON 中。后续部署应先锁定源码提交，再核对指纹。

| 文件 | SHA-256 |
| --- | --- |
| `src/helper/ImportHelperV2.sol` | `7fc39bc8020ec1dcddea62f94eeb5c336ffe76970e90116726efd0ea9004e08c` |
| `script/DeployBSCImportHelperV2.s.sol` | `8e9bf062abf30b361c80e2c76356625bf87a5544b8b4239e8767a3829f51bcc6` |

编译配置：Solidity 0.8.26，viaIR，optimizer 200 runs（参见 foundry.toml）。主网地址、部署交易、浏览器验证和多签执行只在真实执行后记录。

### 可直接执行的部署命令

在合约仓库中先模拟：

```bash
cd "/Volumes/Extreme Pro/wangxi/work/tiptag/TagAI-contract-V2"
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCImportHelperV2.s.sol:DeployBSCImportHelperV2 \
  --rpc-url https://bsc-dataseed.binance.org \
  --legacy -vv
```

确认模拟通过后部署并验证：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCImportHelperV2.s.sol:DeployBSCImportHelperV2 \
  --rpc-url https://bsc-dataseed.binance.org \
  --broadcast --slow --legacy \
  --gas-estimate-multiplier 150 \
  --verify -vv
```

只有正式 broadcast 成功收据对应的地址可用于后续多签与生产设置。脚本末尾打印的激活 calldata 对应其本次部署地址；模拟结果不能用于主网激活。如果部署成功但浏览器验证失败，应单独补做验证，避免再次运行部署命令创建另一个 Helper。

## 2026-10-10 正式部署记录

- ImportHelperV2：`0x40BACB12D79dadf045c21C999b74484816F746F7`。
- 部署交易：`0xd86532076cdd5db8fcace3bcc1d4ee84ac6060b5800833243ce9f66528fc28f4`，区块 `126770859`，收据 status = 1。
- Owner：`0x871fb7006C5964B21695Ba20006021777A26146C`，已直接设置，无 pending ownership acceptance。
- 默认组合：`0x774A48Ba391a1013Ae43289eBdf871618822CD67` / 10,000 / 空 meta；矿池类型仅登记 Trade Curation。
- Gas used：`2080339`；effective gas price：`50000000` wei；部署实际花费 `0.00010401695 BNB`。
- 源码验证：用户 Forge 输出确认 `Pass - Verified`；独立 RPC 核验部署收据、constructor 对应 immutable getter 和运行时代码。规范化 immutable 范围后本地 artifact 与链上运行时代码一致。
- 运行时代码 hash：`0xb9d81837da6d05907fdff2acb2f32ae4d772dcfc69c1f725463c081d9d4994cd`。
- 当前 Wrapper registrar：`0x40BACB12D79dadf045c21C999b74484816F746F7`，已由多签启用。
- 正式部署快照：[import-helper-v2.json](../deployments/56/import-helper-v2.json)。
- 多签 Transaction Builder 文件：[import-helper-v2.safe.json](../deployments/56/import-helper-v2.safe.json)。仅一笔 `setRegistrar(newHelper)`，value = 0。
- 多签启用交易：`0x947bfd4789f246bc4f478a4257d534bf162ed51d33243430f83a086a319a62cd`，区块 `126772104`，收据 status = 1；`RegistrarChanged` 从旧 Helper 切换至 V2。最新区块 `126772205` 已再次核验 registrar、Helper owner 和默认交易矿池 100%。
- API / UI 的代码默认地址已经更新；生产发布结果及首次新导入验收交易待补记。

## 2026-10-12 服务代码发布记录

| 仓库 | 目标远程分支 | 本次升级提交 |
| --- | --- | --- |
| tagai-api | `bsc` | `02999b19a3fa9b9b48c55e3a5a8bc1578727980d` |
| tiptag-server | `main` | `3267e2967a4955998f4b56bb494fd955c7e3de70` |
| tiptag-ui | `main` | `587037fa` |

UI 提交前钩子的完整类型检查和生产构建通过。上述是源码发布记录，生产服务重启、UI 部署及首次新导入验收仍需单独记录。若设置过旧地址覆盖变量，API 的 `BSC_IMPORT_HELPER` 和 UI 的 `VITE_BSC_IMPORT_HELPER` 应改为正式 V2 地址。
