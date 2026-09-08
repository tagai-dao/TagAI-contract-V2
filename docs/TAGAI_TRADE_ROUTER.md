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
function buy(address token, Leg[] legs, uint256 minTokenOut, uint256 deadline, address recipient)
    external payable returns (uint256 tokenOut);
function sell(address token, uint256 amountIn, Leg[] legs, uint256 minBnbOut, uint256 deadline, address recipient)
    external returns (uint256 bnbOut);
```

所有数量均为最小单位整数；不要使用 JS Number。`deadline` 是 Unix 秒。
`recipient` 是最终输出接收者，退款始终退给调用者。

| routeIndex | 买入 | 卖出 | Nutbox 路由哈希参数 |
| --- | --- | --- | --- |
| 0 | Nutbox 注册的 BNB → T 路由，正常为 V4 主池 | T → BNB | 买入 `(0, T)`；卖出 `(T, 0)` |
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

## 资金与事件

交易腿和顶层最低到账任何一项不满足，所有 swap、税款和中间动作一起回滚。
Nutbox 授权仅开放本次所需金额，调用后归零。卖出后的未用 T、中间 A，买入后的
未用 BNB 都返回调用者；最终输出交付 recipient。交易前已经存在的执行器余额
不用于交易、不计入输出，也不允许后续调用者领取。

`LegExecuted` 记录各腿实际投入和实际输出。`TradeExecuted` 记录：

- token、payer、recipient、isBuy；
- amountIn：提交的总投入；amountOut：实际最终到账；
- refundAmount：退回的输入币数量（买入为 BNB，卖出为 T）；
- planHash：`keccak256(abi.encode(legs))`。

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

fork 测试复用 Pump13Mainnet 的固定区块与真实 BSC DEX/资产/质押 Factory，Pump、Hook、
Basket 和执行器在 fork 内部署。没有运行在生产网络上；该测试也不等于独立安全审计。

2026-09-08 验证结果：22 项单元测试通过，其中模糊测试执行 4096 次；上述四项 fork
测试全部通过，无跳过。部署脚本编译及新增 Solidity 文件格式检查通过。

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
