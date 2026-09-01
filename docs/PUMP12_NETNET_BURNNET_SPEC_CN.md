# Pump12 × NetNet × BurnNet 机制规范

> 状态：设计冻结稿，尚未实现或部署
>
> 首发网络：Robinhood Chain 主网（chain ID `4663`，Arbitrum Orbit L2，ETH gas）
>
> 计价资产：Robinhood Chain 官方 Global Dollar（USDG，`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`，6 decimals）
>
> 官方 DEX：Robinhood Chain Canonical Uniswap v4（PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`）
>
> 适用范围：仅适用于未来通过 Pump12 创建的新 Token，不改变既有 Pump V9/V11 Token

## 1. 设计目标

Pump12 将 TagAI 的 Bonding Curve 冷启动机制与 NetNet 的受控发行机制、Hooked Bitcoin 风格的 BurnNet 防御网组合为一套独立发行平台：

1. 用户在内盘通过 Pump9 同形的指数 Bonding Curve 完成冷启动；
2. 内盘卖出 `750,000,000` Token，净筹集 `15,000 USDG`；
3. 上市时使用 `15,000 USDG + 250,000,000 Token` 创建 Uniswap v4 全域流动性；
4. 基础 LP fee 为零，全部官方池交易费由 Hook 以 USDG 收取；
5. 上市后平台、创建者和 BurnNet 按固定比例分配 Hook 手续费；
6. BurnNet 每8小时最多执行一次 `poke()`，在 anchor 下方布置分层 USDG 买单，成交获得的 Token 在结算时销毁；
7. Treasury 是上市后唯一 Token minter，Distributor、BondDepository、PremiumSeller 和 pTEAM 只能在各自固定边界内请求增发；
8. 不使用 Nutbox，不使用 NetNet 的 Morpho（全部进入回购墙）、InverseBond（回购墙自动回购销毁）、TaxCollector（v4池直接收取了usdg） 或 RFV/NAV（没有国库了，只有回购墙和后续的RWA金库） 会计；本协议只复用 USDG 作为计价和结算资产；
9. Anchor 是货币政策和 BurnNet 的参考价格，不是兑付承诺，也不代表可赎回 NAV；
10. 非官方池不收取 Hook 手续费，协议依靠官方池的永久流动性深度集中主要交易量；
11. Distributor 的 USDG 型信用只来自官方池交易费中进入 BurnNet 的份额，并永久按 `initialAnchor` 折算；其他资金只能增强回购墙。

## 2. 核心术语


| 术语                      | 含义                                                                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 内盘                      | Token 上市前，由 Pump12 Bonding Curve 执行的买卖市场                                                                                |
| 官方池                     | Pump12 上市时创建的唯一受支持 Token/USDG Uniswap v4 池                                                                              |
| 基础 POL                  | 上市时创建的 `250M Token + 15,000 USDG` 全域、零 LP fee、永久锁定仓位                                                                    |
| Anchor                  | BurnNet 分层挂单和 NetNet 参数调节共同使用的参考价格                                                                                      |
| Generation              | 使用同一个 anchor 和七档区间的一代 BurnNet 仓位                                                                                        |
| Pending USDG            | 已归属于指定 poolId、但尚未部署进回购仓位的 USDG；必须按交易费来源与其他来源分账                                                                          |
| Active reserve USDG     | 已归属于指定 poolId、已经过有效 poke 结算并投入当前 BurnNet generation 的 USDG 储备本金；不包括 Pending USDG                                        |
| Eligible trade-fee USDG | 上市后由官方池真实 swap 收取、完成 TagAI/创建者分成后实际划入 BurnNet 的手续费 USDG；这是唯一能产生 USDG 型 Distributor credit 的资金来源                         |
| Reserve snapshot        | 有效 poke 在完成结算、销毁、anchor 更新和 pending 激活后，为指定 poolId 分别封存 Active reserve 总额、其中 Eligible trade-fee USDG、anchorVersion 和时间戳 |
| Distributor credit      | Distributor 还可向质押者增发的 Token 数量额度                                                                                        |
| 实际销毁                    | BurnNet 已经获得 Token 并成功调用 Token `burn()`；仓位中尚未结算的 Token 不属于实际销毁                                                          |


## 3. 固定经济参数

### 3.1 发行与上市


| 参数                  | 固定值                   |
| ------------------- | --------------------- |
| Bonding Curve 售卖量   | `750,000,000 Token`   |
| Bonding Curve 净筹资目标 | `15,000 USDG`         |
| 基础全域 LP Token       | `250,000,000 Token`   |
| 基础全域 LP USDG        | `15,000 USDG`         |
| 上市初始总供应量            | `1,000,000,000 Token` |
| Token decimals      | `18`                  |
| USDG decimals       | `6`                   |
| 原生 LP fee           | `0`                   |
| Tick spacing        | `60`，实现标定时确认          |
| Listing fee         | `0`                   |
| Nutbox 分配           | `0`                   |


Robinhood Chain 固定基础设施：


| 参数                         | 地址/数值                                        |
| -------------------------- | -------------------------------------------- |
| Chain ID                   | `4663`                                       |
| Native gas                 | `ETH`                                        |
| Canonical USDG             | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap v4 PoolManager     | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Uniswap v4 PositionManager | `0x73991a25c818bf1f1128deaab1492d45638de0d3` |


### 3.2 时间参数


| 参数                          | 固定值                   |
| --------------------------- | --------------------- |
| BurnNet heartbeat / poke 间隔 | `8 hours`             |
| Anchor 单次正常最大涨幅             | `8%`                  |
| Anchor 向下重启后的 mint 冻结       | `24 hours`            |
| pTEAM 首次可执行时间               | `listTime + 24 hours` |
| Distributor epoch           | `8 hours`             |
| Bond vest                   | `2 days`              |
| pTEAM vest                  | `30 days`             |
| PremiumSeller 最小执行间隔        | `1 hour`              |


### 3.3 费率参数


| 参数                    | 范围/固定值                     |
| --------------------- | -------------------------- |
| 创建者设置的总交易费 `f`        | `1%–10%`                   |
| TagAI 分成              | 总手续费的 `10%`                |
| 创建者分成 `c`             | 总手续费的 `0%–30%`             |
| 上市后 BurnNet 分成        | 总手续费的 `90% - c`            |
| Distributor USDG 信用来源 | 仅官方池 Hook fee 的 BurnNet 份额 |
| Distributor USDG 折算价  | 固定 `initialAnchor`         |


`f` 和 `c` 在 Token 创建时确定。费率和分成比例对该 Token 永久冻结；创建者只能按受控流程更换收款地址，不能提高费率或分成比例。

## 4. Pump9 同形 Bonding Curve

### 4.1 曲线公式

Pump12 沿用 Pump9 的指数曲线形式：

```text
边际价格：
p(s) = a × exp(s / b)

