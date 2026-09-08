# BSC V13 两个路由合约的部署与验证

更新日期：2026-09-08。本文只提供操作命令，本轮未执行广播。顺序必须为 **TagAITradeRouter → TagAILiquidityRouter**。

## 已部署记录

两个地址及部署交易、区块已保存到 [deployments/56/version13.json](../deployments/56/version13.json)，与本地 Foundry 广播回执（status=1）和构造参数核对一致。

| 合约 | 地址 | 部署区块 |
| --- | --- | ---: |
| TagAITradeRouter | `0x7D5480C10A98b0Feb4e5fA77aF3F01aE3a5E86F4` | 120659886 |
| TagAILiquidityRouter | `0x2868FDdf7F86041557257c55a79A382536401752` | 120660204 |

浏览器源码验证状态不能仅由部署回执推断；这里不新增 Verified=true 标记。以下部署命令作为复现说明，已部署的实例无需重跑。

## 部署对象和编译配置

| 合约 | 用途 | 构造参数 |
| --- | --- | --- |
| src/router/TagAITradeRouter.sol:TagAITradeRouter | V13 上市后多池聚合买卖；主池传递 IPShare subject | Pump13、NutboxRouter、Pancake V2 Factory |
| src/router/TagAILiquidityRouter.sol:TagAILiquidityRouter | 双资产加减流动性；BNB 固定主池买 T、Router 买成分资产、加池、卖余量退 BNB | 上一步部署的 TagAITradeRouter |

两者均是普通不可升级合约，无初始化交易或 owner 配置，无需给它们新增 Nutbox operator 权限。基础设施绑定不可修改，地址填错需要重新部署。

当前产物：Solidity **0.8.26+commit.8a97fa7a**、优化 **200** 次、**viaIR=true**、**evmVersion=cancun**。命令使用 `bsc_mainnet` profile（chain ID 56），避免默认 profile 的 31337。部署与验证期间保持源码、依赖和这些配置一致。

## 1. 环境与预检查

在项目目录执行；沿用既有 `.env` 中的 `PRIVATE_KEY_MAIN`、`BSC_RPC_URL`、`ETHERSCAN_API_KEY`。Foundry 自动读取项目 `.env`，RPC 别名 `bsc` 来自 foundry.toml，所以无需把私钥放进命令行，也不需要 source 整份配置。

