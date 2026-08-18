# NutboxRouter

`NutboxRouter` 是 Nutbox 平台级的共享询价与交易路由，不属于某一个 NFT、Pump 或其他 dApp。平台为每个代币对维护唯一的当前官方 DEX 池，再为任意两个端点代币设置一条默认路径；任何账户或合约都可以使用当前配置询价，或执行精确输入交易。官方池可以独立替换，所有引用它的路径会自动生效，不需要逐条更新。

本目录包含完整的 Router 模块：

| 文件 | 职责 |
| --- | --- |
| [`NutboxRouter.sol`](./NutboxRouter.sol) | 池注册表、默认路径管理、精确输入交易、V4 回调与资产结算 |
| [`NutboxSpotPrice.sol`](./NutboxSpotPrice.sol) | V2、V3、Uniswap V4、PancakeSwap Infinity CL 的即时价格读取与来源认证 |
| [`INutboxRouter.sol`](./INutboxRouter.sol) | dApp、脚本和第三方合约使用的公共接口 |

## 1. 功能边界

Router 提供以下能力：

1. 平台为每个归一化代币对审核并登记唯一的当前官方池，该池可以是 V2、V3、Uniswap V4 或 PancakeSwap Infinity CL。
2. 平台为一个查询端点对设置一条由最多五个稳定代币对 ID 组成的默认路径。
3. 一条路径自动支持正向和反向使用。
4. 路径可混合 V2、V3 和两种 V4 池。
5. 任何人都可以按当前路径读取即时现货报价。
6. 任何人都可以按当前路径执行 exact-input 交易。
7. 原生 BNB 用 `address(0)` 表示，并与 WBNB 在路径查找层归一化。
8. 平台更换某个代币对的官方池后，所有引用该代币对的路径自动使用新池，路径本身不需要修改。

Router 不负责以下事项：

- 不自动搜索最优路径；路径完全由 owner 配置。
- 不接收用户自定义 path，也不允许调用方固定某个历史 path。
- 不提供 TWAP，不抵抗价格操纵；`quote` 是当前区块的池内即时价格。
- 不在报价中计算交易手续费、价格冲击或滑点。
- 不向用户收取平台手续费。
- 不支持 exact-output。
- 不设计为托管资金或长期持币合约。
- 不支持 fee-on-transfer、rebasing 或转账到账数量不确定的代币。

## 2. 核心数据模型

Router 将配置拆成两层：`PricePool` 和 `Route`。

```text
经过审核的 DEX 合约
        │
        ▼
PricePool 注册表
  pairId(A/B) -> 当前唯一官方池类型、参数、引用数
        │
        ▼
Route 注册表
  tokenA/tokenB -> pairId[1..5]
        │
        ├── quote：逐池读取即时价格
        └── swap：逐池执行真实交易
```

### 2.1 PricePool

`StoredPricePool` 保存：

```solidity
struct StoredPricePool {
    bool enabled;
    uint32 routeReferences;
    address token0;
    address token1;
    SourceType sourceType;
    bytes sourceData;
}
```

- `enabled`：池是否存在于注册表。
- `routeReferences`：有多少条路径正在引用该代币对槽位。更换槽位中的具体池不会改变该数量；非零时不能删除整个槽位。
- `token0/token1`：当前官方池的两个真实端点；V4 原生币端点可以是 `address(0)`。
- `sourceType/sourceData`：当前官方池的 DEX 类型及重建、认证和执行所需的数据。

Router 注册表 ID 根据归一化后的代币对计算，而不是根据具体 DEX 池计算：

```solidity
normalizedA = tokenA == address(0) ? wrappedNative : tokenA;
normalizedB = tokenB == address(0) ? wrappedNative : tokenB;
poolId = keccak256(abi.encode(min(normalizedA, normalizedB), max(normalizedA, normalizedB)));
```

本文继续沿用合约 ABI 中的名称 `poolId`，但它实际是稳定的 `pairId`：

- A-B 无论使用 V2、V3 还是 V4，都得到同一个 ID。
- 同一个 A-B 只能存在一个当前生效的官方池，不能同时登记多个候选池。
- `replacePricePool` 可以原子替换该 ID 下的具体池配置。
- 所有路径只保存稳定 ID，因此更换 A-B 官方池不会改动任何路径。
- 该 ID 不等于具体 DEX 协议内部使用的 pool ID。

例如，A-WBNB 的 V3 池可以直接替换成 A-BNB 的 V4 池。由于 BNB 在注册表层归一化成 WBNB，替换前后 pair ID 相同；当前官方池保存的真实端点则会从 `A/WBNB` 变成 `A/address(0)`，交易执行器据此完成包装或解包。

### 2.2 Route

`StoredRoute` 保存：

```solidity
struct StoredRoute {
    bool enabled;
    bytes32[] poolIds; // 实际保存稳定 pair IDs，不固定具体 DEX 池
}
```

路径端点先按照地址大小排序，形成唯一的 canonical key：

```solidity
routeKey = keccak256(abi.encode(canonicalToken0, canonicalToken1));
```

因此：