从供应量 s 买入 Δ Token 的净成本：
cost(s, Δ)
= a × b × [exp((s + Δ) / b) - exp(s / b)]
```

其中 `s` 和 `Δ` 是已经从 Bonding Curve 售出的 Token 数量。

Pump9 在售卖 `650M` Token 时使用：

```text
b_old = 251,755,164.38 Token
650M / b_old ≈ 2.58187355
结束价 / 起始价 ≈ 13.22188684
```

Pump12 将 `b` 按售卖量从 `650M` 等比例调整到 `750M`，保持 Pump9 的归一化曲线形状：

```text
b_new
= b_old × 750M / 650M
≈ 290,486,728.13076925 Token
```

再根据总净成本恰好等于 `15,000 USDG` 反解 `a`：

```text
a
= 15,000 /
  [b_new × (exp(750M / b_new) - 1)]
≈ 0.000004224999928192 USDG
```

### 4.2 目标价格

使用上述人类可读近似参数：


| 项目         | 价格                         |
| ---------- | -------------------------- |
| 起始边际价格     | `≈ 0.000004224999928 USDG` |
| 曲线结束边际价格   | `≈ 0.000055862470929 USDG` |
| 初始 Anchor  | `≈ 0.000055862470929 USDG` |
| DEX 上市价格   | `0.000060000000 USDG`      |
| 上市价相对曲线结束价 | `≈ +7.4066%`               |


DEX 上市价格由固定的初始资产比例得到：

```text
15,000 USDG / 250,000,000 Token
= 0.00006 USDG/Token
```

初始估值：

```text
750M 内盘 Token 上市市值 = 45,000 USDG
初始 FDV                  = 60,000 USDG
初始池子 TVL             = 30,000 USDG
```

### 4.3 实现期整数标定要求

上述 `a`、`b` 和价格是设计层近似值，不得直接作为未经验证的部署常量。Token 使用18 decimals，USDG 使用6 decimals；价格、Anchor 和 TWAP 在协议内部统一归一化为18-decimal WAD（每枚完整 Token 对应的 USDG），实际收付款再转换成 USDG raw units。实现必须重新进行混合 decimals 的整数求解和 Foundry 测试，使以下条件在允许的最小舍入误差内成立：

```text
costRawUSDG(0, 750_000_000e18) == 15_000e6

usdgWad = usdgRaw6 × 1e12
tokenCreditRaw18 = usdgRaw6 × 1e30 / anchorWad18
```

所有 USDG 债务和手续费必须保留6位原子精度并采用有利于协议偿付能力的一致舍入方向，不能沿用旧链18位计价资产的 raw 常量。前端不得按18 decimals 格式化 USDG。

同时必须离线求出并验证：

- Token/USDG 实际地址排序；
- `sqrtPriceX96`；
- 对齐 tick spacing 后的全域 `tickLower/tickUpper`；
- 使用 `250M Token + 15,000 USDG` 时的准确 liquidity delta；
- Curve 最后一笔 fill-to-cap 的退款、手续费和 rounding 行为。

## 5. Token 创建与初始供应

创建 Token 时必须同时提供：

1. Token 名称、符号和 salt；
2. 总交易费 `f`，范围 `1%–10%`；
3. 创建者手续费分成 `c`，范围 `0%–30%`；
4. 创建者收款地址；
5. 从 TagAI 官方 `IndexRegistry` 中选择的指数 Token ID；
6. pTEAM 固定 holder/团队地址。

Token 初始化时一次性预铸：

```text
750M Bonding Curve allocation
+ 250M base POL allocation
= 1.0B initial supply
```

内盘期间不存在任何可被外部调用的增发入口。Pump12 只能销售已经预铸的 `750M` Curve allocation。

Token 不使用 fee-on-transfer。钱包转账和非官方池交易不收 Token 层税。

## 6. 内盘交易与手续费

内盘只实际收取 TagAI 和创建者分成，不收取未来属于 BurnNet 的部分。

设：

```text
f = 创建者设置的总交易费率
c = 创建者在总手续费中的分成比例
```

内盘每笔买卖的实际费用：

```text
TagAI fee  = quoteAmount × f × 10%
Creator fee = quoteAmount × f × c
Inner total fee = quoteAmount × f × (10% + c)
```

理论上属于 BurnNet 的：

```text
quoteAmount × f × (90% - c)
```

在内盘不扣取，继续作为用户 Bonding Curve 交易本金。

买入时，扣除实际内盘手续费后的 USDG 进入曲线；卖出时，从曲线毛退款中扣除实际内盘手续费。Curve 完成条件以净 Curve reserve 达到 `15,000 USDG` 且 `750M` allocation 全部售完为准，不以用户历史毛支付额为准。

TagAI 不额外收取上架费，全部 `15,000 USDG` 净 Curve reserve 用于创建官方池基础 POL。

## 7. 原子 Listing

达到 Curve 终点后，Listing 必须在同一笔原子交易中完成：

```text
1. 永久关闭Bonding Curve买卖
2. 固定curveEndPrice并设置initialAnchor
3. 创建每Token独立的Treasury和BurnNet模块
4. 初始化Token/USDG官方Uniswap v4池
5. 添加250M Token + 15,000 USDG全域基础POL
6. 将基础POL永久锁定/等效销毁
7. 注册Hook的poolId和Token配置
8. 初始化TWAP observation
9. 将上市后唯一mint权限交给Treasury
10. 永久撤销Pump12的供应控制
11. 设置listTime并启动8小时heartbeat
```

任何一步失败，整笔 Listing 回滚。迁移交易本身不收内盘费或 Hook 费。

## 8. 基础全域 POL

### 8.1 永久性

Uniswap v4 的核心流动性仓位不是可以简单发送到黑洞地址的 ERC-20 LP Token。因此“LP 销毁”实现为经济等效的永久锁定：

- 基础仓位由不可升级的 `PermanentLiquidityVault` 创建并持有；
- 仓位使用已知 owner、全域 ticks 和固定 salt；
- 合约不提供减少、提取、转移基础 liquidity 的方法；
- 没有 owner 或管理员可以取走基础仓位；
- 基础 LP fee 为零，不需要保留领取 LP fee 的能力。

只有 `250M + 15,000 USDG` 的基础 POL 永久锁定。BurnNet 七档仓位必须由 BurnNet 控制，以便 poke、harvest、结算、销毁和迁移 generation。

### 8.2 当前 Token 库存

V4 没有 V2 `getReserves()`。协议使用以下方式计算基础 POL 当前包含的 Token 数量：

```text
sqrtPrice = StateLibrary.getSlot0(UniswapV4PoolManager, poolId).sqrtPriceX96
liquidity = StateLibrary.getPositionInfo(
    UniswapV4PoolManager,
    poolId,
    PermanentLiquidityVault,
    fullRangeLower,
    fullRangeUpper,
    BASE_LP_SALT
).liquidity

