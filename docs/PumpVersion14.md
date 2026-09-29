# Pump V14：可选奖励矿池

后续已补充极端场景和实际 BSC fork 测试，见 [压力测试记录](PumpVersion14StressTests.md)。早期发现八池组合超过项目单笔 gas 预算，现按用户要求收紧为最多 2 个可选池、总计最多 6 池；最新部署演练见 [部署核验记录](PumpVersion14DeploymentReadiness.md)。下文最初的“fork 未完成”描述属于早期验证记录。

V14 保留 V13 的 Token、指数配置、成分池、上市、回购及社区所有权逻辑。创建社区矿池时增加 owner 配置的可选矿池，部署时支持复用已有 Token 模板。`Pump.VERSION()` 返回 `14`。

## 创建接口与分配

原来的 `createToken(tick, salt, indexConfig)` 保留，仍只创建 LP 质押池，奖励比例等于 `indexConfig.targetWeights`。

新增重载：

```solidity
struct OptionalPoolConfig {
    address factory;
    uint16 rewardRatio; // bps：10000 = 100%
    bytes meta;
}

createToken(tick, salt, indexConfig, optionalPools);
```

- 不选交易矿池：传空数组，或继续使用三参数入口。
- 选择交易矿池：传 `[{factory: tradeCurationFactory, rewardRatio: 3000, meta: "0x"}]`，代表 30%。
- 每个可选矿池比例必须大于 0，且不超过 owner 为该工厂设置的上限。
- 所有可选矿池合计最多 8000 bps（80%）；同一工厂不能重复选择；单次最多 2 个可选矿池（与最多 4 个成分 LP 池合计最多 6 池）。
- 剩余至少 20% 按指数权重分给原有 LP 池。指数权重本身不改变，仍必须合计 10000。
- LP 池按成分顺序排列，然后追加用户选择的可选池；创建的中间步骤比例为零，最后一次 `adminAddPool` 设置全部比例。
- 使用累计舍入：`LP[i] = floor(累计权重[i] × 剩余比例 / 10000) - floor(累计权重[i-1] × 剩余比例 / 10000)`。每池误差小于 1 bps，总和严格为 10000。极小权重池可能舍入为 0 bps。

例：指数权重 3333/6667，交易池选择 8000，则 LP 奖励比例为 666/1334，交易池为 8000。此变化不影响成分资产的上市资金分配、指数权重或交易税。

固定创建费用：

```text
Pump.createFee
+ 尚未创建 IPShare 时的 IPShare.createFee
+ Committee.getCreateCommunityFee()
+ Committee.getCommunitySettingsFee() × (成分数量 + 可选池数量)
```

超过固定费用的 BNB 继续用于预买。`NutboxStakingPoolLinked.rewardRatio` 现在表示最终 LP 奖励比例；新增 `NutboxOptionalPoolLinked(token, pool, factory, rewardRatio)` 供索引服务发现可选池。

## Owner 配置与扩展范围

Pump owner 调用：

```solidity
pump.adminSetOptionalPoolFactory(tradeFactory, "Trade Curation", 8000, true);
```

Committee owner 还需调用 `adminAddContract(tradeFactory)`。创建时同时检查这两层许可。可通过 `optionalPoolFactories(factory)` 查询名称、上限和启用状态，通过 `OptionalPoolFactorySet` 事件枚举配置。

以后增加矿池时，部署兼容的 `IPoolFactory/IPool` 工厂，完成上述配置即可，无需重新部署 Pump。用户提供的 `meta` 透传到工厂，工厂负责验证该类型的参数；owner 应只注册经过检查的工厂。TradeCuration 要求 `meta` 为空。

适用范围是现有 `Community.adminAddPool(name, ratios, factory, meta)` 能完成初始化的矿池。若新类型需要额外资产划转、特殊权限授予、上市回调或改变 Token 交易逻辑，仍需单独开发适配或升级；本次没有增加任意调用或 delegatecall 插件机制。

配置变更只影响未来创建。禁用工厂不会关闭已有池；降低上限不会改写已有社区比例。

80% 是 **Pump 创建时** 的限制。与 V13 一致，保留社区 owner 的创建者仍能通过 Community 修改比例、关闭或添加池。若希望比例永久固定，应选择 `retainCommunityOwnership = false`；若希望保留部分管理权限同时强制永久上限，需要修改 Community 的权限模型，超出本次范围。