- `A -> B` 与 `B -> A` 共用同一条存储路径。
- 反向访问时，Router 反向遍历 pair ID，并对每个当前官方池使用相反交易方向。
- `routePoolAt(A, B, i)` 按调用者请求的方向返回稳定 pair ID；查询 `B, A` 时顺序自动反转。
- 路径最多包含 `MAX_ROUTE_HOPS = 5` 个池。
- 路径必须首尾连续，且中间不能重复访问已经经过的代币，以阻止环路。

例如，登记：

```text
SPCX -> USDT -> WBNB
```

同一份配置可用于：

```text
SPCX -> WBNB
WBNB -> SPCX
```

### 2.3 原生 BNB 与 WBNB

外部接口使用：

- `address(0)`：原生 BNB。
- `wrappedNative`：WBNB 合约地址。

路径 key、连续性检查和终点检查会通过 `_normalized()` 将 `address(0)` 归一化为 WBNB。这样，ERC-20 池与原生币 V4 池可以出现在同一条多跳路径中。

需要注意：

- BNB 与 WBNB 在路径注册表中被视为同一资产端点。
- `BNB -> WBNB` 和 `WBNB -> BNB` 不需要路径，`swapExactInput` 直接调用 WBNB 的 `deposit/withdraw`，兑换比例为 1:1。
- V4 一跳输出原生 BNB 后，Router 会先包装成 WBNB，便于交给下一跳；如果下一跳要求原生 BNB，则在执行该跳前再解包。

## 3. 部署与不可变信任边界

构造函数：

```solidity
constructor(
    address wrappedNative_,
    address pancakeV3Router_,
    address[] memory v2Routers_,
    address[] memory v2Factories_,
    address[] memory v3Factories_,
    address[] memory uniswapV4Managers_,
    address[] memory pancakeV4CLManagers_,
    bytes memory initialConfig_
)
```

| 参数 | 用途 |
| --- | --- |
| `wrappedNative_` | 当前链的包装原生币，例如 BSC 的 WBNB |
| `pancakeV3Router_` | 执行 V3 单池交易的 PancakeSwap SmartRouter |
| `v2Routers_` | 每个受信任 V2 factory 对应的 Router02 执行器 |
| `v2Factories_` | 允许登记价格池的 V2 factories |
| `v3Factories_` | 允许登记价格池的 V3 factories |
| `uniswapV4Managers_` | 允许登记和执行的 Uniswap V4 PoolManagers |
| `pancakeV4CLManagers_` | 允许登记和执行的 PancakeSwap Infinity CL PoolManagers |
| `initialConfig_` | `abi.encode(InitialPricePool[], InitialRoute[])`；为空时不初始化池和路径 |

构造阶段会验证：

- 所有地址必须有合约代码。
- V2 Router 返回的 `WETH()` 必须等于 `wrappedNative`。
- V2 Router 返回的 factory 必须在 `v2Factories_` 中，并且一个 factory 只能绑定一个 Router。
- Pancake V3 Router 返回的 `WETH9()` 必须等于 `wrappedNative`。
- Pancake V3 Router 返回的 factory 必须有代码且位于 `v3Factories_` 中。
- 每个 Pancake V4 CL Manager 的 Vault 必须是有效合约；Router 会同步登记允许回调和转入原生币的 Vault。

DEX 基础依赖完成校验后，构造函数会把 `initialConfig_` 中的平台初始池和路径直接写入存储。该路径只用于一次性的可信部署配置，不重复执行池身份、流动性和路径拓扑校验，以避免把 15 个池和 29 条路径拆成 44 笔管理交易。部署脚本必须在创建 Router 前校验全部真实池，并在创建后验证链上保存的路径和双向报价。部署完成后的 `addPricePool`、`replacePricePool`、`addRoute` 和 `replaceRoute` 仍执行完整校验。

这些 DEX factory、manager、Router 和 wrapped-native 地址部署后不能修改。owner 只能管理池和路径，不能把新的 DEX 执行器加入现有 Router。若要支持新的 factory、manager 或新的交易实现，需要部署新版 Router。

V2 允许名单与交易执行器也是分开的：位于 `v2Factories_` 但没有对应 `v2Routers_` 的 factory 可以用于池登记和询价，但其池在交易时会因找不到绑定 Router 而回退。

V3 还有一个重要区别：`v3Factories_` 中的其他 factory 可以用于登记和询价，但当前交易实现只允许使用 `pancakeV3Router_` 自己返回的 `pancakeV3Factory`。来自其他 V3 factory 的池不能通过本合约执行交易。

Router 继承 `Ownable2Step`：部署者初始为 owner，所有权转移需要新 owner 再调用 `acceptOwnership()`。生产环境不应调用 `renounceOwnership()`，否则将永久失去池和路径维护能力。

## 4. 支持的池类型

`SourceType` 当前有四种：