polTokenInventory = SqrtPriceMath计算出的当前Token侧数量
```

不得使用 `token.balanceOf(PermanentLiquidityVault)`、PoolManager 聚合余额或 PositionManager NFT 余额代替该固定 position 的流动性，也不得把外部 LP 或 BurnNet 仓位计入 PremiumSeller clip 基数。

## 9. 上市后 Hook 手续费

官方池原生 LP fee 固定为零。Hook 对官方池买卖统一按 USDG 侧毛金额收取创建时固定的总费率 `f`：

```text
TagAI      = grossQuote × f × 10%
Creator    = grossQuote × f × c
BurnNet    = grossQuote × f × (90% - c)
Total fee  = grossQuote × f
```

买入时从 USDG 输入中扣费，剩余 USDG 执行 swap；卖出时从池子毛 USDG 输出中扣费，用户收到净 USDG。

第一版只支持 exact-input；exact-output 必须 revert，避免 quote fee 和 V4 delta 结算产生歧义。Token/USDG 地址排序不得硬编码，Hook 必须按 PoolKey 动态识别 quote 方向。

Robinhood 版本必须基于 Uniswap v4 Hook ABI 实现，而不是复用 Pancake Infinity 的 `ICLHooks/IVault` 回调：

- USDG exact-input 买入：在 swap 前从指定 USDG 输入中收取 Hook delta，只允许净额进入池子；
- Token exact-input 卖出：根据实际 USDG 毛输出在 swap 后收取 Hook delta，用户只取得净额；
- Hook 地址权限位必须与实际 `beforeSwap`/`afterSwap` 及 returns-delta 回调完全一致；
- 所有 delta 都在 canonical PoolManager 的 unlock/settle/take 会计内结清，不存在 Pancake Infinity Vault；
- 手续费先用18位中间精度计算，再按 USDG 6 decimals 采用固定舍入规则落账，且三方分账之和必须等于实际收取 raw amount。

手续费分配采用内部应收账款/拉取领取模式，不在 swap callback 中向任意创建者合约执行可能失败的外部调用。每个 poolId 的平台、创建者和 BurnNet 账本完全隔离。

Hook 只对 Pump12 注册的官方池收费。外部创建的 V2/V3/V4 池不收费，协议不承诺阻止手续费旁路。

只有上式中的 `BurnNet` 手续费份额属于 Eligible trade-fee USDG。swap 的交易本金、池子输出的毛 USDG、TagAI/创建者份额均不得计入 Distributor 信用。

### 9.1 外部注入 Pending USDG

共享 Hook 提供 permissionless 资金注入入口。任何地址都可以给指定的已注册官方 `poolId` 增加 BurnNet 资金：

```solidity
function addPendingUSDG(PoolId poolId, uint256 amount)
    external
    returns (uint256 received);
```

语义：

```text
调用者USDG
→ Shared Hook
→ pendingUSDG[poolId] += 实际收到数量
```

固定规则：

1. `poolId` 必须已经由 Pump12 注册、已经 Listing，且 quote asset 必须是 Robinhood Chain canonical USDG；
2. `amount` 必须大于0；Hook 使用 non-reentrant 的 `transferFrom` 拉取 USDG，并以调用前后余额差记账，不能盲信输入的 `amount`；
3. 注入是不可撤回的 BurnNet 资金贡献，不给调用者 Token、LP、份额、Distributor credit 或退款权；外部注入在激活前后都不产生 USDG 型 Distributor credit；
4. 外部注入不经过 TagAI/创建者手续费分成，实际收到的 USDG 100% 记入指定 poolId 的 Pending USDG；
5. 外部注入只增强回购墙；下一次有效 `poke()` 可以将其部署，但不得因此增加 Eligible trade-fee USDG 或 Distributor reserve credit；
6. 注入不能自动执行 poke、不能重置 heartbeat、不能改变 anchor/generation，也不能通过 dust 注入阻塞该 poolId；
7. 不允许管理员把一个 poolId 的 Pending USDG 改记到另一个 poolId；
8. 直接向 Hook 地址转账但未调用本函数的 USDG 不得自动归属于任何 poolId，前端必须明确提示调用正确入口。

Hook 手续费产生的 BurnNet 份额和协议模块主动注入的 USDG 使用同一套 per-pool Pending 总账，但必须按资金来源设置不可伪造的分类子账。只有官方池 swap callback 内实际收取并分给 BurnNet 的手续费可以增加 `pendingEligibleTradeFeeUSDG[poolId]`。BondDepository、PremiumSeller、pTEAM、外部 `addPendingUSDG`、直接转账、管理员补款及其他协议收入全部属于 non-eligible 资金。内部入账与外部 `transferFrom` 入账必须分别发出事件并保持总账守恒。

## 10. TWAP Oracle

共享 Hook 必须按 `poolId` 为每个官方池维护完全独立的 observation ring buffer 和 TWAP 状态：

```text
oracleState[poolId]
= observations
 + observationIndex
 + observationCount
 + lastCheckpointAt
 + lastValidTwap
```

`Hook.validTWAP(poolId)` 是协议所有市场价格判断的唯一输入。不得使用 V4 spot、PoolManager `slot0` 瞬时价格、其他 poolId 的价格、外部池价格或管理员提交价格替代。PoolManager spot 只允许作为累计 observation 的采样原料，必须经过满足固定窗口的时间加权后才能成为有效价格。

每个 poolId 的 TWAP 至少服务：

- BurnNet `poke()` 和 generation reset；
- Distributor premium；
- BondDepository 定价；
- PremiumSeller 激活和最小输出；
- pTEAM/IndexBondDesk 激活和认购定价。

安全规则：

1. Listing 时初始化首个 observation；
2. 不能使用调用 `poke()` 当前区块的 spot 作为 anchor 更新依据；
3. TWAP observation 数量、最小窗口和最大窗口使用部署前固定常量；
4. Oracle 数据不足、过期、时间倒退或不满足窗口要求时判定无效；
5. `poke()` 在 TWAP 无效时整笔 revert；
6. 所有 mint 模块在依赖的 TWAP 无效时 fail-closed；
7. Anchor 向下重启后的 mint 解冻不仅要求等待24小时，还必须存在完全形成于重启之后的有效 TWAP；
8. Anchor 更新只使用同一 poolId 已经满足窗口并封存的有效 TWAP，不允许同块 spot、跨池价格或外部输入。

Robinhood Chain 是 Arbitrum Orbit L2。TWAP 累积、8小时 epoch、24小时冻结和 freshness 必须使用 `block.timestamp` 的实际秒数，并验证时间单调递增；不得用 L2 block 数量估算经过时间，也不得假设固定出块间隔。单个 timestamp 内无时间增量的多次 swap 只能更新最新 tick，不能虚构 TWAP 权重。

所谓“封存价格”只能是同一个 `poolId` 的 Hook observation 在先前区块形成的时间加权结果，不是第二价格源。第一版直接使用：

```text
marketPrice = Hook.validTWAP(poolId)
```

所有依赖市场价格的模块都必须显式传入或永久绑定正确的 `poolId`，并校验该 poolId 注册的 Token、USDG、Hook 和模块地址一致。任何跨 poolId 读取均应 revert 或 fail-closed。

Oracle 的精确窗口属于实现期安全参数，必须结合 `30,000 USDG` 初始 TVL 做操纵成本仿真后冻结；不得由创建者或管理员在部署后修改。

## 11. Anchor

### 11.1 初始值

```text
initialAnchor = Pump12 curveEndPrice
≈ 0.000055862470929 USDG/Token
```

Anchor 不是协议兑付价格，不代表真实资产 NAV，也不要求计算 POL、BurnNet 仓位或指数资产的市场价值。

### 11.2 正常上调

每次有效 poke 最多上调8%：

```text
candidate = Hook.validTWAP(poolId)

