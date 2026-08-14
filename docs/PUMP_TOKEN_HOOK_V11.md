# Pump、Token 与 TagAISwapHook V11 更新说明

本文记录 BSC V11 已部署版本中 Pump 发行链路、社区 Token 和 PancakeSwap Infinity CL Hook 的实际行为。这里只描述已部署代码，不包含早期设计草案中的废弃方案。

## 1. 适用范围

V11 的新行为只适用于通过 V11 Pump 创建的新社区 Token：

- V9 及更早 Pump 已创建的 Token 是独立 clone，继续运行原有 Token implementation；
- 已创建的 PancakeSwap V4 PoolKey、Hook 和费率不会迁移；
- V11 不改变 ImportHelper V10 导入外部 ERC20 的流程；
- Pump 的 `feeRatio` 只用于上市前 bonding curve，上市后的费率由 V11 Token 和 TagAISwapHook 固定定义。

## 2. BSC 主网合约

| 合约 | 地址 |
| --- | --- |
| Pump | [`0x8fEF5b4c0f761a0cc447800e3019B089ac306F28`](https://bscscan.com/address/0x8fef5b4c0f761a0cc447800e3019b089ac306f28) |
| Token implementation | [`0xfD40C112F39D372786265a032C546D05Feec4D66`](https://bscscan.com/address/0xfd40c112f39d372786265a032c546d05feec4d66) |
| TagAISwapHook | [`0x9E38747072F326b4e614EfF6FdCA8529db090cc1`](https://bscscan.com/address/0x9e38747072f326b4e614eff6fdca8529db090cc1) |

Hook 使用 CREATE2 salt `5845`，地址低 16 位为 `0x0cc1`，对应当前启用的 PancakeSwap V4 Hook 回调位图。

## 3. Pump 更新

### 3.1 Bonding curve 与上市后费率隔离

`Pump.feeRatio` 继续控制上市前 bonding curve 的平台费和推荐/IPShare 费。TagAISwapHook 上市后的费率是代码常量，不读取 `Pump.feeRatio`，因此管理员调整内盘费率不会改变已上市池的 Hook 收费。

### 3.2 Community 收款人与管理员交接

Pump 创建 Community 和默认 Social Curation Pool 后，会在仍持有 Community 管理权限时完成两项设置：

1. 调用 `adminSetDev(creator)`，把 Community 的 `devFund` 设置为 Token 创建者；
2. 调用 `transferOwnership(creator)`，把创建者设置为 Community 的 `pendingOwner`。

`devFund` 会立即生效；Community 使用 `Ownable2Step`，创建者仍需调用 `acceptOwnership()` 才会成为正式 owner。这样收益接收者和待交接管理员都明确指向创建者，不再遗留为 Pump。

## 4. Token 上市与 LP Fee

### 4.1 上市池原生费率

V11 Token 创建的 PancakeSwap Infinity CL 池使用：

```text
PoolKey.fee = 3000 = 0.3%
tickSpacing = 60
```

`fee` 与 `tickSpacing` 是独立参数。0.3% 原生 LP Fee 会按 PancakeSwap 的池规则在流动性提供者之间累计；PancakeSwap 协议对这部分费用的分配以链上配置为准。

Token 合约仍持有上市时建立的固定流动性仓位，V11 没有增加减少或取出该流动性的接口。

### 4.2 固定上市 PoolKey

Token 在上市时保存：

```solidity
address public listingHook;
bytes32 public listingPoolParameters;
```

后续 `collectFees()` 使用这份上市快照重建 PoolKey。即使 Pump 管理员以后修改默认 Hook，已经上市的 Token 仍然使用原 Hook、原参数和原 PoolId，Token 侧累计的 LP Token Fee 也只会进入原上市 Hook。

### 4.3 公开领取 LP Fee

上市后任何地址都可以调用：

```solidity
function collectFees() external returns (uint256 bnbAmount, uint256 tokenAmount);
```

该方法通过 `modifyLiquidity(..., liquidityDelta = 0, ...)` 只领取上市仓位已经产生的费用，不减少流动性：

| 领取资产 | 分配方式 |
| --- | --- |
| BNB LP Fee | 领取金额的 0.5% 直接发送给调用者，其余直接从 Vault 发送给 `Pump.getFeeReceiver()` |
| 社区 Token LP Fee | 直接从 Vault 发送给该 Token 的 `listingHook`，作为 Nutbox 注入预算 |

Token 不作为这批资产的中转余额。调用时没有可领取费用会返回零值并发出金额为零的事件；调用者奖励向下取整产生的 dust 留给平台。

事件：

```solidity
event ListingFeesCollected(
    address indexed collector,
    uint256 bnbAmount,
    uint256 tokenAmount,
    uint256 callerReward
);
```

上市后的 Token 只接受 PancakeSwap Vault 在领取 LP Fee 流程中发送的 BNB，普通地址不能直接向 Token 转入 BNB。

## 5. TagAISwapHook 上市后费率

Hook 使用两个固定常量：

```text
IPSHARE_FEE_BPS   = 30 = 0.3%
DIRECTIONAL_FEE_BPS = 30 = 0.3%
```

实际资金流如下：

| 交易方向 | 费用资产与基数 | 去向 |
| --- | --- | --- |
| 买入 Token | BNB 侧金额的 0.3% | `IPShare.valueCapture(subject)` |
| 买入 Token | 买到的社区 Token 毛输出的 0.3% | 留在原上市 Hook，增加 Nutbox 注入预算 |
| 卖出 Token | BNB 侧金额的 0.3% | `IPShare.valueCapture(subject)` |
| 卖出 Token | 同一 BNB 毛金额的 0.3% | `Pump.getFeeReceiver()` |

卖出时两项 BNB Hook Fee 都按同一个 BNB 毛金额计算，不是先扣一项再对余额计算另一项。以上 Hook Fee 与池本身的 0.3% LP Fee 是独立路径。

Hook 兼容 exact-input 和 exact-output 两种交易：根据 BNB 是 specified currency 还是 unspecified currency，分别在 `beforeSwap` 或 `afterSwap` 完成 Vault 记账，并返回对应 Hook delta。

## 6. Nutbox 奖励注入

每个新 Token 上市时仍会把 150,000,000 枚社区 Token 转入 Hook。V11 不再维护只会递减的固定 `remaining` 计数，而是使用 Hook 当前实际 Token 余额作为注入预算。预算来源包括：

- 上市时的 150M 初始分配；
- 买入交易收取的 0.3% 社区 Token；
- `Token.collectFees()` 领取的社区 Token LP Fee；
- 任何其他直接转入 Hook 的 Token。

买入量继续按 10 分钟周期累计。进入新周期后的第一笔买入结算上一周期，并按固定档位计算注入量；实际注入不会超过 Hook 当前余额，低于最小注入量的结果会跳过。

Hook 注册 Token 时读取该 Community 自己的 `rewardCalculator()`，不依赖 Pump 以后可能修改的全局 Calculator。外部注资因此可以持续延长 Nutbox 社区奖励，而不受最初 150M 计数限制。

## 7. Anti-snipe 修正

V11 明确区分 Pump 创建流程中的初始 premine 和公开买入：

- Pump 在 Community 尚未绑定前执行的 premine 使用普通 `feeRatio`；
- 创建后 15 秒内的公开买入，包括公开第一笔买入，都使用 anti-snipe 费率；
- anti-snipe 窗口内禁止触发上市，避免动态费用购买直接把供应推到上市状态；
- Community 尚未建立、购买量为零或注入失败时，相关费用回退到 IPShare 路径；
- Calculator 注入失败时会撤销临时授权，避免残留 allowance。

## 8. 核心安全不变量

- Hook 只允许 Pump 创建的 Token 注册池，并要求调用者就是该 Token；
- `collectFees()` 只使用上市时保存的 Hook 和 Pool 参数；
- 领取费用时流动性变化量恒为零，上市仓位不会被减少；
- BNB 和社区 Token 从 Vault 直接分发，Token 合约不暂存本次领取资产；
- `collectFees()`、Hook 注册和关键交易路径使用重入保护或严格调用者校验；
- V11 只影响新 Pump 创建的 Token，不会修改旧 Token、旧 Pool 或旧 Hook 的状态。

完整部署地址、交易、区块及发布状态见 [`VERSION_HISTORY.md`](../VERSION_HISTORY.md) 和 [`deployments/56/version11.json`](../deployments/56/version11.json)。
