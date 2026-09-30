# RH V14 合约迁移

## 范围与兼容

本次代码位于 `rh-version14`，基线 `03ed6b01`，业务迁入参考 BSC `08a5faa5`。新的 `src/v14/RHPumpV14.sol`、`RHTokenV14.sol`、`RHSwapHookV14.sol` 使用独立合约名；V11 的源码、部署记录和旧资产运行逻辑保留。新 Token 使用新模板，不复用 V11 模板。新增 ABI 需要在后续索引、后端和前端阶段接入。

本次不修改 BSC 合约，也不广播真实链上交易。

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
2. owner 读取现有 RH Pump，signer 读取 RH SocialCurationFactory。必须显式提供 `RH14_DEPLOYER`、`RH14_LISTING_KEEPER`；不沿用 BSC keeper 地址。
3. 部署新 NutboxRouter（含 PriceReader）、绑定它的 Basket Executor / Hook / SwapRouter、新 Pump / Token 模板 / Hook、TradeCurationFactory、新三个业务 Router。
4. 配置新实例内部关系、Pump operator 和可选矿池。发起 Pump、NutboxRouter、TradeRouter、TradeCurationFactory 的两步 owner 转移。
5. 输出待多签执行的目标和 calldata：Committee 白名单、Basket registrar / forwarders、四项 `acceptOwnership()`。

模拟不会改写 `version11.json` 或把预测地址记为已部署。生产 `version14.json` 应在实际交易 receipt 成功并核验代码、角色后记录；未完成多签接入前不能切换生产入口。

```bash
# 先在 robinhood-basket-contract 构建与源码匹配的部署产物
forge build --skip test --skip script

# 回到 TagAI-contract-V2，本地测试不依赖网络
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*'

# 只读 fork：默认固定 RH 区块 76263063；本地模拟授权，不提交多签交易
# 公共 RPC 若已裁剪历史状态，使用 RH14_FORK_BLOCK 指定可访问的新快照；本轮复核为 76298453。
RUN_RH14_FORK=true FOUNDRY_ETH_RPC_URL='' forge test --match-contract RHVersion14ForkTest -vv

# 主网状态部署模拟；显式设置上述两个公开角色地址，不加 --broadcast
FOUNDRY_PROFILE=rh_fork forge script script/DeployRHPump14.s.sol:DeployRHPump14Script \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

## 验证边界

`test/v14/` 使用真实 Uniswap V4 PoolManager、Pump、Token、Hook、NutboxRouter、Nutbox 社区和矿池；外部股票 V3 成交和指数在部分本地测试中使用 doubles。V2 double 验证 30 bps 常数乘积约束及 LP 记账。`test/fork/RHVersion14Fork.t.sol` 单独验证真实股票、V2 Factory、既有 Nutbox 与未改业务逻辑的 Basket。

新增 TradeCuration 单元、恶意回调及长期账务 invariant 测试复用 BSC 的对应测试向量，在 RH 仓库的现有 Nutbox 合约上运行。不能把本地 mock 通过视为真实主网验证，也不能把 fork 内模拟 owner 授权描述为主网已授权。

## 首轮迁移验证记录（2026-09-30）

- 完整本地回归：39 个测试套件，**542 通过、0 失败、2 跳过**；跳过的是默认关闭的两项旧 RH fork 测试。新增 RH V14 的主网 fork 测试单独执行并通过。
- RH 主网区块 `76263063` 的 fork 生命周期测试通过：真实 NVDA / TSLA 购股、V2 成分池上市、V4 主池买卖、回购、指数首次铸造及 BasketSwapRouter 卖出。授权在本地 fork 中模拟。
- 同一区块的完整部署脚本模拟通过，没有 `--broadcast`。模拟使用 `0x0000000000000000000000000000000000001234` 作为 keeper 占位值；实际部署必须改为正式 keeper。
- 本地覆盖最大 4 个成分池 + 2 个可选矿池、失败上市原子回滚后重试、多 Pump / 多 Factory 接入、权限隔离及 256 轮奖励分配 fuzz。
- 已导出 9 份公共 ABI 到 `abis/rh-version14/`；编译后可用 `python3 script/export-rh14-abis.py` 重建。

当前编译产物的运行时代码大小如下，均低于 EIP-170 的 24,576 字节上限；测试同时检查包含 9 个股票构造参数的 Pump initcode 不超过 49,152 字节。Token 剩余空间仅 410 字节，后续增加功能需继续检查大小。

| 合约 | 运行时代码（字节） |
| --- | ---: |
| RHPumpV14 | 21,048 |
| RHTokenV14 | 24,166 |
| RHSwapHookV14 | 8,330 |
| NutboxRouter | 21,973 |
| NutboxPriceReader | 6,075 |
| TagAITradeRouter | 15,730 |
| TagAILiquidityRouter | 9,205 |
| TagAIBuybackRouter | 3,438 |
