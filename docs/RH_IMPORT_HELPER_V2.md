# RH ImportHelperV2

日期：2026-10-12。合约仓库主目录已切到 `rh`；该分支先快进纳入已部署 RH V14 的
`8bab1cf`，再实现本次升级。BSC V2 保存在 `main` 的 `79c65e7`，本次沿用其业务逻辑，
仅将原 Helper 的间接 imports 换成 RH 的独立接口 imports。

状态：代码、本地验证、主网部署和 registrar 切换完成；**API/UI 默认地址及索引接入仍待更新**。
浏览器源码验证已由操作员确认完成；真实部署信息见文末。
后续 RH 合约统一使用 [浏览器 Standard JSON 验证流程](RH_CONTRACT_VERIFICATION.md)。
不得将本地模拟地址填入生产配置。RH 导入币业务版本仍为 V10，Helper 自身版本为 V2。

## 新导入的行为

- 初始默认组合：现有 RH TradeCurationFactory 创建交易策展池，奖励份额 100%。
- 初始 owner：部署时的 `ImportedTokenSwapWrapper.owner()`，直接设置，不需要 acceptOwnership。
  之后 owner 转移使用 Ownable2Step；Wrapper owner 后续变更不会自动同步 Helper。
- 固定使用现有 HourlyTickCalculator，不创建 IPShare，也不收取 IPShare 创建费。
- owner 可登记最多 32 类矿池，最多选择 6 个不同工厂，每项比例必须大于零且在登记上限以内，
  总和严格为 10,000。工厂同时受 Helper 登记和 Committee 白名单双重限制。
- `createCommunityAndPool(token,address(0))` 使用当前默认组合；
  `createCommunityAndPools(token,configs)` 使用完整显式组合，不附加默认池。
- 初始只登记交易策展；可由 owner 启用既有 SocialCurationFactory 并配置例如 70% 交易 / 30% 社交。
- 创建费用为社区创建费 + 设置费 × 实际矿池数，多付 ETH 退回导入者。
- 每次创建新的不可增发 Community，owner / dev 为导入者；不接受复用已有社区。
- Wrapper 已登记的币不能再次导入。任一矿池、登记或退款失败时，整个交易回滚。
- 逐池发出 `ImportedPoolCreated`；兼容 `CommunityCreated` 的 pool 仅为第一个池，
  API/索引不能从它推断社区仅有一个矿池。

### IPShare 与交易手续费（2026-10-12 用户确认）

导入资格不检查导入者是否拥有 IPShare，不自动创建，也不收取 IPShare 创建费。
Helper 将导入者登记为 Wrapper 的 deployer。交易未显式提供 sellsman，或提供零地址 / Wrapper
自身时，部署者是默认手续费接收者：已有 IPShare 则执行 valueCapture；没有 IPShare 则直接
向部署者地址支付对应的 ETH 手续费。显式有效 sellsman 仍按 BSC 的优先级接收佣金。
这一规则只决定部署者 / 推广者佣金，平台手续费和 Nutbox 社区代币奖励仍独立处理。
若直接支付被接收合约拒绝，保留现有 Wrapper 向平台 feeAddress 支付的 fallback。

已核对 RH 与 BSC 的 `_takeFees` / `_resolvedSellsman` 代码，执行逻辑一致。
本次仅补充注释，并修正原注释将零地址 fallback 描述为平台地址的歧义；
实际代码一直优先使用已登记部署者，无需升级或重新部署现有 Wrapper。
既有 Wrapper 回归已覆盖无 IPShare 部署者在买入 / 卖出时直接收款、
已有 IPShare 的 valueCapture，以及拒收 ETH 时的 fallback。

## 复用的主网地址

以下状态在固定区块 **86,435,919** 通过一笔链上 Multicall3 核验；不是实时状态。
证据：[import-helper-v2-preflight.json](../deployments/4663/import-helper-v2-preflight.json)。

| 对象 | 地址 |
| --- | --- |
| 当前旧 Helper | `0xD0baaF8D314b0C6AB6bebd24ddbC86157c9c7b09` |
| ImportedTokenSwapWrapper | `0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab` |
| Wrapper owner / 新 Helper 初始 owner | `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611` |
| CommunityFactory | `0x24328DccA1bA54EeE82e2993F021802e64290486` |
| TradeCurationFactory | `0x73cb7A6Ad01686659F72011eb952fBa53fe6212B` |
| 交易奖励 claimSigner | `0x1C3864ea7a54eC4E3cEb27553A6F2927bBe4222e` |
| Committee | `0x7B0ddC305C32AAEbabc0FE372a4460e9903e95D0` |
| HourlyTickCalculator | `0x3DC52C69C3C8be568372E16d50E9F3FEc796610c` |
| SocialCurationFactory | `0xddbAba530728b5B8939d7fdDC334432490916e90` |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |

