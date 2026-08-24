# Imported Token 导入与交易

当前实现由两个合约组成：

| 合约 | 功能 |
| --- | --- |
| `ImportHelper` | 创建 Community 和 SocialCuration Pool，并把 token 绑定到该 Community |
| `ImportedTokenSwapWrapper` | 接收每笔交易的外部池信息，完成报价、买卖、费用分配和 Nutbox 注入 |

## 导入流程

用户调用：

```solidity
function createCommunityAndPool(
    address token,
    address existingCommunity
)
    external
    payable
    returns (address community, address pool);
```

执行顺序：

所有分支首先调用 Wrapper 的 `getImportedMarket(token)`。如果 token 已经绑定 Community，
交易以 `TokenAlreadyImported` 回退，不会创建新 Community，也不会覆盖原登记信息。

`existingCommunity == address(0)` 时：

1. 使用外部 ERC20 创建不可增发的 Nutbox Community。
2. Reward Calculator 固定为 Helper 构造时配置的 `HourlyTickCalculator`。
3. Distribution policy 固定为空 bytes。
4. 将 Community 的 `devFund` 设置为调用者。
5. 创建 100% reward allocation 的 SocialCuration Pool。
6. 在 Wrapper 登记 token、Community 和部署者。
7. 将 Community ownership 转给调用者。
8. 退回超过 Community 创建费和设置费的 BNB。

`existingCommunity != address(0)` 时：

1. 检查该地址是配置的 CommunityFactory 创建的合法 Community。
2. 检查 Community 的 community token 等于导入 token。
3. 检查 Community 的 Reward Calculator 等于配置的 `HourlyTickCalculator`。
4. 直接在 Wrapper 登记 token、Community 和调用者。
5. 不创建新 Community，不创建 SocialCuration Pool。
6. 不收 Community 创建费或设置费，传入的 BNB 全额退回。
7. 返回已有 Community 地址，返回的 pool 为 `address(0)`。

整个流程是原子交易，任一步失败都会整体回退。

### ImportHelper 构造参数

```solidity
constructor(
    address communityFactory,
    address socialCurationFactory,
    address committee,
    address hourlyTickCalculator,
    address swapWrapper
);
```

## Wrapper 登记信息

ImportHelper 被设置为 Wrapper registrar 后调用：

```solidity
function registerImportedToken(
    address token,
    address community,
    address deployer
) external;
```

每个 token 保存：

```solidity
struct ImportedMarket {
    bool registered;
    address community;
    address deployer;
}
```

查询接口：

```solidity
function getImportedMarket(address token)
    external
    view
    returns (
        bool registered,
        address community,
        address deployer
    );
```

登记信息不包含 DEX、池地址、Router、Quoter 或 quoteToken。Wrapper owner 也可以调用
`registerImportedToken` 为历史 imported token 回填 Community 和部署者。

同一 token 只能登记一次。

登记后如需人工修正绑定，Wrapper owner 可以调用：

```solidity
function updateImportedMarket(
    address token,
    address community,
    address deployer
) external;
```

只修改 deployer 时不会影响该 token 已累计的 Nutbox 奖励。修改 Community 时要求
`pendingNutboxInjection(token) == 0`，防止把原 Community 已累计但尚未注入的奖励转给新
Community；切换成功后，该 token 的十分钟注入周期从当前时间重新计算。

## 每笔交易的 DEX 信息

报价和交易调用都提交本次使用的 `sourceType/sourceData`。Wrapper 直接使用该信息，不读取或保存固定池。

支持以下来源：

| SourceType | 数值 | sourceData |
| --- | ---: | --- |
| `V2_PAIR` | 0 | `abi.encode(V2Source)` |
| `V3_POOL` | 1 | `abi.encode(V3Source)` |
| `UNISWAP_V4` | 2 | 当前不支持 |
| `PANCAKE_V4_CL` | 3 | `abi.encode(PancakeV4Source)` |

### V2

```solidity
struct V2Source {
    address router;
    address pair;
}
```

### V3

```solidity
struct V3Source {
    address router;
    address quoter;
    address pool;
}
```

### Pancake Infinity CL

```solidity
struct PancakeV4Source {
    address quoter;
    INutboxRouter.PancakeV4CLSource pool;
}
```

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

Pancake Infinity 使用 `address(0)` 表示 native BNB。

