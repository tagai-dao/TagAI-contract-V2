# V13 流动性执行器 TagAILiquidityRouter

源码：`src/router/TagAILiquidityRouter.sol`。BSC 部署地址为 `0x2868FDdf7F86041557257c55a79A382536401752`，已与本地成功广播回执核对；部署交易和区块记录在 [version13.json](../deployments/56/version13.json)。与交易执行器的完整部署/源码验证命令见 [BSC_V13_ROUTERS_DEPLOY.md](./BSC_V13_ROUTERS_DEPLOY.md)。

## 职责与依赖

辅助合约服务于已上市 V13 成分 V2 池，不修改 Pump、Token、NutboxRouter 或质押池。

构造参数只有已部署的 TagAITradeRouter 地址，由它派生 immutable `pump`、`nutboxRouter`、`factory`，并保存 immutable `tradeRouter`。合约没有 owner、升级入口、可配置平台费用或任意目标调用能力。

| 场景 | 操作路径 | 用户最终收到 |
| --- | --- | --- |
| 已有双资产添加流动性 | 两种资产授权给辅助合约，按当前储备和 Token13 税配比添加 | LP，及未使用的原资产 |
| 只支付 BNB 添加流动性 | 主池买 T → NutboxRouter 买成分 A → 添加 T/A 流动性 → 主池卖余量 T → Router 卖余量 A | LP 和 BNB 退款；极小零头可能原币返还 |
| 移除流动性 | LP 授权给辅助合约，直接从用户转入 Pair，burn 给用户 | 税后 T 和成分资产 A |

LP 直接发给调用者。现有矿池只为调用者记账，因此取得 LP 后，用户仍需单独授权 LP 并调用矿池 deposit；本合约不替用户质押。

## 接口

```solidity
function add(address token, uint256 index, uint256 tokenIn, uint256 assetIn,
    uint256 minLP, uint256 deadline) external returns (uint256 lp);

function remove(address token, uint256 index, uint256 lp,
    uint256 minToken, uint256 minAsset, uint256 deadline)
    external returns (uint256 tokenOut, uint256 assetOut);

struct Zap {
    address token;
    uint256 component;
    uint256 tokenBnb;
    uint256 minToken;
    uint256 minAsset;
    uint256 minLP;
    uint256 deadline;
    address subject;
    bytes32 mainRouteHash;
    bytes32 assetRouteHash;
    uint256 minTokenRefundRateX128;
    uint256 minAssetRefundRateX128;
}
function addWithBNB(Zap calldata z) external payable returns (uint256 lp);
```

`index/component` 是 `Token.componentAt` 的零起始位置，所有金额使用原始整数，deadline 使用 Unix 秒。

| Zap 参数 | 含义 |
| --- | --- |
| tokenBnb | msg.value 中用于主池购买 T 的 BNB；剩余 BNB 买成分资产；必须大于零且小于 msg.value |
| minToken / minAsset | 两笔购买的最低到账数量；均非零 |
| minLP | 用户实际 LP 余额增长的最低值；非零 |
| subject | IPShare 主体（原 sellsman），不是 IPShare 合约地址；主池买卖均传递 |
| mainRouteHash | TradeRouter.routeHash(0, T)，绑定报价时的主池路径 |
| assetRouteHash | TradeRouter.routeHash(0, A)，绑定报价时的成分资产路径 |
| minTokenRefundRateX128 | 每最小单位 T 的最低 BNB wei 输出，乘以 2^128；非零 |
| minAssetRefundRateX128 | 每最小单位 A 的最低 BNB wei 输出，乘以 2^128；非零 |

BNB 加池不接受前端传任意 legs 数组；辅助合约内部只构造一条 routeIndex=0 的交易腿，强制从主池买卖 T。成分资产的购买/卖出沿用 NutboxRouter 注册的正反向路径。用户独立的普通买卖仍可通过 TagAITradeRouter 多池聚合。

## 配比、税与 LP 报价

Token13 向成分 Pair 转入/转出时收取 `floor(amount/1000)` 的销毁税。add 按毛 T 计算税后到账，再按储备算 A；若 A 不足，反向计算合适的毛 T。多余资产不当作必须投入的金额。minLP 比较 Pair.mint 后用户实际 LP 余额增加。

