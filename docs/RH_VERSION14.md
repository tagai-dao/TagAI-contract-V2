# RH V14 合约迁移

## 当前状态（2026-10-08）

用户已完成 RH 主网部署。全量部署核验区块为 `83067092`；治理专项复核区块为 `83075041`，状态是 **多签 4 项授权已生效、4 项所有权接受待收尾**。正式地址见 [version14.json](../deployments/4663/version14.json)。52 个可选成分、53 个价格池、105 条路由均已配置，keeper 与 BSC V14 一致。

多签导入文件为 [safe-rh14-governance.json](../deployments/4663/safe-rh14-governance.json)，包含的 4 项授权均已在链上确认生效，无需重复执行；另外 4 项所有权接受由部署账户执行。下方恢复命令仅用于记录本次部署过程，不应重新执行。

## 范围与兼容

本次代码位于 `rh-version14`，基线 `03ed6b01`，业务迁入参考 BSC `08a5faa5`。新的 `src/v14/RHPumpV14.sol`、`RHTokenV14.sol`、`RHSwapHookV14.sol` 使用独立合约名；V11 的源码、部署记录和旧资产运行逻辑保留。新 Token 使用新模板，不复用 V11 模板。新增 ABI 需要在后续索引、后端和前端阶段接入。

本次不修改 BSC 合约。真实部署由用户执行，代理负责脚本、测试、只读核验和部署记录。

后续 BSC 对照复核与加强测试见 [RH_VERSION14_BSC_PARITY.md](RH_VERSION14_BSC_PARITY.md)：597 项本地通过、3 项 RH fork 通过，并补充全部默认股票、六池冷状态 gas 与 Router 异常路径验证。

## 用户确认的经济参数

- 总量 10 亿：内盘 6.5 亿；V4 主池 1.2 亿；成分 V2 币股池合计 8000 万；Hook / 社区预算 1.5 亿。
- 保留原 RH 曲线系数 `a = 1_624_898_729`、`b = 2.5175516438e26`。实际曲线资金约 **4.9996884819 ETH**，不是严格 5 ETH。
- V4 主池使用全区间 `[-887220, 887220]`、tick spacing 60、原生 LP fee 0。sqrtPriceX96 = `501082896750095862372827603139212`，liquidity = `18973665961010275991993`。实际支付接近 3 ETH / 1.2 亿 Token，受整数取整影响。
- 主池初始现货价格约 **0.025 ETH / 百万 Token**。剩余 ETH（约 1.999688 ETH）全部按权重购入股票，与同权重的 8000 万 Token 配对；初始 V2 LP 铸至 dead 地址。
- 用户明确选择保留旧曲线：末价约 **0.021484 ETH / 百万 Token**，上市理论初价高约 **16.4%**。这是接受的设计，不是价格连续性已修复。
- 币股池价格会受外部股票价格、交易费、购股滑点、实际资金余量及取整影响，不能声称所有池实际价格严格相同。keeper 必须为每腿设置有效 minOut / deadline。
- 最多 4 个成分池 + 2 个可选池；可选池合计最多 8000 bps；剩余奖励按累计舍入分配至 LP 池，合计严格 10000 bps。社区保留 owner 时，owner 仍有原 Community 的后续调池权限。

## Router 扩展边界

### NutboxRouter

