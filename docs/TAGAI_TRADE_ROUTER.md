# V13 BNB 聚合交易执行器

合约：`src/router/TagAITradeRouter.sol`。它是独立的交易执行器，不修改 Pump V13、
Token、NutboxRouter、Basket V4 或现有质押池。部署地址尚未生成。

## 职责与边界

前端负责发现候选池、计算资金分配与执行顺序、比较扣除 gas 后的结果，并模拟完整交易。
合约执行前端传入的拆单方案；支持 BNB 买 T，以及卖 T 收 BNB，两者各用一笔交易完成。
卖出前需要用户对执行器授权 T，首次授权可能是额外一笔交易。

支持已上市、由构造参数指定 Pump 创建，且基础设施快照匹配的 V13 Token。
内盘继续使用 Token 的买卖接口；pending 时禁止交易。旧版本不使用本执行器。
执行器没有平台加收费用、owner、升级入口、托管头寸或任意外部调用接口。

## 接口

```solidity
struct Leg {
    uint8 routeIndex;
    uint256 amountIn;
    uint256 minIntermediateOut;
    uint256 minAmountOut;
    bytes32 routeHash;
}

function routeHash(address tokenIn, address tokenOut) external view returns (bytes32);
function buy(address token, Leg[] legs, uint256 minTokenOut, uint256 deadline, address recipient, address subject)
    external payable returns (uint256 tokenOut);
function sell(address token, uint256 amountIn, Leg[] legs, uint256 minBnbOut, uint256 deadline, address recipient, address subject)
    external returns (uint256 bnbOut);
```

所有数量均为最小单位整数；不要使用 JS Number。`deadline` 是 Unix 秒。
`recipient` 是最终输出接收者，退款始终退给调用者。
`subject` 是 IPShare 主体地址（前端原 sellsman），不是 IPShare 合约地址，也不是 recipient。
主池买卖都传 `abi.encode(subject)` 给 Hook；零地址或未创建 IPShare 的主体沿用 Hook 的
Token.getIPShare() 回退规则。组件 V2 池不因此新增 IPShare 收费。

现有 NutboxRouter 的 swapExactInput 不支持 hookData，因此执行器直接锁定 V4 Vault
并调用主池。仅允许 Nutbox 注册的单跳原始上市池：PoolId、原生币/T、Hook、Manager、
Vault 必须与 Token 上市快照一致。回调绑定本次完整参数哈希，并且只能消费一次。
组件中转仍通过既有 NutboxRouter，现有 Pump、Hook、NutboxRouter 和矿池均无需改动。
本次 buy/sell ABI 增加参数，前端和 API 必须使用更新后的 ABI。

| routeIndex | 买入 | 卖出 | Nutbox 路由哈希参数 |
| --- | --- | --- | --- |
| 0 | Nutbox 注册且匹配 Token 快照的 V4 主池 BNB → T | T → BNB | 买入 `(0, T)`；卖出 `(T, 0)` |
| 1..N | BNB → 成分 A → T/A V2 池 → T | T/A V2 池 → A → BNB | 买入 `(0, A)`；卖出 `(A, 0)` |

`routeIndex=1` 对应 `Token.componentAt(0)`。最多四个组件池加主池，共五条交易腿。
数组顺序就是执行顺序，允许前端重排；每个 routeIndex 只能出现一次。
每条腿的 amountIn、minAmountOut 和 routeHash 必须非零。
组件腿的 minIntermediateOut 必须非零，主池腿必须为零。
未使用的腿直接省略，不能用零投入的占位腿。

买入：所有腿的 amountIn 合计必须等于 msg.value，计价为 BNB。
卖出：合计必须等于顶层 amountIn，计价为毛 T；合约只从调用者拉取这笔总额一次。
顶层最低到账必须非零，并以实际交付结果核验，不依赖外部路由返回的数字。

## 路由与报价

中转路线使用现有 Nutbox 注册路线，没有新增任意路径执行能力。执行器支持选择与拆分
V13 主池和组件池；每条腿内部的 BNB/A 中转仍以 Nutbox 当前注册路线为准。
routeHash 包含 chain ID、Nutbox 地址、方向、所有注册池 ID 和当前 sourceData。
管理员替换 sourceData，即使 ID 不变，也会使旧报价失效；失效时前端重新报价。
单条 Nutbox 路由最多八个注册池。哈希固定的是路线配置，不固定市场价格或流动性。

前端流程：

1. 在同一区块读取组件、各路径配置、价格和流动性。
2. 比较最佳单路径与多路径分配，统计全部中转池的费用和 gas。
   净收益相近时减少路径；多路径净收益更好时选择多路径，不机械平均分配。