`ETHERSCAN_API_KEY` 用于 Etherscan 验证服务，明确指定 `--verifier etherscan`。不要依赖工具默认 verifier。参考 [Etherscan 的 Foundry 验证文档](https://docs.etherscan.io/contract-verification/verify-with-foundry)。

```bash
cd "/Volumes/Extreme Pro/wangxi/work/tiptag/TagAI-contract-V2"

export TRADE_ROUTER_PUMP=0x2c2f4e8D85c02a065f109c74d9b27186AE65Adfa
export TRADE_ROUTER_NUTBOX=0x72dc4F38A7E4159e97d826a6ab594748C6b68f17
export TRADE_ROUTER_V2_FACTORY=0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73

cast chain-id --rpc-url bsc
cast call "$TRADE_ROUTER_PUMP" 'nutboxRouter()(address)' --rpc-url bsc
cast call "$TRADE_ROUTER_PUMP" 'pancakeV2Factory()(address)' --rpc-url bsc

FOUNDRY_PROFILE=bsc_mainnet FOUNDRY_ETH_RPC_URL='' forge build \
  script/DeployBSCTagAITradeRouter.s.sol \
  script/DeployBSCTagAILiquidityRouter.s.sol
```

前三个查询应分别返回 `56`、上述 NutboxRouter、上述 V2 Factory。两个脚本沿用 PRIVATE_KEY_MAIN，部署账户需要 BNB 支付 Gas。若刻意修改基础设施，部署和补验证的参数也必须一起修改。

## 2. 部署交易执行器

先模拟（不广播）：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCTagAITradeRouter.s.sol:DeployBSCTagAITradeRouterScript \
  --rpc-url bsc --evm-version cancun
```

部署并发起浏览器源码验证：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCTagAITradeRouter.s.sol:DeployBSCTagAITradeRouterScript \
  --rpc-url bsc --evm-version cancun \
  --broadcast --slow --verify --verifier etherscan
```

确认广播 receipt 成功后，从输出 `TagAITradeRouter` 取地址。模拟输出的预测地址不能当成已部署地址。把下面占位符替换为真实地址：

```bash
export BSC_V13_TRADE_ROUTER=0x填入刚部署的交易路由地址

cast call "$BSC_V13_TRADE_ROUTER" 'pump()(address)' --rpc-url bsc
cast call "$BSC_V13_TRADE_ROUTER" 'nutboxRouter()(address)' --rpc-url bsc
cast call "$BSC_V13_TRADE_ROUTER" 'pancakeV2Factory()(address)' --rpc-url bsc
```

返回值应与第 1 步三个部署参数一致。

## 3. 部署流动性执行器

沿用同一终端的 BSC_V13_TRADE_ROUTER。先模拟：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCTagAILiquidityRouter.s.sol:DeployBSCTagAILiquidityRouterScript \
  --rpc-url bsc --evm-version cancun
```

部署并验证：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCTagAILiquidityRouter.s.sol:DeployBSCTagAILiquidityRouterScript \
  --rpc-url bsc --evm-version cancun \
  --broadcast --slow --verify --verifier etherscan
```

确认广播 receipt 成功后，填入输出的 TagAILiquidityRouter 地址：

```bash
export BSC_V13_LIQUIDITY_ROUTER=0x填入刚部署的流动性路由地址

cast call "$BSC_V13_LIQUIDITY_ROUTER" 'tradeRouter()(address)' --rpc-url bsc
cast call "$BSC_V13_LIQUIDITY_ROUTER" 'pump()(address)' --rpc-url bsc
cast call "$BSC_V13_LIQUIDITY_ROUTER" 'nutboxRouter()(address)' --rpc-url bsc
cast call "$BSC_V13_LIQUIDITY_ROUTER" 'factory()(address)' --rpc-url bsc
```

分别应返回交易路由、Pump13、NutboxRouter、V2 Factory。注意：流动性合约的 getter 叫 `factory()`，交易合约的 getter 叫 `pancakeV2Factory()`。

## 4. 单独补验证

部署成功但验证失败时，只运行下面的验证命令，**不要重新广播部署**。验证只是向浏览器提交源码和编译参数，不会再创建合约。

三个基础地址及两个已部署地址需与之前一致。构造参数应 ABI 编码，不能附带函数 selector。

```bash
TRADE_CTOR_ARGS="$(cast abi-encode 'constructor(address,address,address)' \
  "$TRADE_ROUTER_PUMP" "$TRADE_ROUTER_NUTBOX" "$TRADE_ROUTER_V2_FACTORY")"

FOUNDRY_PROFILE=bsc_mainnet forge verify-contract \
  "$BSC_V13_TRADE_ROUTER" src/router/TagAITradeRouter.sol:TagAITradeRouter \
  --chain 56 --verifier etherscan --watch \
  --compiler-version v0.8.26+commit.8a97fa7a \
  --num-of-optimizations 200 --via-ir --evm-version cancun \
  --constructor-args "$TRADE_CTOR_ARGS"

LIQUIDITY_CTOR_ARGS="$(cast abi-encode 'constructor(address)' "$BSC_V13_TRADE_ROUTER")"

FOUNDRY_PROFILE=bsc_mainnet forge verify-contract \
  "$BSC_V13_LIQUIDITY_ROUTER" src/router/TagAILiquidityRouter.sol:TagAILiquidityRouter \
  --chain 56 --verifier etherscan --watch \
  --compiler-version v0.8.26+commit.8a97fa7a \
  --num-of-optimizations 200 --via-ir --evm-version cancun \
  --constructor-args "$LIQUIDITY_CTOR_ARGS"
```

`--watch` 等待验证结果。若报 compiler list 网络错误，需要恢复对 binaries.soliditylang.org 的访问；若报 API key/验证服务错误，修正验证配置后重试本节；都不需要重复部署。验证应最终显示成功，并在 BscScan 合约页面可查看对应源码。

## 5. 保存记录、配置前端

保存两个合约的真实地址、创建 tx hash、区块、构造参数、源码 Git commit/未提交 diff、编译配置及浏览器验证结果。广播记录分别在：

- broadcast/DeployBSCTagAITradeRouter.s.sol/56/run-latest.json
- broadcast/DeployBSCTagAILiquidityRouter.s.sol/56/run-latest.json

这些记录应在再次运行脚本前归档。当前流动性路由等工作区文件尚未提交，部署使用的是当前工作区代码。

前端 `tiptag-ui/src/config/chains.ts` 的 BSC `contracts` 配置（地址由用户提供）：

```typescript
tradeRouter13: '0x7D5480C10A98b0Feb4e5fA77aF3F01aE3a5E86F4',
liquidityRouter13: '0x2868FDdf7F86041557257c55a79A382536401752',
```

发布更新后的前端。API 继续提供代币、池子和路径元数据，前端忽略 API 返回的旧 executor / liquidityRouter 地址。
无需设置 API 的 BSC_V13_TRADE_ROUTER / BSC_V13_LIQUIDITY_ROUTER 环境变量；上述部署/验证命令里的同名 shell 变量仅供 Foundry 使用。
本次两个辅助合约部署不涉及新增数据库迁移。

上线联调区分：代币买卖仍支持多池聚合；BNB 加池固定主池购买 T。依次确认买卖 subject、自动 LP 报价、最低到账回滚、BNB 余量退款，以及用户独立的 LP 授权/质押/解押/移除。浏览器源码验证成功不等于上述业务联调已完成。

## 本轮本地验证记录

- 两个脚本已本地编译；编译元数据与本文参数一致。
- 2026-09-08 重新运行相关单元测试 52 项全部通过（交易 26、流动性 13、既有回购 13），三个 fuzz 用例各 4096 次。
- 同日 BSC fork：交易路由 7 项、流动性路由 10 项全部通过，0 失败、0 跳过；固定区块 120508054。见 [流动性 fork 报告](../test/fork/TagAILiquidityRouter.md)。这是本地 fork 验证，部署后的实际地址配置和主网钱包联调仍需执行。
- 部署和线上源码验证由用户执行；本轮没有调用 --broadcast，也没有向验证服务提交已部署地址。
- 本地尝试导出验证 Standard JSON 时，环境无法解析 binaries.soliditylang.org，未完成联网验证预演；命令参数已与本机 Foundry 帮助及 Etherscan 文档核对。
