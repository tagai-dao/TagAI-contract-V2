# Binance Handle NFT 模板部署记录

日期：2026-11-04（北京时间）。网络：BSC 主网，chain ID 56。

两个模板已部署，链上运行时代码与本地编译产物精确一致，**均已通过 BscScan 源码验证**。Factory 注册仍待 Safe 多签执行。

## 地址与交易

| 合约 | 新地址 | 部署区块 |
| --- | --- | --- |
| IndexBrokerNFTBurn | `0x1cceCdED84c825e413F1849FdF55423D07Dc9ab6` | 131586660 |
| IndexBrokerNFTStake | `0x156C2A877069b0e50dC5A74C7d1612d70144B4C6` | 131586670 |

- Burn 部署交易：[0x7325177c9e88f6ae0b25b08a3ee9a8b8b85d1e092fbaa74864812cbcd2bb8b5c](https://bscscan.com/tx/0x7325177c9e88f6ae0b25b08a3ee9a8b8b85d1e092fbaa74864812cbcd2bb8b5c)。Gas：5,325,734。
- Stake 部署交易：[0xc330e99a89ef3526f7579f0500d7f31c9cf238bc8b698affef6249a004b7b785](https://bscscan.com/tx/0xc330e99a89ef3526f7579f0500d7f31c9cf238bc8b698affef6249a004b7b785)。Gas：5,229,101。
- 部署账户：`0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`。
- 两笔 gas price 均为 0.05 Gwei，合计费用 **0.00052774175 BNB**。
- Factory 保持 `0x835E047D4BE6548E95F2Cbb9Ac02d62EFa2508A0`，AMM、Renderer、Community、Router 均复用。

## 行为与编译证据

共享 `mint` 入口要求 Binance Handle 注册表
`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` 的 `handleOf(msg.sender)` 非空。
白名单和公开 Mint 均检查；注册表不可用时拒绝 Mint；初始化接口保持 `0x0b8f9877`。
已有矿池绑定旧实现，不会自动改变；此任务未移除旧模板。

- Solidity：`0.8.26+commit.8a97fa7a`；viaIR；optimizer enabled / 100 runs；EVM Cancun；metadata IPFS。
- Runtime：Burn 24,055 bytes；Stake 23,608 bytes，均低于 EIP-170 限制。
- 本地 NFT 与回调回归测试：90 通过。
- 部署读取与 Multicall 回归测试：13 通过，覆盖目标地址、子调用集合、固定区块和必需数据失败。
- 源码基准提交、部署时真实源码 SHA-256、artifact SHA-256、编译设置与回执保存在[正式记录](../deployments/56/index-broker-handle-templates.json)。Handle 校验在部署时尚未提交，随后随本次发布纳入版本管理；内容摘要和 Standard JSON 固定真实部署源码，不把原基准提交误记为完整部署源码。
- [源码验证材料](../deployments/56/index-broker-handle-templates-verification/manifest.json)已公开提交；同版本 solc 本地重编译的创建字节码和运行时代码与部署产物逐字节一致。用户于 2026-11-04 在本次会话中明确授权公开源码与编译信息。

## BscScan 源码验证：已完成

使用 Foundry `Solidity Standard JSON input`，通过 Etherscan V2 API 的 BSC（chain ID 56）验证；两个提交均返回 `Pass - Verified`。随后独立 `getsourcecode` 回读确认合约名称、完整编译器版本、优化设置、EVM Cancun、无构造参数、无 SimilarMatch，并核对公开源码文件摘要与 viaIR / metadata 设置。

| 模板 | 验证完成时间（北京时间） | 本地 Standard JSON SHA-256 |
| --- | --- | --- |
| [Burn 源码](https://bscscan.com/address/0x1cceCdED84c825e413F1849FdF55423D07Dc9ab6#code) | 2026-11-04 16:04:03 | `415898474cf958dcabebdeb34db7e24c760823782344f07d6a14dc63b420e220` |
| [Stake 源码](https://bscscan.com/address/0x156C2A877069b0e50dC5A74C7d1612d70144B4C6#code) | 2026-11-04 16:04:29 | `9c3be5e254f852baa5d6447c44f9beb8677b3955c0e221173fce411bea6d9c1e` |

验证结果来源、公开编译设置、源码一致性检查、编译输入及去敏后的 CLI 日志均保存在上述验证材料目录。此次验证无需链上交易，不改变 Factory 注册状态。

## Factory 注册：待执行

固定区块 131589995 的 Multicall 确认：两个新模板的 `supportedNFTTemplate` 均为 false。
Factory owner 为 Safe `0x871fb7006C5964B21695Ba20006021777A26146C`，阈值 **2/3**，快照 nonce 为 49。
部署账户不是 Safe signer，不能直接执行 `onlyOwner` 的注册操作。

导入 [Safe Transaction Builder 文件](../deployments/56/index-broker-handle-templates.safe.json)，核对 chain ID 56、Safe 和 Factory 后签署执行。文件仅包含两笔零转账调用：

```text
Factory.addNFTTemplate(0x1cceCdED84c825e413F1849FdF55423D07Dc9ab6)
Factory.addNFTTemplate(0x156C2A877069b0e50dC5A74C7d1612d70144B4C6)
```

两笔原始 owner 调用分别以 Safe 为 sender 在同一区块模拟成功；并非已完成 Safe 签名或链上注册。
证据见[注册模拟](../deployments/56/index-broker-handle-templates-registration-simulation.json)和[固定区块状态](../deployments/56/index-broker-handle-templates-status.json)。

多签执行后回读：

```bash
node script/ops/index-broker-handle-templates.cjs status
```

只有两个新地址均返回 `supportedNFTTemplate == true`，才将注册记录标记为完成。

## 操作入口

在仓库根目录运行，需 Foundry / Solidity 0.8.26、Node.js，以及可解析的 `ethers` v6、`dotenv`。现有工作区通过相邻 `buy-bot` / `tagai-api` 的依赖解析这些模块。状态查询只需本地 `.env` 的 `BSC_RPC_URL`；`PRIVATE_KEY_MAIN` 仅用于部署，`ETHERSCAN_API_KEY` 仅用于公开验证。不要重复部署已记录的模板。

```bash
# 已有 journal/正式记录时不要重复部署；使用 status 核对。
node script/ops/index-broker-handle-templates.cjs status

# 刷新待签交易及 owner 调用模拟；不会提交或签署 Safe 交易。
node script/ops/index-broker-handle-templates.cjs prepare-registration

# 默认仅本地导出并重编译验证，不上传源码。
node script/ops/index-broker-handle-verify.cjs export

# 本地回归，不连接 foundry.toml 默认的 localhost RPC。
FOUNDRY_ETH_RPC_URL= forge test --match-path 'test/unit/IndexBrokerNFT*.t.sol' -vv
node --test script/ops/index-broker-handle-templates.test.cjs script/ops/version18-chain.test.cjs
```

部署脚本仅从本地环境读取既有凭据，不记录私钥或 RPC 凭据。批量合约读取统一通过 BSC Multicall3 `aggregate3`，依赖阶段固定同一区块。部署回执、代码读取和状态改变调用模拟分别记录。