| 类型 | `sourceData` 编码 | 询价 | 交易 |
| --- | --- | --- | --- |
| `V2_PAIR` | `abi.encode(factory, pair)` | 储备金比例 | 绑定到该 factory 的 Router02 |
| `V3_POOL` | `abi.encode(factory, pool)` | 当前 `sqrtPriceX96` | 配置的 Pancake V3 SmartRouter |
| `UNISWAP_V4` | `abi.encode(UniswapV4Source)` | PoolManager 当前 slot0 | PoolManager `unlock` 回调 |
| `PANCAKE_V4_CL` | `abi.encode(PancakeV4CLSource)` | CL PoolManager 当前 slot0 | Infinity Vault `lock` 回调 |

### 4.1 V2_PAIR

来源结构：

```solidity
abi.encode(address factory, address pair)
```

认证过程：

1. factory 必须在 `allowedV2Factory` 中。
2. pair 必须有合约代码。
3. `factory.getPair(tokenIn, tokenOut)` 必须等于 pair。
4. `pair.factory()` 必须等于 factory。
5. 两边储备金都必须非零。

即时报价公式：

```text
amountOut = amountIn × reserveOut ÷ reserveIn
```

该报价只是储备金现货比例，不扣 V2 fee，也不计算恒定乘积曲线上的价格冲击。真实交易通过 Router02 的 `swapExactTokensForTokens` 完成，单跳最小输出传 `0`，最终统一由 NutboxRouter 的 `amountOutMinimum` 保护。

V2 不直接支持 `address(0)`；原生币必须使用 WBNB，或由路径中的 V4 原生币池完成转换。

### 4.2 V3_POOL

来源结构：

```solidity
abi.encode(address factory, address pool)
```

认证过程：

1. factory 必须在 `allowedV3Factory` 中。
2. pool 必须有合约代码。
3. `pool.factory()` 必须等于 factory。
4. 使用池自身 `fee()` 查询 `factory.getPool(tokenIn, tokenOut, fee)`，结果必须等于 pool。
5. `sqrtPriceX96` 和流动性必须非零。

报价使用当前 `sqrtPriceX96`。交易使用配置的 Pancake V3 SmartRouter `exactInputSingle`。每跳 `amountOutMinimum` 和 `sqrtPriceLimitX96` 均为零，最终最小输出由 NutboxRouter 检查。

V3 不直接支持 `address(0)`，原生币端点使用 WBNB。

### 4.3 UNISWAP_V4

来源结构：

```solidity
struct UniswapV4Source {
    address poolManager;
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}
```

Router 按 Uniswap V4 PoolKey 字段计算 DEX pool ID，读取 slot0 和流动性。交易时：

1. Router 设置 `_activeCallback = poolManager`。
2. 调用 `poolManager.unlock(callbackData)`。
3. PoolManager 回调 `unlockCallback`。
4. 回调中重建 PoolKey 并以负的 `amountSpecified` 执行 exact-input swap。
5. 严格验证输入 delta 等于 `amountIn`，输出 delta 为正。
6. ERC-20 输入通过 `sync + transfer + settle` 结算；原生币通过带 value 的 `settle` 结算。
7. 使用 `take` 将输出取回 Router。

`unlockCallback` 只接受当前 `_activeCallback` 且在允许名单中的 PoolManager，回调携带的 `source.poolManager` 也必须等于 `msg.sender`。

### 4.4 PANCAKE_V4_CL

来源结构：

```solidity
struct PancakeV4CLSource {
    address currency0;
    address currency1;
    address hooks;
    address poolManager;
    uint24 fee;
    bytes32 parameters;
}
```

Router 按 PancakeSwap Infinity CL PoolKey 字段计算 pool ID，并从 CL PoolManager 读取 slot0 和流动性。

交易使用 Vault 锁机制：

1. 读取 manager 对应的 Vault。
2. 若 Vault 当前没有 locker，Router 设置 `_activeCallback = vault` 并调用 `vault.lock(data)`。
3. Vault 回调 `lockAcquired`，Router 验证 Vault、manager 及其绑定关系。
4. 回调中调用 CL PoolManager `swap`。
5. 严格验证输入、输出 delta。
6. ERC-20 通过 `vault.sync + transfer + settle` 支付，原生币使用带 value 的 `settle`。
7. 通过 `vault.take` 取回输出。

若 Vault 已经存在 locker，则直接在当前锁上下文中执行这一跳，不再次申请嵌套 lock。一个路径可以顺序包含多笔 V4 交易；每跳的 delta 都单独结清。

## 5. owner 管理函数

以下函数仅 owner 可调用。

### `addPricePool(SourceType sourceType, bytes sourceData)`

为一个尚未登记的代币对设置首个官方池，返回该代币对稳定的 Router 注册表 `poolId`。

执行步骤：

1. 从 DEX 合约或 V4 source 中读取两个真实端点。
2. 验证端点不同、ERC-20 有代码；只有 V4 可以有一个 `address(0)` 端点。
3. 用 `amountIn = 0` 调用价格库完成 factory/manager、池身份、初始化状态和流动性检查。
4. 将原生币归一化为 wrapped-native，对两个地址排序并计算稳定 pair ID。
5. 若该 A-B 槽位已经存在则以 `PricePoolAlreadyExists` 回退，即使提交的是另一种 DEX 或另一个具体池。
6. 写入当前官方池配置并触发 `PricePoolAdded`。