newAnchor = max(
    oldAnchor,
    min(candidate, oldAnchor × 1.08)
)
```

正常 generation 内 anchor 不随下跌向下移动。

### 11.3 向下重启

当市场参考价格已经位于当前最深档以下，旧回购墙失去有效做市位置，BurnNet 按 generation 规则结算旧仓位并使用有效保守 Oracle 价格重设 anchor。

每次向下重启必须：

```text
generation += 1
lastDownwardResetAt = block.timestamp
mintFrozenUntil = block.timestamp + 24 hours
```

冻结期间所有依赖 anchor 的发行与 Desk 认购都停止。期间再次向下重启时，24小时重新开始计算。

## 12. BurnNet 回购网

### 12.1 初始状态

Listing 时：

```text
anchor = curveEndPrice
pendingUSDG = 0
deployedUSDG = 0
activeReserveUSDG = 0
reserveSnapshotUSDG = 0
totalBurned = 0
nextPokeAt = listTime + 8 hours
```

内盘不向 BurnNet 收费，因此 BurnNet 上市时没有 USDG。上市后 Hook 才开始给 BurnNet 累积资金。

### 12.2 七档价格

每个 generation 在 anchor 下方使用七档单边 USDG maker ranges：


| Tier | 相对 Anchor 跌幅 |
| ---- | ------------ |
| 0    | `5%`         |
| 1    | `10%`        |
| 2    | `15%`        |
| 3    | `20%`        |
| 4    | `30%`        |
| 5    | `40%`        |
| 6    | `50%`        |


层级：

```text
L1 = Tier 0–2
L2 = Tier 3–5
L3 = Tier 6
```

第一代空网收到首批 USDG 时，默认分配：

```text
L1 = 8%
L2 = 12%
L3 = 80%
```

后续沿用 HBTC 的 kappa 目标调节：

```text
kappa3
= 2 × L3未成交USDG
  / (anchor × circulatingSupply)
```

- `kappa3 < 1`：新增资金优先补充 L3；
- `kappa3 >= 1`：新增资金优先按 `40% / 60%` 补充 L1/L2；
- L3 总占比限制在 `40%–80%`；
- 所有比例换算、Token/USDG decimals 和 tick 方向必须经过定点数学测试。

### 12.3 三种 poke 场景

每8小时最多成功执行一次 poke。

每次有效 poke 必须按以下顺序形成 Distributor 可使用的储备快照：

```text
结算旧仓位
→ 销毁已经结算获得的Token
→ 按规则更新/重启anchor
→ 扣除不属于Active reserve的明确负债和keeper支付
→ 将本次允许部署的pendingUSDG按来源分类转为activeReserveUSDG
→ 按新anchor部署仓位
→ 封存reserveSnapshotUSDG、eligibleTradeFeeReserveUSDG、anchorVersion、generation和snapshotAt
```

`reserveSnapshotUSDG` 是本次 poke 已核验并锁定在该 poolId BurnNet 体系中的 USDG 储备本金，不是对 PoolManager 当前 spot 资产构成的即时读取。`eligibleTradeFeeReserveUSDG` 是其中由官方池交易费形成的子集，且任何时刻不得大于总储备。仓位在两个 poke 之间从 USDG 转换成 Token 时，已锁定的 Eligible 本金继续计入本期排放节流额度；结算时必须把获得的 Token 实际 burn，再更新下一份快照。该快照不是全体 Token 的 backing、兑付资产或价格托底承诺。

Distributor 禁止在 `distribute()` 中使用当前 spot、PoolManager 聚合余额或临时推高/压低价格后计算出来的仓位 USDG 数量。储备快照必须来自该 `poolId` 有效 TWAP 保护的 poke，并与当前 `anchorVersion` 和 `generation` 匹配；快照不足、过期或版本不匹配时，本 epoch mint 为0而不是使用不可信数据。储备快照只封存 USDG 数量和会计版本，绝不封存、生成或替代市场价格。

#### 场景 A：价格高于 Anchor

旧仓位先结算，新增 pending USDG 按七层目标部署到 anchor 下方。

#### 场景 B：价格低于 Anchor、但仍高于最深档

- 市价上方已经失效或已经越过的档位不再新增 USDG；
- 当前价格所在档只部署可正常结算的部分；
- 其余资金部署到当前价格以下仍然有效的档位；
- 已经获得并结算到 BurnNet 的 Token 立即销毁；
- 存活资金迁移到新位置，但 generation 不变。

初始第一档约为：

```text
0.95 × initialAnchor
≈ 0.000053069347383 USDG
```

相对 `0.00006` 上市价约低 `11.5511%`。

#### 场景 C：价格位于最深档以下

```text
结算旧generation
→ 销毁已获得Token
→ 撤销旧仓位
→ generation++
→ 使用有效Oracle价格向下重设anchor
→ 冻结mint和Desk认购24小时
→ 在新anchor下部署仍可使用的pending USDG
```

如果第一代在尚未部署任何 USDG 前就跌穿最深档，则没有 Token 可销毁，只执行 anchor/generation 重设和资金部署。

### 12.4 Harvest

保留 permissionless `harvest()`：

- 只能移除已经完全越过的仓位；
- 结算并销毁已经获得的 Token；
- 对已经计入 reserve snapshot 的仓位，必须在同一交易中扣减已经转换掉的 Active reserve USDG 本金；其中属于 Eligible trade-fee 的本金同时扣减 `consumedEligibleTradeFeeUSDG`，并增加实际 burn，禁止同一份交易费价值同时保留 reserve credit 和 burn credit；
- 不同来源的 USDG 混合部署时，每个仓位必须固化 `eligiblePrincipalUSDG / totalPrincipalUSDG`，成交消耗按该固定比例归因；不得由 keeper 或管理员选择优先消耗 non-eligible 本金来人为保留更多信用；
- harvest 后记录该快照自上次 poke 以来的 `consumedActiveUSDG` 和 `consumedEligibleTradeFeeUSDG`；Distributor 只使用 `eligibleTradeFeeReserveUSDG - consumedEligibleTradeFeeUSDG`；
- 不修改 anchor；
- 不迁移 generation；
- 不领取 poke keeper 奖励。

`poke()` 的 TWAP 无效时必须 revert，但 `harvest()` 可以继续执行纯结算，避免 Oracle 中断导致已成交 Token 长期无法销毁。

### 12.5 供应量口径

```text
circulatingSupply = Token.totalSupply()
```

不减去基础 LP、Bond escrow、pTEAM Desk、Staking 或仓位中的 Token。原因是这些 Token 在真正销毁前都可能进入市场。

BurnNet 仓位内已经转换成 Token、但尚未结算和销毁的部分仍计入供应量。只有实际 `burn()` 后 `totalSupply` 才下降并增加 Distributor credit。

## 13. Mint 权限与统一冻结

### 13.1 权限迁移

```text
内盘：
仅存在创建时一次性预铸，Pump12不能额外mint

Listing：
Treasury被设置为唯一永久minter
Pump12永久失去供应控制

