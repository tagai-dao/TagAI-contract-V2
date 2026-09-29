# Pump V14 / TradeCuration 极端场景测试记录

> 本文保留初次八池版本的历史测量。后续已收紧为最多 2 个可选池、总计最多 6 池，相关测试已更新为六池成功回归；最新结果见 [部署核验记录](PumpVersion14DeploymentReadiness.md)。下列旧八池用例不再是当前代码允许的配置。

日期：2026-09-22。本轮新增 18 项场景/性质测试，只增加测试与文档，未修改生产合约或 feeFree 业务规则，未广播主网交易。

## 执行结果

- 完整本地回归：40 套件，689 通过、0 失败、2 个原有测试跳过。包含继承的旧测试，不代表新增 689 项。
- V14 与攻击测试加强运行：62 项通过；每个 fuzz 测试执行 4096 轮，包括四成分、四可选池的随机权重组合。
- 独立账务不变量：512 轮 × 128 步，共 65,536 次 handler 调用，0 非预期回滚。启用 `fail_on_revert=true`，不会把意外失败的动作静默忽略。
- BSC fork：使用区块 **120508054** 的真实 CommunityFactory、Committee、IPShare、ERC20StakingFactory、PancakeSwap 和资产；部署新的本地 Pump、TradeCuration、Calculator、Router 及 Basket V4。授权操作通过 fork 内模拟 owner 执行。
- BSC fork 四项均达到预期，包含非零领取手续费下的直接 feeFree 豁免，以及一个**已知超 gas 预算场景的复现**；该用例通过表示成功证明超限及回滚，不代表该配置满足主网交易预算。

## 覆盖与断言

### 最大规模创建与失败回滚

`test/unit/PumpVersion14.t.sol`：

- 4 个成分 LP 池＋4 个可选池，首次创建 IPShare，非零社区/建池手续费，额外 1 BNB 预买。
- 极端指数权重 `[1, 1, 1, 9997]`，可选池合计 80%。不仅检查事件，还向真实 Community/Calculator 注入奖励并提取，验证四个可选池各得 20%，未领取 LP 份额仍留在 Community。
- 四成分、四可选池权重随机组合：用独立的逐池有理数上下界验证舍入，所有奖励比例严格合计 10000。
- 最后一个（第八个）矿池工厂拒绝参数：验证创建者及收款方业务资金、IPShare 创建状态、Token/Community 克隆代码、工厂映射、token 总数、tick 占用全部回滚；修正参数后原 salt/tick 可重试。

四个可选池使用四个独立的真实 TradeCurationFactory，目的是测试八池创建流程；不能据此推断所有未来矿池类型的 gas 相同。LP/DEX 在本地套件使用 doubles，gas 结论采用下方 BSC fork 结果。

### 恶意回调、失败退款与异常 ERC20

`test/security/TradeCurationAdversarial.t.sol`：

- 用户接收退款、手续费接收方收到 BNB、代币 transfer 回调时分别重入 `claim` 与 `harvestRewards`。断言回调确实发生，且两次调用均返回明确的 ReentrancyGuard 错误，外层只支付一次奖励。
- 用户拒收退款：在已经提取 Community 奖励、支付手续费、转出用户奖励之后触发失败，检查奖励债务、结算游标、pending、订单、totalClaimed、各方余额全数回滚。使用相同签名、支付准确手续费后成功重试。
- 手续费接收方拒收：整笔领取回滚，恢复接收方后可重试。
- ERC20 返回 false（包括先转账再返回 false）、直接 revert：对直接支付和从 Community 提取两种路径分别验证完整回滚及重试。
- ERC20 不返回数据：可以正确提取和支付。
- ERC20 在 Community → 矿池及矿池 → 用户两个 transfer 中回调：两次都验证重入被阻断。
- 扣税 ERC20：复现签名 10、用户净到账 9、totalClaimed 记 10 的现有行为。此为兼容性边界，未改成净到账担保。Pump Token 对矿池向普通用户转账不采用该异常税费模型。

### 长期账务与舍入