## TradeCuration 检查与修复

1. 修复复制残留的 `SocialCurationFactory`、`SocialCuration` 和 `SocialCurationCreated` 引用，事件统一为 `TradeClaimed` / `TradeCurationCreated`。
2. 工厂构造时拒绝零签名地址，轮换签名地址发出 `ClaimSignerChanged`，增加 `claimedOrders(user, orderId)` 查询。
3. 修复零手续费时的 BNB 退款：Community 的手续费函数在 fee=0 时直接返回，不会退回传入 BNB。TradeCuration 现在只转发准确手续费，多付金额留在矿池退给当前调用者。
4. 保持与 SocialCuration 一致的 feeFree 判断：矿池余额足够时，白名单用户直接领取免手续费，多付 BNB 全额退回；普通用户仍支付一次手续费。余额不足时仍走 Community 原有的提取奖励收费逻辑，本次不修改 Community 的收费规则。
5. 保留 EIP-712 域、领取者、矿池、链、有效期及订单防重放校验；领取失败整笔回滚，不消耗订单。签名地址轮换会立即使旧签名失效。

同一 `TradeCurationFactory` 对每个社区只创建一次，即使关闭原池也不能通过该工厂重建。不同工厂各有自己的映射，不能保证跨工厂的全局唯一性；与 SocialCuration 相同。实际运营应统一使用官方工厂。

SocialCuration 的原有实现也存在相同的零手续费退款问题；本次只修复新 TradeCuration 的退款，不改变已存在的 SocialCuration 行为。Community 的提取奖励路径没有 feeFree 判断，属于现有行为，未在本次调整。

## 官方签名格式

签名者为 TradeCurationFactory 的 `claimSigner`，需要使用 ECDSA 钱包签名，当前不支持 EIP-1271 合约钱包。社区 owner 不能改签名者，只有工厂 owner 可以轮换。

```javascript
const domain = {
  name: 'Nutbox TradeCuration',
  version: '1',
  chainId: 56,
  verifyingContract: poolAddress, // 克隆池地址，不是工厂或实现合约
};
const types = { Claim: [
  { name: 'chainId', type: 'uint256' },
  { name: 'pool', type: 'address' },
  { name: 'orderId', type: 'uint256' },
  { name: 'amount', type: 'uint256' },
  { name: 'to', type: 'address' },
  { name: 'deadline', type: 'uint256' },
] };
const signature = await signer.signTypedData(domain, types, {
  chainId: 56, pool: poolAddress, orderId, amount, to: userAddress, deadline,
});
// userAddress 发交易；amount 使用代币最小单位，deadline 使用秒。
await pool.connect(user).claim(orderId, amount, deadline, signature, { value: operationFee });
```

订单唯一性范围为 `(pool, user, orderId)`。后端应确保不重复签发不同金额的同一订单，并根据可领取资金分配奖励；签名只授权提款，不凭空产生奖励。

## 部署与验证

新增 `script/DeployBSCPump14.s.sol`，沿用 V13 的基础设施配置变量；owner、Token 模板默认从已部署 V13 Pump 读取，交易矿池 signer 默认从现有 SocialCurationFactory 读取，可通过对应环境变量覆盖。现有 BSC 基础设施和 V13 keeper 地址已作为 Pump 状态变量初值写入，部署时不再发起相应 setter 交易；原 owner 管理接口保留。脚本将基础设施环境变量及 `PUMP14_LISTING_KEEPER`（缺省读取 V13）与内置值比较，不一致就终止模拟，不会用额外设置交易覆盖它们。脚本部署新的 Pump、Hook、BuybackRouter 和 TradeCurationFactory，注册交易矿池；当部署者拥有 Committee 时自动加入白名单，否则输出待执行操作。两步 owner 转移仍需目标 owner 分别接受 Pump 与 TradeCurationFactory 的所有权。

Pump 构造函数新增第四个参数 `existingTokenImplementation`。V14 脚本默认从已部署 V13 Pump 读取并复用 Token 模板（与 `deployments/56/version13.json` 记录一致） `0xcC8f585593feAb2a27f9e699a6b578d46446c88C`，可通过 `PUMP14_TOKEN_IMPLEMENTATION` 指定其他已验证兼容的模板；脚本要求该地址存在代码。构造函数传零地址时仍部署新模板，以支持独立部署及旧测试。非零地址仅检查存在代码，兼容性由部署者核验，不能传任意合约。