## 交易路径

外部池为 `TOKEN/QQQB`，NutboxRouter 已配置 `QQQB → USDT → WBNB` 时：

```text
买入：BNB → NutboxRouter → QQQB → external pool → TOKEN
卖出：TOKEN → external pool → QQQB → NutboxRouter → BNB
```

外部池为 `TOKEN/WBNB` 或 Pancake Infinity `TOKEN/BNB` 时跳过 NutboxRouter bridge。

NutboxRouter 只处理已配置的核心 quoteToken 路径。Imported token 的外部池由每笔调用提供。

## 报价

```solidity
function quoteBuy(
    address token,
    INutboxRouter.SourceType sourceType,
    bytes calldata sourceData,
    uint256 nativeAmountIn
) external returns (uint256 tokenAmountOut);

function quoteSell(
    address token,
    INutboxRouter.SourceType sourceType,
    bytes calldata sourceData,
    uint256 tokenAmountIn
) external returns (uint256 nativeAmountOut);
```

- `quoteBuy` 返回扣除 BNB 费用和 Nutbox token fee 后的最终 TOKEN 数量。
- `quoteSell` 返回扣除 Nutbox token fee 和 BNB 费用后的最终 BNB 数量。
- 只有已登记 token 才收取 Nutbox token fee。
- 非 native quoteToken 使用 NutboxRouter 完成 bridge 报价。
- 前端通过 `eth_call/staticCall` 调用报价方法。
- V2 税币以及 V3 买入税币的报价是池子给出的税前理论值，无法预知代币合约的动态转账税；实际买入按最终到账余额差结算，前端滑点必须额外覆盖可能的多段转账税。

普通代币的前端最终滑点保护值：

```text
minimumFinalOut = quotedFinalOut × (10000 - slippageBps) / 10000
```

V2 fee-on-transfer token 应在 `slippageBps` 中同时覆盖价格影响、池费和代币可能在多段转账中收取的税。V3 允许税币作为买入输出，并按用户最终到账量检查滑点；V3 税币卖出以及 Pancake Infinity CL 税币仍不支持。

## 买入

```solidity
function buyToken(
    address token,
    INutboxRouter.SourceType sourceType,
    bytes calldata sourceData,
    uint256 minimumTokenOut,
    address recipient,
    uint256 deadline,
    address sellsman
) external payable returns (uint256 tokenOut);
```

执行顺序：

1. 从 gross BNB 扣除 0.2% sellsman/deployer fee。
2. 从 gross BNB 扣除 0.2% platform fee。
3. 使用剩余 BNB 完成 bridge 和外部池交易。
4. 已登记 token 从 gross TOKEN output 扣除 0.2% Nutbox token fee。
5. 将净 TOKEN 发送给 recipient。
6. 检查净 TOKEN 不低于 `minimumTokenOut`。
7. 将 Nutbox token fee 计入该 token 绑定 Community 的待注入余额。

## 卖出

```solidity
function sellToken(
    address token,
    INutboxRouter.SourceType sourceType,
    bytes calldata sourceData,
    uint256 amountIn,
    uint256 minimumNativeOut,
    address recipient,
    uint256 deadline,
    address sellsman
) external returns (uint256 nativeOut);
```

执行顺序：

1. 从用户接收 gross TOKEN。
2. 已登记 token 扣除 0.2% Nutbox token fee。
3. 使用剩余 TOKEN 完成外部池交易和 bridge。
4. 从 gross BNB output 扣除 0.2% sellsman/deployer fee。
5. 扣除 0.2% platform fee。
6. 将净 BNB 发送给 recipient。
7. 检查净 BNB 不低于 `minimumNativeOut`。
8. 将 Nutbox token fee 计入该 token 绑定 Community 的待注入余额。

## Sellsman 和部署者

- 交易传入非零 `sellsman` 时使用该地址。
- `sellsman == address(0)` 时，已登记 token 使用登记的部署者。
- 未登记 token 且 sellsman 为零时使用 platform feeAddress。
- subject 已创建当前 IPShare 时，通过 `IPShare.valueCapture` 分配 BNB fee。
- subject 未创建 IPShare 时，直接发送 BNB。
- 直接发送失败时，费用转入 platform feeAddress。

## 费用

默认费率：