### `replacePricePool(SourceType sourceType, bytes sourceData)`

直接替换一个已登记代币对的当前官方池，并返回不变的稳定 pair ID。

新 source 必须完整通过与初次登记相同的 DEX 来源、端点、初始化和流动性验证。合约从新 source 自行读取 A-B 并定位现有槽位，因此不能通过该函数把 A-B 槽位改成 A-C。

替换只更新 `token0`、`token1`、`sourceType` 和 `sourceData`：

- `enabled` 保持不变。
- `routeReferences` 保持不变。
- 所有直接或间接引用该 pair ID 的路径保持不变。
- 后续所有 `quote` 和 `swapExactInput` 立即使用新池。
- 允许 V2→V3、V3→另一个 V3、V3/WBNB→V4/native 等跨类型替换，只要新来源已在构造时允许。

成功后触发 `PricePoolReplaced`。这是更换 A-B 具体官方池的标准操作，不应为了换池逐条调用 `replaceRoute`。

### `removePricePool(bytes32 poolId)`

删除整个代币对槽位。它必须存在且 `routeReferences == 0`，因此 owner 必须先删除或改变所有引用该代币对的路径。单纯更换 A-B 的具体池不需要也不应该删除槽位。

### `addRoute(address tokenIn, address tokenOut, bytes32[] poolIds)`

创建新默认路径。要求：

- 端点有效且不同（BNB 会先归一化为 WBNB）。
- 该 token pair 尚未存在路径。
- pair ID 数量为 1 到 5。
- 所有代币对槽位已登记且启用。
- 每一跳与上一跳连续。
- 不重复经过任何端点，避免环路。
- 最终到达目标代币。
- 每个代币对的当前官方池在当前方向仍能通过来源认证和初始化检查。

成功后，所有 pair ID 的 `routeReferences` 加一。

### `replaceRoute(address tokenIn, address tokenOut, bytes32[] poolIds)`

原子替换现有路径拓扑。新路径先完整验证，通过后才释放旧 pair ID 引用并写入新路径。只有中间代币发生变化时才需要它，例如把 `A→B→C` 改为 `A→D→C`；仅将 A-B 从 V3 换成 V4 应调用 `replacePricePool`。

### `removeRoute(address tokenIn, address tokenOut)`

删除路径并减少旧路径中每个 pair ID 的引用数。之后该端点对的询价和交易会以 `RouteNotFound` 回退。

## 6. 查询函数

### 部署配置与允许名单

| 函数 | 返回值 |
| --- | --- |
| `wrappedNative()` | 包装原生币地址 |
| `pancakeV3Router()` | V3 交易 Router |
| `pancakeV3Factory()` | V3 交易 Router 对应 factory |
| `v2RouterForFactory(factory)` | V2 factory 对应交易 Router，未配置则为零地址 |
| `allowedV2Factory(factory)` | 是否允许该 V2 factory 用于池认证和询价 |
| `allowedV3Factory(factory)` | 是否允许该 V3 factory 用于池认证和询价 |
| `allowedUniswapV4Manager(manager)` | 是否允许该 Uniswap V4 manager |
| `allowedPancakeV4CLManager(manager)` | 是否允许该 Pancake V4 CL manager |
| `allowedPancakeV4Vault(vault)` | 实现合约额外公开的 Vault 允许名单 getter |

### 池查询

```solidity
pricePoolId(address tokenA, address tokenB) returns (bytes32 poolId)
```

返回 A-B 的稳定 pair ID。顺序不影响结果；`address(0)` 与 `wrappedNative` 会得到同一个端点 ID。该函数只负责计算并验证端点，不要求对应槽位已经登记，是否存在应继续查询 `hasPricePool(poolId)`。

```solidity
hasPricePool(bytes32 poolId) returns (bool)
```

判断 Router 注册表中是否存在该代币对槽位。

```solidity
pricePool(bytes32 poolId)
    returns (
        bool enabled,
        uint32 routeReferences,
        address token0,
        address token1,
        SourceType sourceType,
        bytes sourceData
    )
```

返回该代币对当前官方池的全部注册信息。

### 路径查询

| 函数 | 说明 |
| --- | --- |
| `hasRoute(tokenIn, tokenOut)` | 查询端点对是否有默认路径 |
| `routePoolCount(tokenIn, tokenOut)` | 返回跳数 |
| `routePoolAt(tokenIn, tokenOut, index)` | 按请求方向返回指定位置的稳定 pair ID |
| `validateRoute(tokenIn, tokenOut)` | 验证当前路径仍存在且每一跳仍可读取；无返回值，失败则 revert |

`hasRoute` 等路径存储查询要求归一化后的两个端点不同。BNB/WBNB 是直接包装关系，不存在注册路径；对此应使用 `validateRoute`、`quote` 或直接按 1:1 处理，而不是调用 `hasRoute(address(0), wrappedNative)`。

### `quote(tokenIn, tokenOut, amountIn)`

沿当前默认路径逐跳读取即时现货比例，并把上一跳的原始整数输出作为下一跳输入。