3. 处理共享中转池的状态影响，按最终执行顺序模拟整个计划。
   `NutboxRouter.quote()` 是现货参考值，不能直接充当可执行成交报价。
4. 计算各腿最低中间到账、最低最终到账以及顶层最低到账，设置短 deadline。
5. 使用真实 from、value、授权状态，对 buy/sell calldata 做 eth_call 和 estimateGas。
   eth_call 的返回值为最终实际输出；只有模拟成功才请求钱包发送交易。
6. 报价过期、路线变动、链切换或余额变动时重新计算。模拟输出是当时状态的结果，
   最终执行仍由最低到账保护。

Pancake V2 手续费按 25 bps；V13 T 向组件 Pair 转入或转出另有 10 bps 销毁税。
输入按本次转账实际到池数量计算，输出按净到账计算；已有 Pair 捐赠不被算作本次投入。
外部 A 路径的执行能力沿用 NutboxRouter 的限制，不额外承诺任意税币或 rebase 币支持。

## 本地路由优化与数据批量读取

前端和 API 的 `bsc-version13` 分支已接入元数据接口、一次 aggregate3 状态读取和
Worker 本地寻优，具体实现和边界见两个项目的 `docs/bsc-v13-routing.md`。
当前优化器采用多起点粗分配与完整交易模拟微调；下文的水位法为独立路线的后续优化方向。

目标是以统一 BNB 口径比较扣除 gas 后的结果。买入比较 (输入 BNB + gas BNB) / 净 T；
卖出比较净 BNB - gas BNB。合约最低到账约束的是输出币数量，不包含另付的 gas。
不能使用固定边权的最短路径算法直接解决此问题：边的实际汇率随交易金额和状态变化。

- 区分物理池与候选路线。当前 V13 为最多四个组件池加一个主池；中转池另外计数，
  并可能被多条路线共用。若按六条候选路线扩展，非空组合仅 63 个，当前五条为 31 个。
- 静态缓存保存地址、PoolKey、decimals、费用规则和注册路径；以配置版本/路线哈希失效。
  每轮行情在明确 blockNumber 上刷新所有相关动态状态，额外读取必须固定同一区块。
- V2 的核心数据为 reserves，税币还需对应转账规则。V3/V4 需要 sqrtPrice、tick、liquidity、
  实际协议/LP/Hook 费用，以及可能跨越的 bitmap 和 initialized tick 的 liquidityNet。
  当前 V4 主池的固定 Hook 费按链上代码模拟；不能直接把普通 V3 报价器用于 Hook 池。
- API 提供完整路线、池子和 tick 列表及覆盖范围。前端一次 Multicall3 刷新当前状态，
  不做前置发现、补读或自动分包。覆盖范围外的数据不处理；范围内出现 API 未提供的
  初始化 tick 时排除依赖该池的路线。触及边界时限制分配量或改用其他路线，不能把
  未知区间当成没有流动性。API 限制响应规模，避免生成超大的读取请求。

独立路线可用边际收益均衡（水位法）求比例：对固定路线集合，最大化 sum(f_i(x_i))，
约束 sum(x_i)=总输入。连续、递增且凹的报价函数下，使用中的路线满足 f'_i(x_i)=lambda，
未使用路线的初始边际收益不高于 lambda。用二分搜索 lambda 求解，不逐个枚举百分比。
V2 的 f(x)=Rout*gamma*x/(Rin+gamma*x)，其导数可直接计算并反解投入；多跳要包含每跳
费用、转账税与整数舍入。V3/V4 按 tick 分段模拟，对候选解最后进行精确整数核算。
固定开启成本 gas 通过路线集合比较处理，不能只放进边际导数。gas 随跨 tick 数变化时，
先估算筛选，再对少量最终候选 estimateGas 比较。

存在共享池时，独立路线解只作为起点。每个候选必须用统一池状态按真实整腿执行顺序
模拟，不能把逐小份交错成交的结果直接当作合约整腿成交结果。保留几个优选起点，进行
路线间资金重新分配与相邻执行顺序交换；步长由粗到细，并设置迭代预算。始终保留最佳
单路线作为基准，不声称在任意共享池/Hook 状态下求得全局最优。

性能实现：在 Web Worker 中复用已解码池状态与报价曲线；以区块+路由版本+方向+金额
缓存结果；输入金额小幅变化时沿用前次解作为初值；旧请求用序号取消，避免覆盖新报价。
先展示可用的单路线结果，再发布经过优化和核验的方案。对少量候选执行 eth_call 和
estimateGas，使用真实 from/value/subject/授权状态，避免按“每条路线×每个比例”请求 RPC。
本地运算耗时与端到端 RPC 耗时分别测量；任何毫秒级目标在手机与桌面实测前都不是保证。