- `setV2Router(factory, router, enabled)`：验证 Factory 与 WETH，登记/停用 V2 执行器。
- `setV3Router(factory, router, enabled)`：每个 Factory 单独绑定执行器，支持与 `exactInputSingle` 无 deadline 参数元组兼容的 SwapRouter02 风格接口。旧 `pancakeV3Router` / `pancakeV3Factory` getter 只代表初始配置。
- `setUniswapV4Manager(manager, enabled)`、`setPancakeV4Manager(manager, enabled)`：新增/停用已支持协议类型的 Manager。合约代码存在不代表自动可信，只由 owner 注册审查后的地址。
- `addOperator` / `removeOperator`：允许受信任 Pump 新增包含其 `createdTokens` 的池和端点路由。替换或删除已有共享池/路由仍仅 owner 可执行。所有 DEX 配置仍仅 owner。
- 新的 `NutboxPriceReader` 在 Router 构造中自动部署，承担读取与来源校验，避免 Router 超过 EIP-170 大小限制。它无资金托管和管理员权限。
- 支持已实现的 V2 / V3 / Uniswap V4 / Infinity CL 调用协议；完全不同的未来协议仍需要代码适配，不能仅白名单添加就自动兼容。

### TagAITradeRouter / TagAILiquidityRouter

- TradeRouter 用 `setPump(pump, enabled)` 登记兼容 Pump。通过 Token `getPump()` 与可信 Pump `createdTokens(token)` 双向验证，O(1) 查询，不逐个扫描历史 Pump。
- `setFactory(factory, feeBps, enabled)` 登记兼容 Uniswap V2 风格成分池 Factory 与实际费率；初始 RH Factory 为 30 bps。
- Token 自己的 `listingInfrastructure()`、`listingHook()`、`v4PoolId()`、`pancakeV2Factory()` 和 `componentAt()` 决定实际交易目标。管理者登记新 Pump 不会改写旧 Token 的池绑定。
- 保留 `pump()`、`pancakeV2Factory()` 等初始配置 getter 供兼容；LiquidityRouter 的实际准入也使用 TradeRouter 注册表，而非初始 Pump。
- LP 配比读取 Token 的 `COMPONENT_POOL_TAX_BPS()`，支持相同扣税规则下的新税率。复杂税种或不同 LP 机制不属于配置兼容范围。
- 回调来源与数据哈希单次认证；交易按余额差检查净到账、minOut、deadline、退款；不消费预存资金。
- 本轮保持固定 NutboxRouter 引用。新 Pump 需使用该共享 Router，且保留上述 Token 接口，才能只通过注册接入。

### BasketSwapRouter / TagAIBuybackRouter

按用户要求保持与 BSC 同类的版本绑定方式。BuybackRouter 绑定一个 Pump、一组指数买入基础设施；未来版本配套重部署，不增加通用指数适配层。

RH Basket V3 已支持 V2 成分、扣税后的净到账和 `createBasketFor`，因此复用现有 `robinhood-basket-contract` 业务源码及 V3 TokenDeployer。新部署 Executor / Hook / BasketSwapRouter，仅将其不可变的 bridgeRouter 绑定到新 NutboxRouter；没有把 Basket 版本号伪装成 V4。Pump 中 `basketHookV4` 字段名仅保留 BSC ABI 命名，RH 校验版本 3 和实际基础设施。

## 部署准备

`script/DeployRHPump14.s.sol`：

1. 从 RH `version11.json` 与 Basket `version3.json` 读取已有基础设施，运行时检查代码存在。
2. owner 读取现有 RH Pump，signer 读取 RH SocialCurationFactory。显式提供 `RH14_DEPLOYER`；listing keeper 已按用户确认设为合约默认值 `0x8047FcC508446E2673195B8125d3388defc23688`，与 BSC V14 相同，无需 `RH14_LISTING_KEEPER`。部署脚本不再覆盖该默认值，owner 后续仍可调用 `adminSetListingKeeper` 更换。
3. 部署新 NutboxRouter（含 PriceReader）、绑定它的 Basket Executor / Hook / SwapRouter、新 Pump / Token 模板 / Hook、TradeCurationFactory、新三个业务 Router。
4. 从 `RHVersion14StockConfig` 每组最多 16 项批量初始化 Router：53 个价格池用 4 笔、105 条双向路由用 7 笔。52 个成分白名单（50 个股票代币及 SPY/QQQ）由 Pump 构造函数一次写入，并检查完整 initcode 不超过 EIP-3860 的 49,152 字节限制。当前清单下，全新部署合计 32 笔交易。配置新实例内部关系、Pump operator 和可选矿池。发起 Pump、NutboxRouter、TradeRouter、TradeCurationFactory 的两步 owner 转移。
5. 输出待多签执行的目标和 calldata：Committee 白名单、Basket registrar / forwarders、四项 `acceptOwnership()`。