- 输入输出相同的包装资产（BNB/WBNB）时返回 `amountIn`。
- `amountIn == 0` 可用于只验证路径。
- 非零输入最终得到零输出时回退。
- 不读取 ERC-20 `decimals()`，也不要求所有代币为 18 位。池中价格本身以各代币最小单位表达，因此不同精度会自然体现在储备金或 `sqrtPriceX96` 中。
- 每跳使用向下取整的整数运算，多跳会逐跳累积取整误差。
- 结果不含 DEX fee、价格冲击和滑点，不能直接作为无容差的真实成交最小值。

V3/V4 的平方根价格计算分成 `sqrtPriceX96 <= uint128.max` 与更大值两条分支，分别使用 Q192 或 Q128 比率及 OpenZeppelin `Math.mulDiv`，避免中间乘法溢出。

### `quoteNative(token, tokenAmount)`

返回指定数量 token 按当前路径折算的 WBNB/原生币数量。token 已经是 WBNB 或 `address(0)` 时按 1:1 返回；其他代币必须存在到 WBNB 的路径。

## 7. 交易函数

### `swapExactInput`

```solidity
function swapExactInput(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOutMinimum,
    address recipient,
    uint256 deadline
) external payable returns (uint256 amountOut);
```

参数：

| 参数 | 说明 |
| --- | --- |
| `tokenIn` | 输入 ERC-20；原生 BNB 使用 `address(0)` |
| `tokenOut` | 输出 ERC-20；原生 BNB 使用 `address(0)` |
| `amountIn` | 精确输入数量，必须大于零 |
| `amountOutMinimum` | 整条路径的最终最小输出 |
| `recipient` | 最终收款人，不能是零地址或 Router 本身 |
| `deadline` | 交易最晚时间，进入函数时必须尚未过期 |

原生币 value 规则：

- `tokenIn == address(0)`：`msg.value` 必须精确等于 `amountIn`。
- ERC-20 输入：`msg.value` 必须为零，调用方必须提前 approve Router。

执行流程：

1. `nonReentrant` 锁定整笔外部交易。
2. 验证 deadline、输入数量和 recipient。
3. 若是 BNB/WBNB 直接转换，则执行 1:1 包装或解包并返回。
4. 收取精确输入；通过 Router 余额差确认实际到账等于 `amountIn`。
5. 读取交易执行时的当前 owner-managed route。
6. 逐跳确定池的实际方向并执行对应 DEX 交易。
7. 确认最终代币等于请求的 `tokenOut`。
8. 检查最终 `amountOut >= amountOutMinimum`。
9. 将输出发送给 recipient；ERC-20 使用 recipient 余额差验证完整到账。
10. 触发 `SwapExecuted`。

调用方不能传入 path，也没有 `expectedRouteHash`。owner 在交易上链前更换官方池或替换路径时，该交易会使用执行时的最新配置。安全保护来自：平台只登记审核池、输出端点固定、交易原子执行，以及调用方设置的最终 `amountOutMinimum`。对配置变化敏感的调用方应使用较短 deadline 和合理的最小输出。

每一跳内部不设最小输出；V4 使用接近全价格区间的 sqrt-price limit。任何一跳失败、最终输出不足或余额验证失败，整笔交易都会原子回退。

## 8. 内部实现索引

### 路径存储和验证

| 函数 | 作用 |
| --- | --- |
| `_routeKey` | BNB/WBNB 归一化、端点排序、计算唯一 key、返回请求是否为正向 |
| `_setRoute` | 验证并创建路径 |
| `_storeRoute` | 按 canonical 方向保存稳定 pair IDs 并增加引用数 |
| `_validateRoute` | 检查跳数、池状态、连续性、无环和最终端点 |
| `_releaseRoutePools` | 减少引用数并清空旧 pair IDs |
| `_copyRoutePoolIds` | 为事件复制 canonical pair ID 数组 |
| `_nextToken` | 根据当前归一化端点确定下一端点 |
| `_actualPoolDirection` | 将归一化路径方向还原为池实际的 ERC-20/`address(0)` 方向 |

### 询价

| 函数 | 作用 |
| --- | --- |
| `_quote` | 正向或反向遍历当前路径，逐跳复合报价 |
| `NutboxSpotPrice.quote` | 分派到具体 DEX 价格读取器 |
| `NutboxSpotPrice.sourceTokens` | 从来源数据读取真实 token0/token1 |
| `NutboxSpotPrice.otherToken` | 给定一个池端点，返回另一端点 |
| `_quoteV2/_quoteV3/_quoteUniswapV4/_quotePancakeV4CL` | 来源认证、初始化检查和现货比例计算 |
| `_quoteAtSqrtPrice` | 安全地将 Q96 平方根价格转换为原始整数报价 |

### 交易执行

| 函数 | 作用 |
| --- | --- |
| `_receiveInput` | 收取 ERC-20 或包装原生币，并拒绝到账不足 |
| `_executeRoute` | 遍历当前路径并把每跳输出交给下一跳 |
| `_executePool` | 按 `SourceType` 分派执行器 |
| `_swapV2` | Router02 单池 exact-input |
| `_swapV3` | Pancake SmartRouter `exactInputSingle` |
| `_swapUniswapV4` | 发起 PoolManager unlock 周期 |
| `_swapPancakeV4` | 发起或复用 Infinity Vault lock 周期 |
| `_executePancakeV4Swap` | 在有效 Vault 锁内完成 CL swap、settle 和 take |
| `_swapWrappedNative` | BNB/WBNB 1:1 转换 |
| `_deliverOutput` | 将 ERC-20 或解包后的原生币发送给 recipient |