交易工厂、计算器的 CommunityFactory 绑定及 Committee 批准均通过；
Wrapper registrar 仍为旧 Helper。旧社区、矿池、奖励、Wrapper、Pump、Hook 和 Router 均不重部署。
Wrapper 从登记记录取得 importer / community，不依赖新 Helper 提供 `importerOf`。

## 与旧 RH Helper 的接口差异

旧 RH Helper 的创建入口是 3/4 参数，包含 calculator、distributionPolicy，且会补建 IPShare。
V2 与 BSC 一致，默认入口改成 2 参数，并提供显式多池入口。
新 Helper 不实现旧 Helper 的 `importerOf`，也没有旧的 Pump getter/创建参数。
RH 旧 Helper 和旧 Wrapper 登记记录不迁移，API 必须保留历史收据 allowlist。

本轮只改合约。启用 V2 前仍需完成 RH API 的 TradeCuration / 多池收据验证和投影，
UI 的新 ABI、固定区块 Multicall 费用计算及增强 Helper 开关切换，
以及 RH 导入币买入事件的索引与奖励 worker 识别。
既有 RH TradeCurationFactory 已被 V14 索引覆盖，但不能因此推断新 Helper / 当前导入 Wrapper
的事件和所有 downstream 路径均已覆盖。索引升级必须沿用精确生产包 continuation，不能重放旧历史。

## 验证

- 新旧 Helper 的 23 项单元测试通过；包括两个各 256 次的 fuzz，默认池、多池比例、费用退款、
  重复导入、owner 权限、工厂禁用/上限/白名单撤销、后续矿池失败和退款失败整笔回滚。
- 连同 ImportedTokenSwapWrapper 和 TradeCuration 的相关本地回归共 72 项通过、0 失败。
- 固定主网区块的 RH fork 使用真实 CommunityFactory、Community implementation、Committee、
  TradeCurationFactory、SocialCurationFactory、HourlyTickCalculator、旧 Helper 和 Wrapper。
  测试币只在本地 fork 创建；奖励签名使用测试密钥，工厂 signer 修改也仅在本地 fork。
  共 4 项通过，覆盖无 IPShare 的默认导入、实际奖励注入/归集/领取、双池默认配置、
  旧导入记录保留，以及部署 preflight 的精确 Multicall 子调用和 registrar 变化拒绝。
- Multicall 脚本回归 4 项通过，验证固定 blockTag、目标及全部子调用、错链/失败/缺失结果拒绝、
  部署后 immutable/owner/default 及 registrar 激活核验。
- 正式部署和 owner 激活已完成并独立核验，浏览器源码验证已由操作员确认；API/UI/索引接入及首次导入交易验收仍待完成。
- 部署脚本在同一固定区块使用显式虚拟密钥 `1`、不带 `--broadcast` 模拟通过，
  仅生成一笔 Helper 创建交易；未将模拟地址保存为正式部署地址。

本地单元测试不使用默认 localhost fork：

```bash
make test-rh-import-helper-v2
```

固定区块 fork：

```bash
FOUNDRY_PROFILE=rh_fork FOUNDRY_ETH_RPC_URL='' RUN_RH_IMPORT_FORK=true \
  forge test --match-contract RHImportHelperV2ForkTest -vv
```

## 部署顺序（操作员每次只执行一个步骤并回传）

1. 确认使用本次 `rh` 源码和已验证的编译配置。新 Helper 可先部署，暂不激活。
2. 在合约仓库 `rh` 分支运行 `make simulate-rh-import-helper-v2`。
   复用既有 `.env` 的 `PRIVATE_KEY`，无需手工输入依赖合约地址；脚本仅允许 chain 4663。
   preflight 在一笔 Multicall 检查 owner、registrar、WETH、工厂、signer、计算器和白名单。
3. 模拟通过后运行 `make deploy-rh-import-helper-v2`；只部署一个 Helper，
   不自动切换 registrar。保存成功部署收据的真实地址、交易/区块与源码提交。
   部署中断时先查收据，不直接重跑创建另一个 Helper。