外盘：
Distributor、BondDepository、PremiumSeller、pTEAM
只能调用Treasury.mintNet()
```

Treasury 的授权模块集合在部署/Listing 时一次性固定，不提供新增任意 minter 的管理员路径。

### 13.2 冻结

Treasury 在统一 `mintNet()` 入口检查：

```text
block.timestamp >= mintFrozenUntil
oracle.hasValidWindowAfter(lastDownwardResetAt)
```

Anchor 向下重启后的24小时内，以下操作全部禁止：

- Distributor `distribute()`；
- BondDepository 新认购；
- PremiumSeller `execute()`；
- pTEAM `exercise()`；
- IndexBondDesk 新认购。

不得在 anchor 更新的同一交易或同一区块执行 mint。

Treasury 记录：

```text
mintedByDistributor
mintedByBond
mintedByPremium
mintedByPTeam
```

用于链上审计各类供应来源。

## 14. Distributor 与质押

### 14.1 排放速度

沿用 NetNet 的 premium-throttled 公式，但把 NAV 输入替换为 anchor。市场价格只能读取该 Token 官方 `poolId` 的 Hook TWAP：

```text
marketPrice = Hook.validTWAP(poolId)
emissionAnchor = max(initialAnchor, currentAnchor)
premium = marketPrice / emissionAnchor

premium <= 1:
rate = 0

1 < premium < 1.75:
rate = 0.45% × (premium - 1) / (1.75 - 1)

premium >= 1.75:
rate = 0.45%
```

`initialAnchor` 是 Distributor 排放速度的永久最低参考线：只要 `marketPrice <= initialAnchor`，即使 BurnNet 因 downward reset 已经使用更低的 `currentAnchor`，质押排放仍然为0。价格重新高于 initialAnchor 后，也按 `marketPrice / emissionAnchor` 从0线性恢复，不允许使用更低 currentAnchor 让排放率直接跳到高位。

例如 downward reset 后：

```text
currentAnchor = 0.5 × initialAnchor

TWAP = 0.9 × initialAnchor:
reserveCredit仍按initialAnchor固定折算
Distributor rate = 0

TWAP = 1.1 × initialAnchor:
premium = 1.1
Distributor rate = 0.06% / 8 hours
```

每8小时最多推进一个 epoch：

```text
formulaReward = totalSupply × rate
```

`0.45%` 是相对于 Token 总供应量的协议排放速度，不是已质押数量的0.45%。新增 Token 全部 mint 到 Staking，并通过 sToken rebase 只分给实际质押者。没有外部质押者时不 mint。

以上市初始状态为例：

```text
initialSupply = 1,000,000,000 Token
initialTWAP   = 0.00006 USDG
initialAnchor = 0.000055862470929 USDG
initialPremium ≈ 1.074066345
initialRate ≈ 0.0444398% / 8 hours
initialFormulaReward ≈ 444,398 Token / 8 hours
```

实际 mint 仍受剩余 Distributor credit 限制；以上数字只表示上市价格和 anchor 均未变化时的首期理论排放。

每次 Distributor epoch 都必须使用当次有效的 `Hook.validTWAP(poolId)` 计算 premium，并使用 `max(initialAnchor, currentAnchor)` 作为排放速度分母。TWAP 无效或 `marketPrice <= emissionAnchor` 时本 epoch mint 为0；不得回退到 spot、上一次价格或其他 poolId。Reserve snapshot 只参与额度计算，不参与 premium 或 anchor 的价格读取。

### 14.2 质押进入、退出和 rebase 快照

完全沿用 NetNet 的即时质押模型：

```text
stakingWarmupEpochs = 0
```

- 用户质押 Token 后立即按 `1:1` 收到 sToken；
- 用户可以随时用 sToken 按当前余额 `1:1` 解除质押；
- 不记录每个用户的质押时间，也不要求单个地址连续质押满8小时；
- 奖励按全局8小时 epoch 的 rebase 快照分配，而不是按用户持仓秒数线性计提；
- 在 `epoch.end` 之前持有 sToken，并跨过该次有效 rebase，即可参与该期奖励；
- 在 rebase 前退出则不参与该期奖励，rebase 后可以立即退出并保留已经获得的奖励；
- `stake()` 必须先处理已经到期的 rebase，再接收新质押，因此在 epoch 已到期后才提交的质押不能追溯领取刚到期的奖励；
- 没有流通 sToken 时 Distributor 不 mint，不把无人领取的排放计入已用信用。

这是明确接受的 NetNet 快照语义，不得由前端描述为“每个用户必须质押满8小时才有奖励”。

### 14.3 初始信用、交易费信用和 burn 信用

Distributor 不使用 NetNet 的 Treasury RFV。它使用固定初始信用、按 `initialAnchor` 折算的 Eligible trade-fee USDG 和 BurnNet 实际销毁共同限制长期排放。

初始信用：

```text
bootstrapCredit
= 750M Curve allocation × 5%
= 37.5M Token
```

交易费储备折算价格永久固定为初始最低 Anchor：

```text
reserveReferencePrice
= initialAnchor
```

`initialAnchor` 只是在 Distributor 信用会计中使用的固定折算单位，不是兑付价格、净值或协议托底承诺。`currentAnchor` 上下移动不会重估、扩大或缩小同一笔 Eligible trade-fee USDG 对应的信用。Anchor 向下重启仍受有效 TWAP、24小时 mint freeze 和完全形成于重启后的 post-reset TWAP 约束；它只影响排放速度门槛和 BurnNet 仓位，不改变交易费折算分母。

只有上市后官方池真实交易产生、已经完成手续费分配、并在最近一次有效 poke 中从 Pending 激活和封存的 Eligible trade-fee USDG 参与计算：

```text
reserveCredit
= (eligibleTradeFeeReserveUSDG - consumedEligibleTradeFeeUSDG)
  / initialAnchor

availableCredit
= max(
    37.5M
    + reserveCredit
    + BurnNet.totalBurned
    - Distributor.totalMinted,
    0
  )
```

以上市参数为例：

```text
initialAnchor ≈ 0.000055862470929 USDG

