# Hooks 版本迭代记录

本文记录本仓库中独立 PancakeSwap Hook 的版本、用途、发布提交、链上部署和配套工具。

每个已经发布的版本都必须绑定到不可变的 Git commit；后续新增 Hook 时，在“版本索引”中增加一行，并在下方追加完整版本说明。历史版本不得通过改写原有记录来覆盖。

## 版本索引

| 版本 | Hook | 使用场景 | 网络 | 发布提交 | 标签 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| V1 | `XSpaceStoreHook` | SPCXB / XSpace Store 固定代币池 | BSC（56） | [`d653ba5`](https://github.com/tagai-dao/TagAI-contract-V2/commit/d653ba52139b2a66ba1b3608c5bb75a36e0b6e23) | [`hooks-for-spcxb`](https://github.com/tagai-dao/TagAI-contract-V2/tree/hooks-for-spcxb) | 已部署（按仓库记录） |

## V1 — SPCXB / XSpace Store

### 发布信息

| 项目 | 内容 |
| --- | --- |
| 发布日期 | 2026-06-15 |
| 完整提交 | [`d653ba52139b2a66ba1b3608c5bb75a36e0b6e23`](https://github.com/tagai-dao/TagAI-contract-V2/commit/d653ba52139b2a66ba1b3608c5bb75a36e0b6e23) |
| Git 标签 | [`hooks-for-spcxb`](https://github.com/tagai-dao/TagAI-contract-V2/tree/hooks-for-spcxb) |
| 开发分支 | [`hooks`](https://github.com/tagai-dao/TagAI-contract-V2/tree/hooks) |
| Hook 源码 | [`src/hook/XSpaceStoreHook.sol`](src/hook/XSpaceStoreHook.sol) |
| 部署记录 | [`deployments/56/xspace-store.json`](deployments/56/xspace-store.json) |

V1 是本仓库第一套面向指定外部代币的独立 Hook。它服务于 SPCXB / XSpace Store 代币，不依赖 `Pump`，也不执行 Nutbox 奖励注资；因此它与社区代币使用的 `TagAISwapHook` 是两条独立的产品线。

### BSC 主网部署

| 项目 | 值 |
| --- | --- |
| Chain ID | `56` |
| SPCXB Token | [`0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1`](https://bscscan.com/token/0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1) |
| XSpaceStoreHook | [`0xe64Caf44eff0841D213a716a449B4563cFEc0CC1`](https://bscscan.com/address/0xe64Caf44eff0841D213a716a449B4563cFEc0CC1) |
| Pool ID | `0x8364c6a1ee0e1776cb32f817e69b74c1201704b74ff5d75a746d9893ca64d444` |
| Deployer | [`0x0De93A988D657e1E8897e1a70Ba1b95334297B63`](https://bscscan.com/address/0x0De93A988D657e1E8897e1a70Ba1b95334297B63) |
| Platform receiver | [`0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048`](https://bscscan.com/address/0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048) |
| IPShare | [`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`](https://bscscan.com/address/0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922) |
| PCS V4 CLPoolManager | [`0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b`](https://bscscan.com/address/0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b) |
| PCS V4 Vault | [`0x238a358808379702088667322f80aC48bAd5e6c4`](https://bscscan.com/address/0x238a358808379702088667322f80aC48bAd5e6c4) |
| Tick spacing | `10` |

以上地址来自本版本提交中的部署记录。链上合约是否仍作为当前交易入口，应结合前端配置和链上池状态单独确认。

### 实际费率

V1 的费率应以发布 commit 中的合约常量为准：

| 费用 | 合约配置 | 实际比例 | 去向 |
| --- | ---: | ---: | --- |
| PCS V4 原生 LP fee | `4000` pips | 0.4% | LP 仓位 |
| Hook platform fee | `20` BPS | 0.2% | `feeReceiver` |
| Hook IPShare fee | `20` BPS | 0.2% | 有效 IPShare subject；无效时进入 `feeReceiver` |
| 合计 | — | **0.8%** | — |

`deployments/56/xspace-store.json` 中的 `lpFeeBps` 值 `4000` 按照 PancakeSwap V4 fee pips 解释，对应 0.4% LP fee。V1 每笔交易的当前总费率为 0.8%。

### 核心行为

- 只接受 BNB 原生币与固定 SPCXB Token 组成的池。
- 只接受 `tickSpacing = 10` 的 PoolKey。
- Hook 地址低 16 位满足 PancakeSwap V4 bitmap `0x0CC1`。
- 买入和卖出都在 BNB 一侧收取 Hook fee。
- `hookData` 格式为 `abi.encode(address ipshareSubject)`。
- subject 已创建 IPShare 时，IPShare 部分通过 `IPShare.valueCapture(subject)` 分配。
- subject 无效、为空或未提供时，IPShare 部分回退到平台 `feeReceiver`。
- 合约不依赖 `Pump`，不读取社区配置，也不执行 Nutbox 注资。
- Token、PoolManager、Vault、feeReceiver 和 IPShare 均在部署时固定，V1 合约本身不可修改这些配置。

### 部署与运维工具

| 工具 | 用途 |
| --- | --- |
| [`script/DeployXSpaceStoreHook.s.sol`](script/DeployXSpaceStoreHook.s.sol) | CREATE2 salt 挖掘、部署 Hook，可选初始化池 |
| [`script/InitializeXSpacePool.s.sol`](script/InitializeXSpacePool.s.sol) | 初始化 SPCXB 集中流动性池 |
| [`script/AddXSpaceLiquidity.s.sol`](script/AddXSpaceLiquidity.s.sol) | 增加集中流动性 |
| [`script/RemoveXSpaceLiquidity.s.sol`](script/RemoveXSpaceLiquidity.s.sol) | 移除集中流动性 |
| [`script/SwapXSpace.s.sol`](script/SwapXSpace.s.sol) | SPCXB 池交易脚本 |
| [`script/helpers/XSpaceLiquidityMath.sol`](script/helpers/XSpaceLiquidityMath.sol) | 流动性和价格区间计算 |
| [`script/helpers/XSpaceUniversalRouter.sol`](script/helpers/XSpaceUniversalRouter.sol) | Universal Router 交易辅助 |

### 测试入口

| 测试 | 覆盖范围 |
| --- | --- |
| [`test/unit/XSpaceStoreHook.t.sol`](test/unit/XSpaceStoreHook.t.sol) | Hook 注册、交易费和 IPShare 路由单元测试 |
| [`test/fork/BSCForkXSpaceStore.t.sol`](test/fork/BSCForkXSpaceStore.t.sol) | BSC 主网 PancakeSwap V4 fork 交易 |
| [`test/fork/BSCForkXSpaceStoreUsdRange.t.sol`](test/fork/BSCForkXSpaceStoreUsdRange.t.sol) | 价格区间与流动性验证 |
| [`test/fork/RemoveXSpaceLiquidityFork.t.sol`](test/fork/RemoveXSpaceLiquidityFork.t.sol) | 移除流动性 fork 测试 |
| [`test/fork/UniversalRouterSellFork.t.sol`](test/fork/UniversalRouterSellFork.t.sol) | Universal Router 卖出路径 |

## 后续版本登记规则

新增 Hook 时，应在本文追加一个新版本章节，并至少记录：

1. 版本号、用途、目标链和固定代币（如适用）。
2. 完整发布 commit 链接和不可变 Git 标签。
3. Hook、Token、PoolManager、Vault、Pool ID 等链上地址。
4. LP fee、Hook fee、平台/IPShare/社区等全部资金流向。
5. 是否依赖 Pump、Nutbox、预言机或外部 Router。
6. 部署、初始化、流动性和应急运维脚本链接。
7. 单元测试与真实网络 fork 测试链接。
8. 相比上一版的行为变化、兼容性和已知限制。

已部署版本只能通过新版本替代。不得复用旧版本号描述不同字节码，也不得让同一标签指向新的提交。