### V4 回调与结算

| 函数 | 作用 |
| --- | --- |
| `unlockCallback` | Uniswap V4 回调入口，仅接受当前激活的允许 manager |
| `lockAcquired` | Pancake V4 Vault 回调入口，仅接受当前激活且允许的 Vault |
| `_validateUniswapV4Delta` | 验证 exact-input delta 和正输出 |
| `_validatePancakeV4Delta` | 验证 exact-input delta 和正输出 |
| `_settleUniswapV4` | 支付 Uniswap V4 ERC-20/原生币债务 |
| `_settlePancakeV4` | 支付 Infinity Vault ERC-20/原生币债务 |
| `_prepareV4NativeInput` | V4 原生币输入前将持有的 WBNB 解包 |
| `_verifyAndWrapV4Output` | 验证 V4 输出余额；原生输出重新包装为 WBNB |

### 部署认证辅助

| 函数 | 作用 |
| --- | --- |
| `_allow` | 验证合约代码并写入 factory/manager 允许名单 |
| `_configureV2Routers` | 认证 V2 Router、factory 与 wrapped-native 的绑定 |
| `_configurePancakeV4Vaults` | 从 CL managers 读取并允许对应 Vault |
| `_validEndpoint/_validPoolTokens` | 验证 ERC-20 合约和原生币池端点 |
| `_validatePricePool` | 读取新 source 的真实端点并验证来源、初始化和流动性 |
| `_pricePoolId` | 归一化并排序两个端点，计算不随具体 DEX 池变化的稳定 pair ID |

## 9. 事件

| 事件 | 触发时机 |
| --- | --- |
| `PricePoolAdded` | owner 为一个新代币对登记首个官方池 |
| `PricePoolReplaced` | owner 更换代币对的当前官方池；pair ID 和路径引用不变 |
| `PricePoolRemoved` | owner 删除无引用的代币对槽位 |
| `RouteAdded` | owner 新建路径，携带 canonical pair IDs 和 route hash |
| `RouteReplaced` | owner 原子替换路径 |
| `RouteRemoved` | owner 删除路径 |
| `SwapExecuted` | 任意调用方成功完成交易 |

`RouteAdded/RouteReplaced` 的 `routeHash` 是：

```solidity
keccak256(abi.encode(canonicalPairIds))
```

该 hash 用于链下索引和识别事件中的配置，不会要求交易调用方提交或锁定它。

## 10. 回退错误

### Router 错误

| 错误 | 含义 |
| --- | --- |
| `InvalidAddress` | 构造参数不是有效合约 |
| `InvalidSource` | factory、manager、Router、Vault 或池身份认证失败 |
| `UnsupportedSource` | 未支持的来源枚举 |
| `InvalidPair` | 池端点、顺序或原生币使用不合法 |
| `PoolNotInitialized` | 池价格或流动性/储备金尚未初始化 |
| `PriceUnavailable` | 非零输入无法得到输出，或低于最终最小输出 |
| `InvalidRoute` | 端点、跳数、连续性、环路或终点不合法 |
| `PricePoolAlreadyExists` | 该归一化代币对已经拥有官方池，应调用 `replacePricePool` |
| `PricePoolNotFound` | 代币对槽位不存在或已禁用 |
| `PricePoolInUse` | 仍有路径引用该代币对槽位，不能删除 |
| `RouteAlreadyExists` | 该端点对已有路径 |
| `RouteNotFound` | 当前默认路径不存在 |
| `InvalidAmount` | 输入为零或 V4 exact-input 超过 int128 可表示范围 |
| `InvalidNativeValue` | `msg.value` 与输入类型/数量不匹配 |
| `InvalidRecipient` | recipient 为零地址或 Router |
| `DeadlineExpired` | 进入交易时已超过 deadline |
| `UnsupportedSwapSource` | 来源可询价但没有可用交易执行器 |
| `UnsupportedInputToken` | 实际到账数量不等于 exact input |
| `InvalidSwapOutput` | DEX 返回值、余额差、delta 或转给 recipient 的数量不一致 |
| `InvalidNativeSender` | 未授权地址直接向 Router 发送原生币 |
| `InvalidCallback` | V4 callback 调用者或上下文不匹配 |

价格库也定义了同名或同类的 `InvalidSource`、`UnsupportedSource`、`InvalidPair`、`PoolNotInitialized`、`PriceUnavailable`。其 selector 按库错误签名产生；集成测试应匹配实际抛出错误的定义。

此外，owner 管理函数可能抛出 OpenZeppelin `Ownable` 错误，ERC-20 操作可能抛出 `SafeERC20` 或代币自身错误，DEX 调用也会透传对应协议的回退。

## 11. 权限与安全模型