无论currentAnchor如何变化：
1 USDG Eligible trade-fee reserve
≈ 17,901.106 Token credit
```

因此 Anchor 持续上移不会因为分母变大而耗尽或缩小既有交易费信用。这里的 USDG 只用来确定发行节奏，不构成 Token 持有人的按价索偿权。

实际排放：

```text
mintAmount = min(formulaReward, availableCredit)
```

全部七档买入价格都低于部署该 generation 时的 anchor。结算后实际销毁会降低净供应并增加 burn credit，但本机制不声称 reserve credit 与全体 Token 供应之间存在法定偿付或完全抵押关系。

只有 BurnNet 已经实际销毁的 Token 才进入 burn credit：

```text
1 Token actual BurnNet burn
= 1 Token future Distributor credit
```

不产生 USDG 型 reserve credit 的项目：

- Hook 刚收到、仍处于 Pending 状态的 USDG；
- 未经有效 poke 封存或属于过期/错误 generation/anchorVersion 快照的交易费 USDG；
- 平台、创建者应收款、keeper 预留和其他明确负债；
- 基础永久 POL 中的15,000 USDG；
- BondDepository、PremiumSeller、pTEAM/IndexBondDesk 的全部 USDG 收入；
- permissionless `addPendingUSDG`、管理员补款、直接转账和其他外部注资；
- 仓位获得但尚未实际 burn 的 Token 不额外增加 `totalBurned`；其对应的 Eligible trade-fee 本金只能沿用原 reserve credit，不能再按 Token 数量重复计入；
- 用户主动 burn；
- 非官方池交易及任何无法由官方池 swap callback 证明来源的 USDG。

上述 non-eligible USDG 仍可通过指定 poolId 的 Pending/Active 账本进入 BurnNet、部署回购墙和购买 Token，但激活后也不得增加 `eligibleTradeFeeReserveUSDG`。如果这些资金以后实际买回并销毁 Token，已销毁数量仍按 `1 Token burn = 1 Token burn credit` 进入 Distributor；这只允许补发已经真实退出供应的数量，不会因一笔 USDG 注资直接扩大净供应。

Eligible 来源必须在官方池手续费结算时确定，之后不可由 keeper、管理员、poke 或资金迁移修改。任何 non-eligible 资金都不能通过先进入 Pending、与交易费混合部署、跨 poolId 转账或会计重分类而变成 Eligible。

### 14.4 长期行为

如果价格长期高于 anchor 且 BurnNet 从未成交，Distributor 不再固定停止于 `37.5M`：官方池持续产生的 Eligible trade-fee USDG 会按 `initialAnchor` 持续提供额外信用。若没有新的合格交易费也没有实际销毁，则仍会在耗尽现有信用后停止。Bond、PremiumSeller、pTEAM 和外部补款无论金额多大，都只能增加回购能力，不能直接延长质押增发。

因此：

```text
价格相对max(initialAnchor, currentAnchor)决定排放速度
按initialAnchor折算的Eligible trade-fee reserve决定尚未成交时的储备信用
实际销毁降低净供应并恢复未来排放信用
```

这是一套排放节流机制，不是 NetNet 的 RFV 偿付约束。它只限制 Distributor 新增量，不把 initialAnchor 或 currentAnchor 宣称为全体 Token 的兑付 NAV，不要求 BurnNet 储备能够托底全部供应，也不计算基础 POL 或指数资产价值。

协议无法在链上可靠区分自然交易与同一经济主体的往返交易，因此所有在官方池成功结算的 swap 都按同一规则产生 Eligible 手续费。固定 `initialAnchor` 会使每1 USDG Eligible 手续费始终对应约17,901.106 Token 信用；当市场价远高于 initialAnchor 且某主体控制大部分质押份额时，存在通过付费交易争夺后续排放的经济动机。TWAP、每8小时一次 epoch、`0.45%` 速率上限和实际手续费成本只能限制速度，不能从机制上证明不存在 wash-trading。第一版明确接受这一剩余风险，并要求监控“单地址/关联地址交易费贡献、质押占比、领取排放”的集中度；不得把 TWAP 防操纵误写成反洗量机制。

## 15. BondDepository

第一版只提供 USDG reserve bond，不接受 LP Token。

### 15.1 定价

```text
bondPrice
= max(
    TWAP × (1 - discount),
    anchor
  )
```

固定边界：

- `discount <= 3%`；
- TWAP 无效时停止；
- anchor 向下重启后的24小时冻结期停止；
- 用户提供 `maxPrice` 保护；
- 所有用户 USDG 直接进入该 Token 的 BurnNet；
- Treasury mint 的 Bond Token 在 BondDepository 内2天线性归属。

### 15.2 发行上限

```text
每8小时payout
<= epochStartSupply × 0.25%

滚动30天payout
<= periodStartSupply × 5%
```

周期基数在周期开始时快照，不能通过周期内增发递归放大当期上限。Bond 没有永久 lifetime cap，因为每次发行都有真实 USDG 进入 BurnNet，但短期发行受双层上限约束。

## 16. PremiumSeller

### 16.1 激活

```text
TWAP > 2 × anchor
```

并且：

- 距离上次成功执行至少1小时；
- 不在 mint 冻结期；
- TWAP 和最小输出检查有效；
- Token/USDG swap 受最大滑点边界保护。

### 16.2 单次额度

```text
clipSize
= PermanentLiquidityVault全域基础POL
  当前Token库存 × 0.25%
```

初始基础 POL 有 `250M` Token，因此初始理论 clip 为 `625,000 Token`。实际激活时价格已经高于 `2 × anchor`，基础全域仓位中的 Token 数量通常已随买入下降，所以真实 clip 会更小。

不得使用：

- 全 PoolManager 或 PositionManager 的 Token 聚合余额；
- 外部 LP；
- BurnNet 七档仓位；
- `totalSupply × 固定比例`。

### 16.3 资金去向和上限

```text
Treasury mint Token
→ PremiumSeller卖入官方池
→ 100%卖出USDG进入BurnNet
```

PremiumSeller 不消耗 Distributor credit。协议不增加额外的“每天总供应量1%”限制；沿用 NetNet 风格的 `0.25% 基础仓位 Token inventory / execution + 1 hour interval + 2×anchor gate`。

## 17. pTEAM 与 IndexBondDesk

### 17.1 固定 Strike

采用固定初始 Anchor 方案：

```text
TEAM_STRIKE
= initialAnchor
≈ 0.000055862470929 USDG/Token
```

Strike 在创建/Listing 后永久不变，不随 anchor 正常上涨或 generation 向下重启改变。

### 17.2 归属和额度

pTEAM 从 `listTime` 起30天线性归属，采用 NetNet 的动态15%上限：

```text
maxCumulativeExercise
= vestedFraction × 15% × circulatingSupply

exercisableNow
= max(maxCumulativeExercise - alreadyExercised, 0)
```

本协议的 `circulatingSupply = totalSupply`。

额外限制：

- `block.timestamp >= listTime + 24 hours`；
- TWAP 有效且 `TWAP >= 1.2 × anchor`；
- 不在 anchor 向下重启后的 mint 冻结期；
- IndexBondDesk 未售 Token inventory 不超过当前总供应量的 `0.5%`。

### 17.3 行权

团队行权 `N` 枚 Token：

```text
团队支付：N × TEAM_STRIKE USDG → BurnNet
Treasury mint：N Token → IndexBondDesk
```

行权 Token 不能发送给团队钱包。IndexBondDesk inventory 没有撤回路径，唯一出口是用户认购后进入2天线性归属 note；不能进入官方池或外部池。

### 17.4 用户认购和指数购买

设：

```text
A = 认购时当前anchor
S = TEAM_STRIKE
D = Desk认购单价
N = 用户认购数量
```

Desk 价格：

```text
D
= max(
    TWAP × (1 - deskDiscount),
    1.2 × A
  )
```

用户支付 `D × N` USDG 后：

```text
BurnNet remittance
= max(A - S, 0) × N