前端无需额外合约 view 方法：先从 API 获得路由/池/tick 清单，单次 multicall 获取当前状态，Worker 固定两条购买路径并搜索资金比例。模拟买入后的净资产及储备，估算：

```text
LP ≈ min(净 T 投入 × LP 总量 / T 储备,
         A 投入 × LP 总量 / A 储备)
```

输入 BNB 停止 400 毫秒后自动显示预计 LP、滑点后的最低 LP、预计 BNB 退款；修改输入取消旧报价，滑点变更只更新本地最低值。预估不是成交保证，池子状态变化时以实际模拟和 minLP 检查为准。当前规则针对现有 Token13 税与已支持的池，不能直接用于税率不同的新版 Token。

## BNB 余量卖出与退款

先完成购买和 LP mint，再卖余量 T、卖余量 A。前端报价也按同一顺序复用池子状态，包含手续费、转账税及估算 Gas。余量可能与报价不同，所以不使用固定 BNB 退款数量作为每次卖出的下限，而是：

```text
minimumBnb = floor(实际余量 × minRefundRateX128 / 2^128)
```

前端以购买后状态下全量反向报价形成保守单位价格，再应用所选滑点；合约使用 Math.mulDiv 避免中间乘法溢出。卖出后核对实际 BNB 增量和原资产消费量，授权仅为当次数量，结束后归零。

minimumBnb 舍入不足 1 wei 时，不强行发起无法满足非零输出要求的兑换，而是原币退给用户并发出 DustRefund。正常兑换得到的 BNB 连同本次剩余 BNB 一起退给用户，NativeRefund 记录金额。

每一步以调用前余额为基线，不消耗合约已有的原生币或代币余额。购买、LP 下限、余量卖出下限或最终 BNB 转账失败，会让整笔交易回滚，包括 LP mint。

移除流动性检查用户真实税后到账；若 Pair 已持有别人转入的 LP，拒绝执行，以免 burn 混入这些 LP。

## 事件和失败处理

- LiquidityAdded：Token、Pair、用户和实际 LP 数量。
- LiquidityRemoved：Token、Pair、用户和两侧实际到账。
- NativeRefund：本次 BNB 退款。
- DustRefund：零头的资产及数量。

InvalidPool 表示来源、成分或路径不匹配；InvalidAmount 表示零值/非法比例；Slippage 表示实际到账不足；Expired 表示过期；TransferFailed 表示原生币转账失败。前端遇到状态变化应重新报价，不能把 minimum 直接降为零绕过检查。

## 测试与发布配置

```bash
FOUNDRY_ETH_RPC_URL='' forge test --match-path 'test/unit/TagAI*Router.t.sol'
```

本地测试覆盖税后 mint/burn、LP 下限回滚、配比 fuzz、固定主池购买、两侧余量卖出、退款不足回滚、路径/价格下限校验、零头、subject、LP 接收人、原有余额隔离。单元回归共 52 项通过，其中交易路由 26 项、流动性路由 13 项、既有回购路由 13 项；两个新合约自身为 39 项。主网钱包全流程验收仍需部署后进行。

前端 ABI：`../tiptag-ui/src/utils/v13/LiquidityRouter.json`，已与当前编译输出核对。两个地址直接配置在前端 `src/config/chains.ts` 的 BSC `contracts.tradeRouter13` / `liquidityRouter13`，无需 API 环境变量。链上绑定校验和用户独立质押流程保留。


2026-09-08 新增 BSC fork 集成测试 **10 项全部通过，0 失败、0 跳过**，固定区块 120508054。
真实 BSC 股票资产、Pancake V2/V3/Infinity、IPShare 和矿池配合本地部署的当前生产合约完成交易。
覆盖 T/股票两侧余量卖出、四成分池、六位精度 XAUt、LP 数量独立核算、税费/IPShare/退款对账、
原有余额隔离、用户独立质押/解押/移除，以及买入、LP 和退款下限失败的整笔回滚。
详见 [fork 测试报告与复现命令](../test/fork/TagAILiquidityRouter.md)。