| 费用 | 默认值 | 资产 | 归属 |
| --- | ---: | --- | --- |
| sellsman/deployer | 0.2% | BNB | IPShare valueCapture 或直接转账 |
| platform | 0.2% | BNB | feeAddress |
| Nutbox distribution | 0.2% | imported token | token 绑定的 Community |

Owner 可调用：

```solidity
setFeeRatios(
    uint16 sellsmanRatio,
    uint16 tagaiRatio,
    uint16 nutboxTokenRatio
);
```

费率单位为 basis points，`20 = 0.2%`。

## Nutbox 注入

每个已登记 token 独立维护：

```solidity
mapping(address => uint256) public pendingNutboxInjection;
mapping(address => uint256) public lastNutboxInjectionAt;
```

处理规则：

1. 每笔交易先检查是否存在满十分钟的 pending fee。
2. 满足时间条件时，将上一批 pending fee 注入登记 Community 的 Reward Calculator。
3. 当前交易产生的 token fee 加入下一批 pending fee。
4. 注入失败时保留 pending fee，当前交易继续执行。
5. 十分钟后任何地址都可以调用 `flushNutboxInjection(token)` 主动结算。

注入目标通过登记 Community 的 `rewardCalculator()` 获取。

## 部署

1. 部署 `ImportedTokenSwapWrapper`。
2. 部署新的 `ImportHelper`，构造参数传入 Wrapper 地址。
3. Wrapper owner 调用：

```solidity
setRegistrar(importHelperAddress);
```

部署脚本 `script/DeployImportHelper.s.sol` 会部署 Helper 并调用 `setRegistrar`。执行脚本的钱包必须是 Wrapper owner。

BSC 上替换 Wrapper 时使用 `script/DeployBSCImportedTokenSwapWrapper.s.sol`。该脚本会在同一批交易中：

1. 部署新的 Wrapper。
2. 部署指向新 Wrapper 的 ImportHelper。
3. 将新 Helper 设置为 registrar。
4. 从旧 Wrapper 只读并校验牛来、Bicat、QQQB 的 Community/deployer 绑定。
5. 将这三个历史绑定登记到新 Wrapper；不会重建 Community 或 SocialCuration Pool。
6. 根据显式的 `IMPORTED_WRAPPER_OWNER` 发起两步 ownership 交接。

旧 Wrapper 的 `pendingNutboxInjection` 不会也不能直接复制到新 Wrapper。切流前应记录旧
Wrapper 的 pending 数值，并在满足十分钟间隔后调用旧 Wrapper 的
`flushNutboxInjection(token)`；在全部旧 pending 结算前不要丢弃旧 Wrapper 地址。

脚本不会自动改写 `deployments/56/version11.json`。只有广播交易全部确认且链上校验通过后，
才应记录新的 Wrapper、Helper、交易哈希和区块号。

## 主要事件

ImportHelper：

- `CommunityCreated`
- `ImportedCommunityRecorded`

Wrapper：

- `ImportedMarketRegistered`
- `ImportedMarketUpdated`
- `ImportedTokenTrade`
- `Trade`
- `NutboxTokenFeeAccrued`
- `NutboxTokenFeeInjected`
- `NutboxTokenFeeInjectionFailed`

`ImportedTokenTrade` 中的 `sourceType/sourceHash/quoteToken` 记录本次交易实际提交和使用的外部池信息。

## 测试

```bash
forge test --match-path 'test/unit/Import*' -vv
```

测试覆盖：

- ImportHelper 固定 Calculator、设置 devFund 和登记 Community。
- 复用已有 Community 时的 Factory、token、Calculator 验证和零费用导入。
- Wrapper registrar 权限与重复登记保护。
- Wrapper owner 人工修正 Community/deployer，以及 Community 切换时的 pending 奖励保护。
- ImportHelper 在创建 Community 前拒绝已经绑定 Community 的 token。
- 已登记 token 使用不同外部池并向同一 Community 累积费用。
- V2、V3、Pancake Infinity CL 的报价和双向交易。
- native 与非 native quoteToken。
- 最终输出滑点保护。
- IPShare valueCapture 和直接转账。
- 十分钟批量注入、主动 flush 和失败保留。
- V2 fee-on-transfer 买卖、V3 fee-on-transfer 买入按实际到账结算、V3 fee-on-transfer 卖出拒绝、callback 防护和 EIP-170 code-size 检查。