Index purchase budget
= [D - max(A - S, 0)] × N
```

结合团队行权款，BurnNet 每发行一枚 pTEAM Desk Token 至少收到当前 anchor 对应资金：

```text
S + max(A - S, 0) >= A
```

如果 generation 向下重启后 `A < S`，用户认购款不再额外补充 BurnNet；团队此前支付的固定 strike 已经高于当前 anchor。

指数购买预算在同一认购交易中，通过受支持路由购买 Token 创建时选定的 TagAI 指数 Token，并先发送到创建者指定的指数资产地址。

指数资产：

- 必须来自官方 `IndexRegistry`；
- Index ID 在 Token 创建时固定，不能后续替换；
- 必须有官方价格源、最小流动性和最大滑点保护；
- 购买失败时整笔认购回滚；
- 不计入 anchor、BurnNet 资产、协议 backing 或 Distributor credit；
- 后续如何处置由单独机制规范决定，本规范只确定初始接收方为创建者。

`deskDiscount` 默认值和不可突破的最大值需在实现 IndexBondDesk 前单独冻结，不得给创建者无限折扣权限。

## 18. 模块发行边界汇总


| 模块             | 触发条件                                               | 接收方                 | 额度                                                                                                   |
| -------------- | -------------------------------------------------- | ------------------- | ---------------------------------------------------------------------------------------------------- |
| Distributor    | `TWAP > max(initialAnchor, currentAnchor)`，且储备快照有效 | Staking/质押者         | 每8小时最高总供应量0.45%；新 mint 后不得超过当时的 `37.5M + effectiveEligibleTradeFeeUSDG / initialAnchor + actualBurn` |
| BondDepository | 有效 TWAP、用户支付 USDG                                  | Bond vesting escrow | 每8小时0.25%；滚动30天5%                                                                                    |
| PremiumSeller  | `TWAP > 2 × anchor`                                | 卖入官方池               | 每次基础 POL 当前 Token inventory 的0.25%；间隔1小时                                                             |
| pTEAM          | 上市24小时后、30天归属、`TWAP >= 1.2 × anchor`               | IndexBondDesk       | 动态15%；Desk 未售库存不超过总供应量0.5%                                                                           |


所有模块同时受 Treasury 的24小时 downward-reset freeze 和 post-reset TWAP 要求约束。

## 19. 推荐合约边界

```text
Pump12
├─ Token12 implementation
├─ TreasuryFactory / Treasury clone
├─ BurnNetFactory / BurnNet clone
├─ Staking + sToken
├─ Distributor
├─ BondDepository
├─ PremiumSeller
├─ PTeam
├─ IndexBondDesk
└─ PermanentLiquidityVault

NetNetHook（平台共享，按poolId隔离）
├─ 官方池注册
├─ USDG Hook fee
├─ Fee split ledger
├─ TWAP observations
├─ Permissionless addPendingUSDG(poolId, amount)
├─ BurnNet pending/active USDG及资金来源子账
└─ Per-pool reserve snapshots
```

可共享 Hook 和 Factory，但以下状态必须按 Token/poolId 隔离：

- 费率和创建者分成；
- 创建者收款地址；
- BurnNet、Treasury 和模块地址；
- Anchor、generation 和 poke 时间；
- Pending/deployed USDG 及 Eligible/non-eligible 来源分类；
- Active reserve USDG、Eligible trade-fee reserve、reserve snapshot、snapshotAt 和 anchorVersion；
- TWAP observations；
- Distributor credit；
- Index ID；
- 各 mint 模块累计量。

## 20. 核心会计与安全不变量

### 20.1 手续费守恒

外盘每笔官方池交易：

```text
totalHookFee
= tagaiFee + creatorFee + burnNetFee
```

内盘每笔交易：

```text
actualInnerFee
= tagaiFee + creatorFee
```

内盘不得扣除或虚构 BurnNet fee。

### 20.2 BurnNet USDG

至少维护：

```text
totalBurnNetUsdtIn
= pendingUSDG
 + activeLiquidUSDG
 + activePositionPrincipalUSDG
 + totalUSDGConvertedToToken
 + keeperPaid
```

仓位迁移、部分成交、generation 重启和 harvest 后都必须保持会计守恒。

Eligible 子账还必须满足：

```text
pendingEligibleTradeFeeUSDG <= pendingUSDG
activeEligibleTradeFeeUSDG <= activeReserveUSDG

totalEligibleTradeFeeAccrued
= pendingEligibleTradeFeeUSDG
 + activeEligibleLiquidUSDG
 + activeEligiblePositionPrincipalUSDG
 + consumedEligibleTradeFeeUSDG
 + eligibleUSDGSpentOnKeeperOrExplicitCost
```

只有官方池 Hook fee 中已经分配给 BurnNet 的份额可以增加 `totalEligibleTradeFeeAccrued`。poke 只是把 Eligible 从 Pending 搬到 Active，仓位迁移只改变其位置，任何操作都不能凭空增加该累计值。keeper 或其他明确成本若从混合资金支付，必须按支付前的固定来源比例同时减少 Eligible 与 non-eligible 子账，只有净部署的 Eligible 金额进入 reserve credit。

共享 Hook 不得用自身聚合 `USDG.balanceOf()` 推断任何单个 poolId 的 Pending 或 Active reserve。必须满足跨池总账：

```text
Hook可归属USDG + 各poolId仓位可归属USDG
>= ΣpendingUSDG[poolId]
 + ΣactiveLiquidUSDG[poolId]
 + Σ平台/创建者可领取USDG[poolId]
 + Σ其他已记录USDG负债[poolId]
```

任一 poolId 的注入、poke、harvest、领取或迁移都不得改变其他 poolId 的余额、储备快照或 Distributor credit。

### 20.3 Token 销毁

```text
BurnNet.totalBurned
= 所有成功Token.burn()数量之和
```

Distributor 只能读取实际销毁累计量，不能根据仓位估算未来 burn。

### 20.4 Distributor

```text
emissionAnchor
= max(initialAnchor, currentAnchor)

marketPrice <= emissionAnchor:
rate = 0

reserveReferencePrice
= initialAnchor

reserveCredit
= (validEligibleTradeFeeReserveUSDG - consumedEligibleTradeFeeUSDG)
  / initialAnchor

validEligibleTradeFeeReserveUSDG <= validReserveSnapshotUSDG
consumedEligibleTradeFeeUSDG <= validEligibleTradeFeeReserveUSDG

currentCreditLimit
= 37.5M
 + reserveCredit
 + BurnNet.totalBurned

availableCredit
= max(currentCreditLimit - Distributor.totalMinted, 0)