### 11.1 owner 信任

owner 可以立即更换任意代币对的官方池，也可以新增、替换或删除默认路径，所以使用方信任 owner：

- 只登记真实、经过审核且具有合理流动性的池。
- 不把官方池或路径切换到经济上恶意但技术上有效的来源。
- 正确管理两步所有权转移。
- 在删除池前先安全迁移依赖路径。

Router 会认证池确实来自构造时允许的 factory/manager，但不会判断代币经济价值、流动性是否足够、价格是否合理或 hook 是否具有恶意经济行为。

### 11.2 即时价格风险

所有报价均来自当前池状态，没有 TWAP、预言机偏差检查和操纵保护。低流动性池可被闪电贷或同区块交易显著改变。该 Router 适合平台审核的大型基础资产路径；把 `quote` 用于借贷清算、抵押率或其他高风险定价前，需要在上层增加独立风险控制。

### 11.3 滑点、官方池与路径变化

`amountOutMinimum` 只保护最终数量，不固定当前官方池或中间路径。owner 在交易进入区块前调用 `replacePricePool` 或 `replaceRoute` 时，交易会使用执行时的最新配置。调用方应在链下或交易前调用 `quote`，再根据业务风险设置折扣后的最小输出。因为 spot quote 不含 fee 和 price impact，不能把 `quote` 原值直接作为 `amountOutMinimum`。

### 11.4 重入与回调

- 外部交易入口有 `nonReentrant`。
- `_activeCallback` 将 V4 回调绑定到当前 manager 或 Vault。
- callback 同时检查构造时的允许名单、source 中的 manager 和 manager/Vault 绑定。
- 向最终原生币 recipient 转账时仍处于重入锁内。
- unsolicited callback 会以 `InvalidCallback` 回退。

### 11.5 代币余额验证

- 输入用 Router 余额差验证 exact input。
- V2/V3 输出用 Router 余额差验证 DEX 返回值。
- V4 输出用 native/ERC-20 余额差和 delta 双重验证。
- ERC-20 最终交付用 recipient 余额差验证。
- 每次 V2/V3 调用只批准本跳精确数量，执行后将 allowance 清零。

这些约束会主动拒绝 fee-on-transfer、销毁税、反射、部分成交或返回值与真实到账不一致的代币。

### 11.6 原生币接收限制

`receive()` 只接受以下来源：

- WBNB 的 `withdraw`。
- 构造时允许的 Uniswap V4 PoolManager。
- 构造时允许 manager 对应的 Pancake Infinity Vault。

普通账户不能直接向 Router 转入 BNB。交易原生输入必须通过 `swapExactInput{value: amountIn}`。

### 11.7 资产留存

正常成功交易的设计目标是：输入被 DEX 消耗，输出全部发给 recipient，Router 不长期持有 ERC-20、WBNB 或 BNB。合约当前没有 rescue/sweep 方法：误转 ERC-20、外部协议异常产生的 dust，或通过授权来源意外转入的原生币可能永久留在合约中。集成方不应预先向 Router 转币，而应使用 approve + `swapExactInput`。

## 12. 集成示例

### 12.1 owner 登记 V3 池和双向路径

```solidity
INutboxRouter router = INutboxRouter(routerAddress);

bytes32 spcxUsdtPairId = router.addPricePool(
    INutboxRouter.SourceType.V3_POOL,
    abi.encode(pancakeV3Factory, spcxUsdtPool)
);

bytes32[] memory pools = new bytes32[](1);
pools[0] = spcxUsdtPairId;
router.addRoute(spcx, usdt, pools);

// 不需要再添加 usdt -> spcx；同一路径自动支持反向。
```

### 12.2 不修改路径，直接更换 A-B 官方池

```solidity
bytes32 stablePairId = router.replacePricePool(
    INutboxRouter.SourceType.V3_POOL,
    abi.encode(pancakeV3Factory, newSpcxUsdtPool)
);

require(stablePairId == spcxUsdtPairId);
// 所有包含 SPCX/USDT 的已有路径现在都自动使用 newSpcxUsdtPool。
```

若要从 V3/WBNB 换成 V4/BNB，只需将经过允许的 V4 source 编码后传给同一函数；BNB/WBNB 归一化保证返回的 pair ID 不变。

### 12.3 读取报价

```solidity
uint256 usdtOut = router.quote(spcx, usdt, 1 ether);
uint256 spcxOut = router.quote(usdt, spcx, 100 ether);
uint256 nativeValue = router.quoteNative(spcx, 1 ether);
```

### 12.4 ERC-20 精确输入交易

```solidity
IERC20(spcx).approve(address(router), amountIn);

uint256 amountOut = router.swapExactInput(
    spcx,
    usdt,
    amountIn,
    minUsdtOut,
    recipient,
    block.timestamp + 300
);
```

### 12.5 原生 BNB 输入

```solidity
uint256 amountOut = router.swapExactInput{value: amountIn}(
    address(0),
    usdt,
    amountIn,
    minUsdtOut,
    recipient,
    block.timestamp + 300
);
```

### 12.6 原生 BNB 输出