模拟不会改写 `version11.json` 或把预测地址记为已部署。生产 `version14.json` 应在实际交易 receipt 成功并核验代码、角色后记录；未完成多签接入前不能切换生产入口。

```bash
# 先在 robinhood-basket-contract 构建与源码匹配的部署产物
forge build --skip test --skip script

# 回到 TagAI-contract-V2，本地测试不依赖网络
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*'

# 更新股票目录与池子 TVL，再核验链上身份并生成固定部署清单（只读）
python3 script/fetch-rh14-stocks.py
node script/prepare-rh14-stocks.mjs
# Node 脚本复用 ../tiptag-ui 的 viem；其他环境可用 RH14_NODE_PACKAGE 指向装有 viem 的 package.json。

# 只读 fork：默认使用生成清单的验证区块；本地模拟授权，不提交多签交易
# 公共 RPC 若已裁剪历史状态，使用 RH14_FORK_BLOCK 指定可访问的新区块。
RUN_RH14_FORK=true FOUNDRY_ETH_RPC_URL='' forge test --match-contract RHVersion14ForkTest -vv

# 主网状态部署模拟；显式设置 RH14_DEPLOYER，不加 --broadcast
FOUNDRY_PROFILE=rh_fork forge script script/DeployRHPump14.s.sol:DeployRHPump14Script \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

股票选择和池子深度依据见 [RH_VERSION14_STOCKS.md](RH_VERSION14_STOCKS.md)。TVL 是官方接口采集时的美元总锁仓量，并非保证可成交 5 万美元的盘口深度。构造和初始化不调用外部 HTTP 接口；部署使用已核验清单。`run()` 拒绝超过 24 小时的快照，部署前运行上面的刷新和验证命令，再检查清单 diff、执行 fork 测试。门槛不是部署后持续执行的链上美元规则，后续增删仍由 owner 配置。

## 验证边界

`test/v14/` 使用真实 Uniswap V4 PoolManager、Pump、Token、Hook、NutboxRouter、Nutbox 社区和矿池；外部股票 V3 成交和指数在部分本地测试中使用 doubles。V2 double 验证 30 bps 常数乘积约束及 LP 记账。`test/fork/RHVersion14Fork.t.sol` 单独验证真实股票、V2 Factory、既有 Nutbox 与未改业务逻辑的 Basket。

新增 TradeCuration 单元、恶意回调及长期账务 invariant 测试复用 BSC 的对应测试向量，在 RH 仓库的现有 Nutbox 合约上运行。不能把本地 mock 通过视为真实主网验证，也不能把 fork 内模拟 owner 授权描述为主网已授权。

## 首轮迁移验证记录（2026-09-30）

- 完整本地回归：39 个测试套件，**542 通过、0 失败、2 跳过**；跳过的是默认关闭的两项旧 RH fork 测试。新增 RH V14 的主网 fork 测试单独执行并通过。
- RH 主网区块 `76263063` 的 fork 生命周期测试通过：真实 NVDA / TSLA 购股、V2 成分池上市、V4 主池买卖、回购、指数首次铸造及 BasketSwapRouter 卖出。授权在本地 fork 中模拟。
- 同一区块的首轮完整部署脚本模拟通过，没有 `--broadcast`。该历史模拟使用 `0x0000000000000000000000000000000000001234` 作为 keeper 占位值；2026-10-08 按用户确认已改为合约内置 BSC V14 keeper，最新部署不再使用占位值或外部 keeper 参数。
- 本地覆盖最大 4 个成分池 + 2 个可选矿池、失败上市原子回滚后重试、多 Pump / 多 Factory 接入、权限隔离及 256 轮奖励分配 fuzz。
- 已导出 9 份公共 ABI 到 `abis/rh-version14/`；编译后可用 `python3 script/export-rh14-abis.py` 重建。

当前编译产物的运行时代码大小如下，均低于 EIP-170 的 24,576 字节上限；测试同时检查 Pump 构造时写入 52 个成分和 Router 分组初始化的 initcode 不超过 49,152 字节。Pump 完整 initcode 为 48,019 字节。Token 剩余空间仅 410 字节，后续增加功能需继续检查大小。

| 合约 | 运行时代码（字节） |
| --- | ---: |
| RHPumpV14 | 21,048 |
| RHTokenV14 | 24,166 |
| RHSwapHookV14 | 8,330 |
| NutboxRouter（新增批量接口） | 22,736 |
| NutboxPriceReader | 6,075 |
| TagAITradeRouter | 15,730 |
| TagAILiquidityRouter | 9,205 |
| TagAIBuybackRouter | 3,438 |

## 2026-10-08 部分部署恢复

首次 231 笔计划因 RPC Cloudflare 403 中断，已有 154 笔成功。链上已确认 Router `0xfc82178523687Edd56F7474d6529a14F7655Ab15`、53 个池和 100 条路由，其余合约尚未部署。原记录与复核结果保存在 `deployments/4663/rh14-recovery/`。

本次改用 `script/ResumeRHPump14.s.sol:ResumeRHPump14Script`，复用该 Router，补齐 5 条路由，Pump 构造时批量写入 52 个成分；合计剩余 25 笔。已部署 Router 不包含后来新增的批量接口，因此仅剩的 5 条路由仍单笔添加；其原源码、编译产物已归档，可用于后续验证，不能用新增批量接口后的 Router 字节码冒充链上实现。

续跑前校验部署账户 nonce=332、Router codehash/owner/pendingOwner、冻结的配置哈希及每条已存在的池和路由。当前恢复计划不刷新股票配置，防止改变已完成的初始化。先模拟新的恢复脚本，不使用原 231 笔计划的 `--resume`；如果新的恢复脚本广播后再次中断，只对 **ResumeRHPump14Script** 使用 `--resume`，避免重复部署后续合约。

```bash
cd '/Volumes/Extreme Pro/wangxi/work/tiptag/TagAI-contract-V2'
export RH14_DEPLOYER=0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611
export RH14_RPC_URL=https://rpc.mainnet.chain.robinhood.com