每次新mint成功后：
Distributor.totalMintedAfter <= currentCreditLimit
```

`currentAnchor` 的任何上调或下调都不得改变既有 Eligible trade-fee USDG 的折算结果。若交易费本金被仓位成交消耗，而对应 Token 尚未完成实际 burn，`currentCreditLimit` 可能暂时低于既有 `totalMinted`；合约不得下溢、回滚历史分配或让 Staking rebase 失败，`availableCredit` 必须饱和为0，直到实际 burn 或新的 Eligible 交易费使额度恢复。因此永久不变量是“无信用时不能新增”。

所有 Pending USDG、non-eligible Active USDG、过期快照、错误 generation/anchorVersion、spot 推导的临时仓位余额和其他 poolId 的资金均不得进入 `reserveCredit`。只有由本 poolId 官方池 swap callback 产生且经过有效 poke 激活的 BurnNet 交易费份额可以进入。

### 20.5 Mint 权限

```text
Token唯一minter == Treasury
Treasury调用者 ∈ 固定授权模块集合
```

不存在 owner 任意 mint 路径。

### 20.6 基础 POL

基础仓位 liquidity 在 Listing 后永远不能下降。BurnNet 仓位变化不得影响基础仓位所有权或 liquidity。

### 20.7 Anchor Freeze

任何 downward reset 后：

```text
所有mint和IndexBondDesk认购
在24小时到期且post-reset TWAP有效前均不可成功
```

## 21. 事件和可观测性

至少定义并索引以下事件：

```text
TokenCreated
CurveTrade
CurveCompleted
TokenListed
MintAuthorityTransferred
OfficialPoolRegistered
HookFeeAccrued
HookFeeClaimed
PendingUSDGAdded
PendingUSDGActivated
ReserveSnapshotUpdated
AnchorUpdated
GenerationReset
MintFreezeStarted
MintFreezeEnded
NetPoked
NetHarvested
BurnPositionOpened
BurnPositionSettled
TokenBurned
Distributed
BondCreated
BondClaimed
PremiumSold
PTeamExercised
DeskSubscribed
IndexPurchased
```

`PendingUSDGAdded` 至少索引 `poolId`、Token、funder 和不可变的资金来源类型，并记录 requested amount、actual received amount 与 `eligibleForDistributor`。`ReserveSnapshotUpdated` 至少记录 `poolId`、generation、anchorVersion、固定 `initialAnchor`、Active reserve USDG 总额、Eligible trade-fee USDG 及折算 reserve credit。

Keeper、创建者、Token、poolId、generation、USDG 数量、Token 数量和 anchor 均应进入相应事件。回调内部事件必须记录外部 keeper，而不是 PoolManager 地址。

## 22. 测试要求

实现不得只依赖单元测试，至少覆盖：

1. Pump9 曲线公式与 `750M → 15,000 USDG` 精确标定；
2. 所有可能的部分成交、最后一笔 fill-to-cap 和退款；
3. 内盘/外盘手续费守恒和所有 `f/c` 边界；
4. Token/USDG 两种地址排序；
5. exact-output 必须拒绝；
6. Listing 原子性和 mint 权限永久交接；
7. 基础全域 LP 永久不可减少；
8. Robinhood Chain 主网 fork（chain ID 4663、canonical USDG、canonical Uniswap v4 PoolManager）上的全域资产比例和 `polTokenInventory`；
9. TWAP observation 不足、过期、同 timestamp 操纵、稀疏出块以及不得用 block count 代替秒数；
10. BurnNet 七档全部未成交、部分成交、完全穿越和深档穿越；
11. Generation 重启和连续重启；
12. 24小时 mint freeze 与 post-reset TWAP；
13. BurnNet USDG/Token 会计守恒 invariant；
14. Distributor 在 `TWAP <= max(initialAnchor, currentAnchor)` 时零排放、`37.5M + eligibleTradeFeeReserve/initialAnchor + actualBurn` 约束、anchor 上下调整时 reserve credit 保持不变、饱和归零，以及 `warmup=0` 的 epoch 快照进入/退出边界；
15. Bond epoch/30天双上限；
16. PremiumSeller clip 只使用永久基础 POL；
17. pTEAM 动态15%、24小时启动限制和0.5% Desk inventory；
18. 恶意创建者收款合约不能阻塞 swap；
19. 恶意/未注册指数不能用于创建 Token；
20. 共享 Hook 中不同 poolId 的 Pending/Active/储备快照、资金和 Oracle 状态不能串账；
21. permissionless `addPendingUSDG` 的未注册 poolId、零金额、余额差记账、直接转账、恶意 ERC-20 回调和跨池注入；
22. Distributor 不得使用 spot/PoolManager 聚合余额，闪电改变仓位资产构成不能增加储备信用；
23. Eligible 交易费 USDG 在有效 poke 激活前不产生信用，激活后只进入指定 poolId；
24. BondDepository、PremiumSeller、pTEAM、`addPendingUSDG`、管理员补款和直接转账在激活前后均不产生 USDG 型 reserve credit；
25. Eligible 与 non-eligible USDG 混合部署、部分成交和 harvest 时按仓位固化比例消耗，任何调用顺序都不能把 non-eligible 本金重分类为 Eligible；
26. non-eligible USDG 买回并实际 burn 后只按真实 burn 数量产生1:1 burn credit，不能同时产生 reserve credit；
27. 高 `TWAP / initialAnchor`、高质押集中度和创建者自交易组合下的 wash-trading 经济仿真，确认链上发行仍受 epoch rate 与 credit 双重上限约束；
28. USDG 6 decimals 下 Curve 买卖、手续费三方分账、退款、Bond、pTEAM、reserve credit 与所有向上/向下舍入边界；
29. Uniswap v4 exact-input 的买入 `beforeSwap` 收费、卖出 `afterSwap` 收费、Hook returns-delta 权限位和 PoolManager delta 全部结清；
30. 部署脚本必须拒绝非 `4663` chain ID、错误 USDG 地址、错误 decimals、无代码或非 canonical PoolManager。

## 23. 实现前仍需冻结的工程参数

下列项目不改变本文经济机制，但必须在编码/仿真后写成不可变常量并补充本文：

1. Curve `aRaw`、`bRaw` 的最终整数值；
2. 上市 `sqrtPriceX96`、全域 ticks 和 liquidity delta；
3. Per-pool TWAP observation 数量、ring buffer 容量、checkpoint 最小间隔、最小窗口和最大窗口；
4. BurnNet 每档精确 tick 宽度和 tick rounding；
5. Keeper bounty 的 USDG 数量、上限和支付来源；
6. IndexBondDesk 默认 discount 和 immutable maximum discount；
7. Hook exact-input Router/PoolManager unlock、settle、take 与 returns-delta 的最终结算接口和权限位；
8. Robinhood canonical USDG 的 SafeERC20、6-decimal rounding、代理升级、黑名单和暂停风险处理；
9. 所有 clone/factory 的地址预测、初始化顺序和 wiring 防抢跑方案。

以上工程参数冻结后，应新增部署参数表和主网 fork 验证结果。本规范中的经济比例、资金去向、发行权限和长期供应约束不得在实现过程中被隐式改变。

## 24. Robinhood Chain 外部基础设施基线

以下信息是 Pump12 Robinhood 首发版的部署前置条件，部署脚本和主网 fork 必须再次链上核验，不能只依赖文档常量：


| 项目                         | 当前基线                                                                               |
| -------------------------- | ---------------------------------------------------------------------------------- |
| Robinhood Chain mainnet    | chain ID `4663`，ETH gas，public RPC `https://rpc.mainnet.chain.robinhood.com`       |
| Explorer                   | `https://robinhoodchain.blockscout.com`                                            |
| Canonical USDG             | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`，链上 `symbol() = USDG`、`decimals() = 6` |
| Uniswap v4 PoolManager     | `0x8366a39cc670b4001a1121b8f6a443a643e40951`                                       |
| Uniswap v4 PositionManager | `0x73991a25c818bf1f1128deaab1492d45638de0d3`                                       |


资料来源：

- [Robinhood Chain 网络配置](https://docs.robinhood.com/chain/connecting/)
- [Robinhood Chain 官方 Token 地址](https://docs.robinhood.com/chain/contracts/)
- [Uniswap Robinhood Chain 部署清单](https://github.com/Uniswap/contracts/blob/main/deployments/4663.md)

其中 USDG 的6位精度和 symbol 已于 `2026-09-01` 通过 Robinhood 官方主网 RPC 只读核验。外部协议地址、代码和 USDG 行为可能升级或变化，因此每次正式部署都必须重新记录区块高度、代码哈希和接口探测结果。