4. 运行 `make verify-rh-import-helper-v2 HELPER=<真实新地址>` 导出标准 JSON，
   按 [RH 验证流程](RH_CONTRACT_VERIFICATION.md) 在浏览器提交验证。
   该 make 目标不再通过 Blockscout API 提交验证。若验证失败，只重试验证，不重复部署。
5. 用 `node script/verify-rh-import-helper-v2.mjs <真实新地址>` 核验新 Helper 和旧 registrar。
   Node 验证器复用相邻 `tiptag-ui` 已安装的 viem；不加载 `.env`、私钥或钱包。
6. 完成上述 RH API / UI / 索引接入准备后，根据真实新地址生成 owner/Safe 的一笔
   `Wrapper.setRegistrar(newHelper)`，value=0。生产切换以各依赖的实际验收结果为准。
   当前 owner 是上述地址；应先核对实际控制方式，不能把历史 owner 快照称为已确认多签。
   新 Helper 已归该 owner，无需额外 acceptOwnership。
7. owner 激活后使用 `node script/verify-rh-import-helper-v2.mjs <真实新地址> --activated`，
   记录激活收据和新地址，再更新正式部署记录与 API/UI 默认地址。
8. 用小额真实导入、买入、奖励展示及领取验收完整流程。

部署和 owner 激活必须由操作员执行；本次本地 fork / script 模拟不构成主网部署证据。

## 2026-10-12 正式部署记录

- 新 Helper：`0x70eD7C79d80dEDE1828a09B3c526df283111Cb82`。
- 部署交易：`0xc81cbd3a01a156a3697322fc64878f717597bd8de364f0f3533098023e0a44b0`，
  区块 `86448655`，独立 RPC 核验 receipt status = 1。
- 源码提交：`3dcd8443263e80cf4d316e5a137617ed7b86546b`，Solidity 0.8.26 / viaIR / optimizer 200。
- CREATE input 与本地 artifact 的部署字节码及 5 个 constructor 参数完全一致；
  正规化 immutable 区段和编译器 metadata 后，链上运行时代码与本地 artifact 一致。
- 运行时代码 hash：`0xdf9f20e3dd39041d5b2d5a3ced2d49872cfb633ce8f04fc4fd74ed062f96e6d2`。
- Gas used `2080305`，实际支付 `0.00004166850915 ETH`。
- 区块 `86448864` 的固定区块 Multicall：VERSION=2，owner 为
  `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，依赖地址全部正确；
  默认矿池为 RH TradeCurationFactory / 10000 / 空 meta。
- 部署后区块 `86448864` 的快照中，Wrapper registrar 当时仍为旧 Helper
  `0xD0baaF8D314b0C6AB6bebd24ddbC86157c9c7b09`；后续已切换，最新状态见下方启用记录。
- 浏览器验证：2026-10-12 操作员确认已完成，方法为上传 Solidity Standard JSON Input。
- 部署及配置核验证据：[import-helper-v2.json](../deployments/4663/import-helper-v2.json)。
  owner 激活已完成；API/UI/索引接入继续推进，不重复运行部署命令。

### 2026-10-12 Owner 启用记录

- 启用交易：`0x3913b5a2b93524d685ea5f84b0a4f73e1600ba850454ec24d9f575183eb20ad8`，
  区块 `86460900`，独立 RPC 确认 receipt status=1。
- 调用目标：既有 Wrapper `0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab`；
  calldata 对应 `setRegistrar(0x70eD7C79d80dEDE1828a09B3c526df283111Cb82)`，value=0。
- 实际执行者为部署者/owner `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，
  是该账户直接发起的交易，不是 Safe 执行。
- Wrapper 的 `RegistrarChanged` 日志 index=8，确认从旧 Helper 切到新 Helper。
- 区块 `86461283` 固定区块 Multicall 再次确认 registrar、新 Helper owner、immutable 依赖和
  默认交易策展 100%；没有重新部署 Wrapper、工厂或计算器。
- 此次在 API/UI/索引迁移完成之前先执行了 owner 启用。旧 Helper 现在不能登记新币；
  更新应用接入前不能把平台导入功能标记为上线完成。
- 后续先补齐索引的 additive continuation 及导入 Wrapper 事件识别，更新 API 验证和 RH
  默认 Helper 地址、UI ABI/费用/无 IPShare 门槛；完整导入和奖励闭环仍待真实验收。