```solidity
IERC20(usdt).approve(address(router), amountIn);

uint256 bnbOut = router.swapExactInput(
    usdt,
    address(0),
    amountIn,
    minBnbOut,
    payableRecipient,
    block.timestamp + 300
);
```

若 recipient 是合约且接收原生 BNB，该合约必须实现可接收 BNB 的 `receive` 或 payable fallback。

## 13. BSC 配置

BSC 主网配置位于 [`script/config/BSCNutboxRouterConfig.sol`](../../script/config/BSCNutboxRouterConfig.sol)。当前配置以 PancakeSwap V3 USDT/WBNB 为 hub，并为 ETH、BTCB、QQQB、SPCXB、AAPLB、SKHYB、SPYB、XAUt、NVDAB、TSLAB、MSFTB、HOODB、BABAB 和 GMEB 建立到 USDT、WBNB 的双向路径。`initialConfig()` 将 15 个价格池和 29 条路径编码后交给 Router 构造函数，因此部署时原子写入全部配置，不需要部署后逐笔调用管理接口。

配置库只是部署期工具，不属于 Router 的运行时代码。生产部署完成后，真实状态以 Router 链上 `pricePool`、`routePoolCount`、`routePoolAt` 和相关事件为准。

## 14. 测试

单元测试：[`test/unit/NutboxRouter.t.sol`](../../test/unit/NutboxRouter.t.sol)

覆盖内容包括：

- V2 池登记和双向报价。
- 构造函数可信配置一次性初始化池、路径和引用计数。
- 多跳报价复合和反向池顺序。
- 同一代币对不能同时登记多个具体池。
- V2/V3/V4 官方池替换保持 pair ID 和全部路径不变，并立即影响询价和交易。
- 新池未初始化或没有流动性时替换回退，原官方池配置保持不变。
- 只有路径拓扑变化时才替换路径。
- ERC-20、原生 BNB、WBNB 输入输出。
- V2、V3、Uniswap V4、Pancake V4 和四种来源混合路径交易。
- V4 callback 身份检查。
- 五跳上限、断裂路径、环路及超长路径拒绝。
- owner 权限、池引用保护、未审核及未初始化池拒绝。
- deadline、`msg.value` 和输入输出余额检查。

BSC 主网 fork 测试：[`test/fork/BSCForkNutboxRouter.t.sol`](../../test/fork/BSCForkNutboxRouter.t.sol)

覆盖内容包括：

- 配置中的真实池均为 canonical、已初始化且具有流动性。
- 所有目标资产到 USDT/WBNB 的双向真实报价。
- 两跳报价与两个真实池逐跳组合一致。
- 通过官方 Pancake V3 SmartRouter 执行真实两跳交易。
- 通过官方 Pancake V2 Router 执行双向交易。
- 通过 Pancake V4 Vault callback 执行原生币双向交易。
- 将同一代币对替换为另一真实 canonical 池后，两条引用路径均保持不变并立即使用新池。

常用命令：

```bash
FOUNDRY_ETH_RPC_URL="" forge test --match-path test/unit/NutboxRouter.t.sol
FOUNDRY_PROFILE=fork forge test --match-path test/fork/BSCForkNutboxRouter.t.sol --fork-url "$BSC_RPC_URL" -vv
forge build --sizes
```

fork 测试需要设置 `BSC_RPC_URL`，并使用 `fork` profile 将执行链 ID 设为 BSC 56。本仓库 default profile 的 `eth_rpc_url` 指向本地 Anvil，所以本地纯单元测试命令显式清空该默认值。

## 15. 上线前检查清单

部署时：

1. 核对 WBNB、初始池、初始路径和全部 DEX 官方合约地址。
2. 确认 V2 Router 与 factory 一一对应。
3. 确认 Pancake V3 SmartRouter 的 factory 和 WETH9 返回值。
4. 确认 V4 manager 对应正确 Vault。
5. 运行单元测试、BSC fork 测试、部署 dry-run 和合约大小检查。

配置池时：

1. 核对 sourceData 的编码类型和字段顺序。
2. 核对池端点、fee、hooks、tick spacing 或 parameters。
3. 检查真实流动性与价格合理性，而不仅是合约验证通过。
4. 确认每个归一化代币对只登记一个当前官方池，再按实际交易顺序添加稳定 pair IDs。
5. 正反向分别调用 `quote` 和 `validateRoute`。

更换某个代币对的官方池时：

1. 核对新 source 的端点与原 pair ID 完全一致，包括 BNB/WBNB 归一化关系。
2. 在 fork 环境验证新池的身份、流动性、正反向询价和真实交易。
3. 调用 `replacePricePool` 原子覆盖当前官方池，不修改任何路径。
4. 监听并核对 `PricePoolReplaced`，确认返回 pair ID、`routeReferences` 和 `routePoolAt` 均未变化。
5. 小额验证所有依赖路径已自动使用新池。

只有路径中间代币发生变化时才调用 `replaceRoute`，例如把 `A→B→C` 改成 `A→D→C`。此时应先登记新路径涉及的代币对，再原子替换路径并核对 `RouteReplaced` 事件中的 canonical pair IDs。