# 先模拟，不广播。必须使用原部署账户，且不要刷新被冻结的股票清单。
env -u FOUNDRY_ETH_RPC_URL FOUNDRY_PROFILE=rh_fork \
  forge script script/ResumeRHPump14.s.sol:ResumeRHPump14Script \
  --rpc-url "$RH14_RPC_URL" --sender "$RH14_DEPLOYER" -vv

# 模拟通过后执行；--interactive 输入原部署账户的私钥。
env -u FOUNDRY_ETH_RPC_URL FOUNDRY_PROFILE=rh_fork \
  forge script script/ResumeRHPump14.s.sol:ResumeRHPump14Script \
  --rpc-url "$RH14_RPC_URL" --sender "$RH14_DEPLOYER" \
  --broadcast --interactive --slow -vv
```

若本次恢复广播再次中断，在最后一条命令增加 `--resume`，不要重新执行第一条模拟命令覆盖恢复计划。不要对旧的 `DeployRHPump14Script` 使用 `--resume`。24 小时快照过期或 nonce 校验失败时，应重新核对链上进度和冻结清单，不应绕过检查。

本轮批量化本地回归：42 套测试，607 通过、0 失败、2 跳过；覆盖批量权限、非法条目整批回滚、路由引用回滚及 16 项批次。另外，区块 `83020129` 的三项 RH fork 测试全部通过，覆盖批量部署后 52 个成分往返交易及上市生命周期。恢复脚本编译通过；早期主网恢复模拟曾因公共 RPC Cloudflare HTTP 403 中断，随后用户完成模拟和正式广播，最终结果见下方部署核验记录。


## 2026-10-08 部署完成核验

恢复脚本的 25 笔交易均已由链上 receipt 确认成功，没有 pending 交易。正式地址保存至 `deployments/4663/version14.json`，恢复广播归档至 `deployments/4663/rh14-recovery/completed-broadcast.json`。不要再次运行部署或恢复广播。

在区块 `83067092` 只读核验：12 个合约地址均有代码，Pump 的 52 个股票/ETF 成分已批准，Router 的 53 个池和 105 条路由与冻结清单一致，keeper 为 `0x8047FcC508446E2673195B8125d3388defc23688`，Pump 的 Router/Hook/Buyback/Basket 绑定、Router operator 和 TradeRouter Pump 准入均符合预期。

部署初次核验时有 8 项待办；区块 `83075041` 专项复核确认前 4 项多签授权已完成，尚有 4 项所有权接受，记录状态仍为 `deployed-governance-pending`。完整 target/data/executor 及逐项完成状态已保存至 `deployments/4663/rh14-governance.json`：

- Committee 与 BasketRegistry 的 owner `0x871fb7006C5964B21695Ba20006021777A26146C`：1 项 Committee 白名单和 3 项 Basket 授权，均已生效。
- Pump、NutboxRouter、TradeRouter、TradeCurationFactory 的 pendingOwner `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`：4 项 `acceptOwnership()`。此处接收方与原部署者相同，不能假定是上述 Committee 管理账户。

核验脚本不签名、不广播。完成治理后，可再次运行 `node script/verify-rh14-deployment.mjs` 更新权限状态；可通过 `RH14_RPC_URL` 指定 RPC。本次治理专项复核未重新完成全量路由验证，部署记录保留原全量核验区块，并单独记录 `governanceVerifiedBlock`。链上 Router 沿用首次部署的旧实现，不支持本轮源码新增的批量初始化接口；验证其源码应使用归档的原始产物。

### Safe 导入文件与后续操作

`deployments/4663/safe-rh14-governance.json` 使用 Safe Transaction Builder 格式，chainId 为 `4663`，多签为 `0x871fb7006C5964B21695Ba20006021777A26146C`。包含：

1. Committee 批准新 TradeCurationFactory。
2. BasketRegistry 批准新 BasketHookV3 为 registrar。
3. BasketRegistry 批准 Pump V14 为 creator forwarder。
4. BasketRegistry 批准新 BasketSwapRouter 为 creator forwarder。

所有调用 value 为 0；导出 calldata 已与 ABI 重新编码比对，并通过从该多签地址发起的逐项 `eth_call` 模拟。这不是整批 MultiSend 执行回执；文件未由代理提案、签署或广播。用户已执行多签，区块 `83075041` 查询确认这 4 项授权状态均为 true；这是授权状态核验，不是多签交易哈希归档。

`acceptOwnership()` 的 pendingOwner 是部署账户，因此不包含在多签文件中；部署账户需分别对 Pump、NutboxRouter、TagAITradeRouter、TradeCurationFactory 执行。区块 `83075041` 的 owner 与 pendingOwner 均为该部署账户，因此这些调用仅完成对自身的转移、清除 pendingOwner，现有 owner 权限已经有效。前端、后端和索引接入仍按后续迁移计划推进。

当前 `abis/rh-version14/NutboxRouter.json` 对应已部署 Router 的接口。重新运行通用 ABI 导出脚本会导出最新源码新增的批量接口，不能据此认为现有链上 Router 也具备这些接口。其归档源码和产物位于 `deployments/4663/rh14-recovery/original-NutboxRouter.*`。