复用的是 Token 实现模板，新 Pump 仍为每个新代币创建独立克隆，初始化自己的管理合约、Hook、社区及指数；已有 V13 代币不受影响。旧 Hook 和 BuybackRouter 均将旧 Pump 地址固定为 immutable，不能切换，因此 V14 需部署新的 Hook 和 BuybackRouter。

BuybackRouter 的作用是把 Hook 中累积的回购 BNB，经 NutboxRouter 换成结算币（USDT），再经 BasketSwapRouter 买入该代币对应的指数代币，交回 Hook 并由 Token 记账给合格持币者领取。任何人都可触发 Hook 的回购入口，但 Router 只接受对应 Token 的 Hook 调用，输出强制交回 Hook，并检查截止时间及两段兑换的最低到账量。该流程沿用 V13 实现。

Pump 不是可升级代理，已部署的 V13 不能通过设置参数获得本次新代码。首次 V14 需要部署新 Pump；之后兼容的新矿池类型可直接注册。既有 V13 代币不迁移，Token 实现源码未修改。沿用 V13 的 `PUMP13_INDEX` Basket salt 前缀以保持原有创建规则。

前期已按区块 123329493 完成真实基础设施、owner、keeper、signer 核对及部署模拟。随后按用户指令完成 9 笔主网部署交易和 5 个新合约源码验证，实际地址见 `deployments/56/version14.json`；当前等待多签授权和 owner 接收，详见部署核验记录。本地单元测试使用真实 Nutbox 合约和 DEX/Basket doubles，最新部署 fork 测试直接使用已部署的 V13 基础设施。

```bash
FOUNDRY_ETH_RPC_URL='' forge test --match-contract 'PumpVersion14Test|TradeCurationTest'
FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
forge build --sizes src/pump/Pump.sol src/nutbox/dapps/trade-curation/TradeCurationFactory.sol
```

2026-09-22 本地验证：38 个测试套件，662 通过、0 失败、2 个原有测试跳过；其中 PumpVersion14Test 38 项（包含继承的 V13 回归）及 TradeCurationTest 11 项全部通过，fuzz 使用默认 256 轮。全项目编译及 V14 部署脚本编译通过。Pump runtime 21,040 bytes / initcode 46,471 bytes（不含构造参数），Token runtime 24,400 bytes，相关合约大小检查通过。

主网 fork 未完成：额外目录内的旧 CommentMarketsForkTest 尝试连接 RPC 时因网络/DNS 失败，最终本地回归明确排除了所有 fork 测试。此结果不代表已验证实际 BSC 部署地址、权限或主网状态。

随后按用户要求撤回取消 feeFree 豁免的变更，恢复与 SocialCuration 一致的直接领取白名单判断；重新运行 TradeCurationTest，12 项全部通过，包含免手续费领取及多付 BNB 全额退款。上述 662 项完整回归记录对应撤回前的版本。

### V13 Token 模板复用验证（2026-09-22）

- 新增构造测试：复用现有模板时 Pump 不再创建 Token 实现；无代码的非零模板地址拒绝部署。零地址仍创建新模板。
- 完整本地回归：691 通过、0 失败、2 个原有测试跳过。V14 部署脚本编译通过；Pump runtime 21,040 bytes / initcode 46,549 bytes（不含构造参数）。
- `test/fork/Pump14TemplateReuse.t.sol` 使用 BSC 区块 `120700000` 上的实际 V13 模板，且验证该地址确实来自已部署 V13 Pump。两项测试均通过：原创建入口的上市、两次回购及持币者领取；80% 交易矿池的新创建入口、共享模板的克隆状态独立、上市及回购领取。新 Pump、Hook、BuybackRouter 在 fork 内部署。
- 上述 fork 验证只读主网数据，没有广播真实链上交易。这轮验证时尚未收紧八池上限；后续六池版本的验证见部署核验记录。

```bash
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' forge test \
  --match-contract Pump14TemplateReuseForkTest --match-test 'test_reuse_' -vvv
```