`test/invariant/TradeCurationAccounting.t.sol`：

- 64 个用户；随机注入、推进时间、提取、领取、重放已消费订单、轮换签名者。
- 独立 O(N) 逐笔线性释放模型，不复用生产代码的前缀和及二分查找。
- 每个状态检查：用户余额 = 逐用户累计领取；totalClaimed = 所有用户累计领取；Community＋矿池＋用户的资金总和 = 累计注入；已领取＋矿池余额＋待提取 = 独立模型已释放奖励；不能领取尚未释放的奖励。
- 确定性场景：365 天、730 次注入（每天两次，同小时合并）、超过 700 次领取、365 次重放、超过 50 次签名者轮换，64 个用户均实际领取过；最后等待完全释放并领取全部余额，Community 与矿池归零。
- 上述精确等式场景刻意使用 `168 × 10^6` 的整数倍金额，隔离固定精度舍入；另以不规则 wei 金额执行 365 次日注入/提取，验证资金守恒和舍入残留上界。实测残留 **1,119,399 token wei**，小于 366 次结算 × `10^6` wei 的上界。残留在 Community，未把它计为已领取。

## Gas 实测与发现

冷状态测量先预执行收集所有访问地址，再还原快照并冷却账户/存储，最后对目标合约执行有 gas 上限的调用。估计值含 `21000 + calldata(零字节×4、非零字节×16)`，未把整个测试函数的 gas 当成单笔交易 gas。

| BSC fork 场景 | gas |
|---|---:|
| 2 个 LP＋1 个交易池、预买 | 8,705,611 |
| 4 个 LP＋4 个可选池、首次 IPShare＋预买 | 16,630,615 |
| 上述最大规模＋64 字节指数/工厂名称、16 字节指数符号、非零社区及建池费 | **16,791,541** |
| 最大规模代币上市（沿用原 harness 测量，非同一冷状态口径） | 6,738,362 |

**发现：最大元数据/非零费组合比项目采用的 16,777,216 单笔预算高 14,325 gas。** 普通最大规模也仅余 146,601 gas，不能把“允许最多四个可选池”理解为所有四池配置都能在该预算内创建。

测试先用 25M 的诊断执行预算测出实际需求，再回滚状态，以扣除 calldata intrinsic gas 的 16,777,216 总预算尝试同一创建。断言该调用失败且业务状态/资金回滚。测试内余额断言不包含真实交易发送者承担的链上 gas 费用。

该用例显式断言超限复现，命名为 `test_v14Fork_characterizeMaxMetadataExceedsBudgetAndRollsBack`。如后续优化使其降至预算内，应改为新的成功回归，不能直接把当前“通过”当成已修复。可选池数量、工厂复杂度和元数据都影响预算；本轮未擅自改变这些业务限制。

## 复现命令

```bash
# 4096 轮参数 fuzz 与攻击测试
FOUNDRY_ETH_RPC_URL='' FOUNDRY_FUZZ_RUNS=4096 forge test \
  --match-contract 'TradeCurationAdversarialTest|PumpVersion14Test' -vv

# 512×128 次状态调用；预期拒绝的重放由 expectRevert 断言处理
FOUNDRY_ETH_RPC_URL='' FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=128 \
  FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test \
  --match-contract TradeCurationAccountingInvariantTest -vv

# 读取 .env 中的 BSC_RPC_URL；不使用 --broadcast
# 需事先存在 ../bsc-basket-contract/out 的 Basket V4 编译产物
FOUNDRY_PROFILE=fork FOUNDRY_ETH_RPC_URL='' PUMP13_FORK_BLOCK=120508054 forge test \
  --match-contract Pump14MainnetForkTest --match-test 'test_v14Fork_' -vvv

# 完整本地回归
FOUNDRY_ETH_RPC_URL='' forge test \
  --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
```

边界：fork 是固定历史区块的本地模拟，未广播主网；不替代部署时的地址、权限及即时流动性核对。旧 fork harness 在该区块跳过未注册的 GOOGLB/CRCLB，本轮使用当时已存在的成分资产。