### Wrapper owner 移交到 RH 多签（2026-10-12，第一步已执行，待多签接收）

用户要求只移交 Wrapper owner。区块 `86464554` 固定区块 Multicall 确认：
Wrapper owner 为 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，pendingOwner 为零；
RH Committee owner 为现有 Safe `0x871fb7006C5964B21695Ba20006021777A26146C`，
Safe 有合约代码，3 个 owner、threshold=2。本次移交模拟由当前 owner 发起，调用通过。

第一步已独立核验：交易 `0x01ef437eee4907ee70e7003517860d16e2364e0bc60eefc7ae4b0a85a4595596`，
区块 `86480489`，receipt status=1，部署账户直接执行 `transferOwnership(Safe)`，value=0。
区块 `86483287` 固定区块 Multicall 确认 pendingOwner=Safe、owner 仍为部署账户、
registrar 仍为新 Helper，Helper owner 仍为部署账户。当前状态为待 Safe 接收，尚未完成所有权移交。

Wrapper 继承 Ownable2Step，移交分两笔：

1. 当前 owner 执行 `Wrapper.transferOwnership(0x871fb7006C5964B21695Ba20006021777A26146C)`，value=0。
   成功后 pendingOwner 变为 Safe，owner 仍为当前部署账户。
2. 核验 pendingOwner 后，由该 Safe 执行 `Wrapper.acceptOwnership()`，value=0。
   核验成功收据及 owner=Safe、pendingOwner=0 后才能记录移交完成。

第一步命令（由操作员执行，交互式输入当前 owner 的私钥）：

```bash
cast send 0x53e65DE68A0eB7f3662579F44Eb9849Ae5cA44ab \
  "transferOwnership(address)" 0x871fb7006C5964B21695Ba20006021777A26146C \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --chain 4663 \
  --from 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611 --interactive
```

预检及状态：[import-wrapper-ownership-transfer.json](../deployments/4663/import-wrapper-ownership-transfer.json)。
第二步 Safe Transaction Builder 文件已准备：
[import-wrapper-accept-ownership.safe.json](../deployments/4663/import-wrapper-accept-ownership.safe.json)，
仅包含一笔 Wrapper `acceptOwnership()`；第一步已核验，可交付操作员通过该 Safe 执行。

Wrapper 和 Helper 的 owner 是独立角色。Wrapper owner 变化不会自动移交 Helper owner；
此次仅处理用户指定的 Wrapper。核验脚本分别记录两者，并按部署记录验证 Helper owner，
不再错误要求移交后两者始终相等。相关 Multicall / owner 分离回归现为 6 项通过。

### Blockscout CLI 验证受阻与浏览器验证记录

2026-10-12 操作员执行源码验证时，`getabi` 返回 Cloudflare `Just a moment...` HTML，
而不是 JSON；独立只读检查亦得到 HTTP 403。该错误发生在浏览器 API 接口，
不是部署失败，也不是编译或字节码不匹配。部署地址和成功收据继续有效。

故障处理时浏览器地址页与验证表单可打开，页面当时显示未验证。
改用 [官方验证页面](https://robinhoodchain.blockscout.com/address/0x70eD7C79d80dEDE1828a09B3c526df283111Cb82/contract-verification)，
选择 `Solidity (Standard JSON input)`、compiler `v0.8.26+commit.8a97fa7a`、license `MIT`，
上传 [标准 JSON 文件](../deployments/4663/import-helper-v2-standard-input.json) 后由操作员提交。
文件含完整 47 份 Solidity 依赖源码及 viaIR / optimizer 200 / Cancun 配置，
不含环境变量、私钥或 API 凭证。参数对应部署源码提交 `3dcd844`。

如需重新导出，在相同源码和配置的合约目录运行：

```bash
FOUNDRY_PROFILE=rh_mainnet forge verify-contract \
  0x70eD7C79d80dEDE1828a09B3c526df283111Cb82 src/helper/ImportHelperV2.sol:ImportHelperV2 \
  --chain 4663 --compiler-version v0.8.26+commit.8a97fa7a --show-standard-json-input \
  > deployments/4663/import-helper-v2-standard-input.json
```

该导出操作不提交验证。操作员随后确认验证成功，当前源码验证记录为已验证，
结果来源标注为 operator confirmation；不将其描述成 agent 独立页面核验。
用户明确要求后续 RH 合约默认使用此方式，已记录至仓库和工作区 AGENTS.md。
不要为解决浏览器 API 拦截重复部署 Helper。