参考：
- [Multicall3 批量读取](https://github.com/mds1/multicall3#batch-contract-reads)
- [Uniswap 集中流动性池数据](https://developers.uniswap.org/docs/sdks/v3/guides/pool-data)
- [Uniswap Smart Order Router](https://github.com/Uniswap/smart-order-router)

## 资金与事件

交易腿和顶层最低到账任何一项不满足，所有 swap、税款和中间动作一起回滚。
Nutbox 授权仅开放本次所需金额，调用后归零。卖出后的未用 T、中间 A，买入后的
未用 BNB 都返回调用者；最终输出交付 recipient。交易前已经存在的执行器余额
不用于交易、不计入输出，也不允许后续调用者领取。

`LegExecuted` 记录各腿实际投入和实际输出。`TradeExecuted` 记录：

- token、payer、recipient、isBuy；
- amountIn：提交的总投入；amountOut：实际最终到账；
- refundAmount：退回的输入币数量（买入为 BNB，卖出为 T）；
- planHash：`keccak256(abi.encode(subject, legs))`。

`MainPoolExecuted` 额外记录主池交易请求的 subject、方向和金额。subject 是请求值，
实际回退后的归属以 IPShare 的 ValueCaptured 为准。计划哈希也包含 subject，不能继续
使用旧版仅对 legs 编码的哈希。

统计实际输入成本使用 `amountIn - refundAmount`；其他中间资产退款应结合 ERC20 日志。
组件成交和主池成交不能分别被当作用户多笔完整 BNB 交易重复计费。
后续 API 可用聚合事件展示整笔交易，再用 LegExecuted 或底层事件展示拆单明细。

## LP 加池与质押保持分开

现有 ERC20Staking ABI 只有 deposit(amount)、withdraw(amount)，没有受益人参数。
`test_tradeRouter_realStakingCreditsCallerNotOriginalUser` 使用真实 BSC Factory 生成的
矿池验证：中间合约调用 deposit 后，getUserStakedAmount(中间合约) 增加，原用户为零；
由原用户直接 deposit 时才记到原用户。

因此前端同页提供两步操作：先添加流动性，LP 直接交给用户钱包；然后用户授权矿池并
直接调用 deposit(amount)，附上实时读取的 pool operation fee。第二步取消或失败时，
LP 留在钱包，页面提供继续质押入口。不改矿池，也不使用中间合约代持用户质押。
本交易执行器不包含添加/移除流动性功能，该功能仍是后续前端和流动性工具的独立工作。

## 测试与部署

离线单元测试（覆盖双向税、两种 token 排序、五腿拆单、退款、捐赠隔离、滑点、
无效路由、路径变动、回滚、重入及模糊测试）：

```bash
FOUNDRY_ETH_RPC_URL='' forge test --match-contract '^TagAITradeRouterTest$' --fuzz-runs 4096 -vv
```

真实 BSC fork（需要 BSC_RPC_URL；不广播交易）：

```bash
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test \
  --match-contract '^TagAITradeRouterForkTest$' --match-test '^test_tradeRouter_' -vv
```

fork 测试同时核对真实 IPShare ValueCaptured 的主体与主池 Hook 收费金额，覆盖买卖及拆单。
fork 测试复用 Pump13Mainnet 的固定区块与真实 BSC DEX/资产/质押 Factory，Pump、Hook、
Basket 和执行器在 fork 内部署。没有运行在生产网络上；该测试也不等于独立安全审计。

2026-09-08 IPShare 修订验证：26 项单元测试（含 4096 次模糊输入）、七项 fork 测试
全部通过，无跳过。覆盖指定主体、零地址及无效主体回退、组件独立交易、主池回调鉴权
和上市池身份检查。真实 ValueCaptured 的主体及金额与对应主池 Hook 收费一致。

部署脚本：`script/DeployBSCTagAITradeRouter.s.sol`。默认绑定 version13.json 中的
Pump13、NutboxRouter 和官方 Pancake V2 Factory，先核验 Pump 当前配置。
只部署执行器，不改旧合约地址、权限或质押池。无需给执行器 Nutbox operator 权限，
swapExactInput 本身是公开接口。

先运行不带 broadcast 的模拟；需要正式发布时再单独执行带 broadcast 的命令：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script script/DeployBSCTagAITradeRouter.s.sol \
  --rpc-url "$BSC_RPC_URL"
```

脚本沿用 PRIVATE_KEY_MAIN。部署后记录地址、交易、区块、源码版本和验证结果，再将
地址写入前端/API 的 bsc-version13 配置。ABI 位于 `abis/TagAITradeRouter.json`，
应与 Foundry 当前产物一致。前端路由优化器和页面的完成状态不由本合约测试代表。
