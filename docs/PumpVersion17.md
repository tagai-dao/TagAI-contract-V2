# Pump V17 — 内盘累计买入上限与钱包转账

V17 基于 V16，`Pump.VERSION()` 返回 `17`。2026-10-26 已部署到 BSC 主网并完成四个新合约的 BscScan 源码验证，当前待多签激活；已部署 V16 的地址和记录不变。

## 累计买入上限

- 每个 Token 独立记录 `innerMarketBought(address)`，单位为 18 位精度的 token 最小单位。
- `INNER_MARKET_BUY_LIMIT()` 固定为 `10_000_000 ether`，即总量 10 亿枚的 1%。达到上限本身允许，任何超出上限的买入整笔回滚，不做部分成交。
- `buyToken` 和直接转 BNB 共用计数；每笔成功买入按实际收到的 token 数量增加。填满曲线的最后一笔按实际剩余额度成交，并沿用原有多余 BNB 退款机制。
- 卖出、转出、转入均不改变累计买入数量。买满 1000 万枚后，即使转出 40 万枚，再买 10 枚也会失败。
- 创建预买计入创建者（`indexCreator`）的累计数量，不计入中转 Pump。预买仍沿用 V16 的 handle 豁免，但没有额度豁免；超限导致整个创建回滚。
- 普通买入继续要求 V16 的 Binance HandleRegistry 注册资格；内盘钱包转账要求转出方和接收方均有非空 handle，卖出保持原有不检查 handle 的规则。
- 反狙击时由协议注入社区奖励的 token 不归买方，不计入买方额度。买入失败时计数、余额、曲线供应量和费用全部回滚。
- 该限制是每地址累计买入限制。接收转账不会消耗接收者的购买额度，因此钱包持仓可超过 1000 万枚；同一人的不同地址没有身份级合并。

## 内盘转账

- `transfer`、`transferFrom` 仅允许两个均有 Binance handle、且无部署代码的钱包地址互相转账；每笔转账实时验证双方的 `handleOf(address)` 非空。`transferFrom` 仍按标准规则使用 allowance，代操作方可以是合约，不以代操作方或 `tx.origin` 的 handle 替代双方资格。合约直接调用 HandleRegistry 校验双方，不依赖 Multicall；任何查询失败或返回数据无效均拒绝转账。链上 Multicall 规则仅用于外部 JS/RPC 批量读取。
- 不允许普通持币者转给已有合约代码的地址，或由已有代码的地址转给其他持币者；Router、Vault、DEX 池仍受限制。
- Token 自身作为一端的买卖、社区反狙击注入，以及 Pump 创建时转发预买的系统流程继续可用。
- `listingPending` 阶段仍要求双方 handle 才能钱包互转；买卖继续沿用原有冻结规则。
- 上市后继续普通 ERC20 转账及既有成分池税、奖励记账。
- “钱包”按转账时的 `address.code.length == 0` 判断；带代码的智能合约钱包或 EIP-7702 委托账户不属于此范围。尚未部署合约的地址及构造期间地址无法通过代码长度与普通钱包区分，这不是身份认证机制。

## 实现与部署入口

- `Token` 的直接 BNB 入口与 `buyToken` 复用累计额度记账和填满曲线处理，两个入口各自使用原有重入保护。买入发币使用内部 `_transfer`，保留 ERC20 奖励钩子。
- 上市 V4 资金需求固定为 15 BNB，以常量替代固定参数的运行时数学计算；专项测试用原 TickMath/SqrtPriceMath 公式核对逐 wei 等值，保持原编译设置。
- 部署入口：`script/DeployBSCPump17.s.sol:DeployBSCPump17Script`；默认所有权接收人可用 `PUMP17_OWNER` 指定。
- 通过固定区块的链上 Multicall，从 V16 Pump `0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8` 读取配置，强制验证前版本为 16，部署全新 Pump、Token implementation、Hook、BuybackRouter。
- 不得复用 V16 Token implementation；脚本校验新 Token runtime 与 V17 编译产物一致，以及 EIP-170 大小限制。
- 部署后仍需对应 owner 授予 NutboxRouter operator、BasketRegistry creator forwarder，并接收 Pump 所有权。部署脚本只输出这些后续操作，不代替多签执行。

## 验证

```bash
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --no-match-path 'test/fork/*'
BSC_RPC_URL='' FOUNDRY_ETH_RPC_URL='' forge test --match-contract PumpVersion17Test
forge build --skip test --skip script --sizes
```

V17 专项测试覆盖精确上限、连续买入、两个买入入口、卖出/转移不恢复额度、转入与持仓独立、创建预买归属与原子回滚、填满曲线按实际数量计费、钱包互转与合约转账限制、反狙击和模糊测试。
历史版本的上市/奖励测试使用多个注册钱包按额度买入，再通过实际转账汇总持仓，继续运行上市、回购、奖励及成分池税回归。

2026-10-26 按用户澄清改为合约直接查询双方 handle 后，本地 44 个测试套件：787 项通过、0 项失败、8 项跳过；V17 专项及继承回归共 62 项通过。新增检查覆盖不依赖 Multicall 的直接调用、双方资格缺失、代转者无法替代资格、查询失败/无效数据回滚、上市等待期资格检查。外部 JS 的 5 项 Multicall 固定区块与子调用完整性测试通过。Token runtime 为 23,645 bytes，Pump runtime 为 21,023 bytes；编译器为 Solidity 0.8.26+commit.8a97fa7a、viaIR、optimizer runs 100、Cancun。

## BSC 主网部署与激活

部署源码提交：`f9eb071494000f3a0026dc81584a7d8ef9ef80bd`（分支 `bsc-version17`）。

| 合约 | 主网地址 |
| --- | --- |
| Pump V17 | [0x01B2308653c7e371B28A862444a40c12ca18b353](https://bscscan.com/address/0x01B2308653c7e371B28A862444a40c12ca18b353#code) |
| Token implementation | [0x309E55BB49cE073227F8a2F67bE659dFeA3d691f](https://bscscan.com/address/0x309E55BB49cE073227F8a2F67bE659dFeA3d691f#code) |
| TagAISwapHook | [0xfF107D782cb2699F617aD96a4ccA39F8D6800cc1](https://bscscan.com/address/0xfF107D782cb2699F617aD96a4ccA39F8D6800cc1#code) |
| TagAIBuybackRouter | [0xA906917D83D47526e4c8a212606dE63a778f4151](https://bscscan.com/address/0xA906917D83D47526e4c8a212606dE63a778f4151#code) |

7 笔交易全部成功，位于区块 `129862551`–`129862580`，实际 gas `13,638,753`，费用 `0.00068193765 BNB`。区块 `129862871` 的独立 Multicall 核验确认 V16 配置及全部 16 个成分资产保留，新 Hook/Buyback 绑定正确；Token/Pump 链上 runtime 与本地产物逐字节一致，Hook/Buyback 校验不可变量绑定及屏蔽不可变量后的完整 runtime。

四个新合约均由 Foundry Standard JSON 提交至 Etherscan V2 API/BscScan 并独立查询确认验证通过。完整源码文件、构造参数、SHA-256 和结果来源见 [验证清单](../deployments/56/version17-verification/manifest.json)。

- [部署记录及全部交易](../deployments/56/version17.json)
- [Safe 激活文件](../deployments/56/version17.safe.json)
- [多签操作说明](PumpVersion17Multisig.md)

创建→handle 转账资格→多地址累计额度→上市→回购→领取→赎回的真实主网 fork 已通过（固定区块 129859627）。实际部署合约的三笔导出激活 calldata 在区块 129862871 的 fork 中顺序模拟通过。所有权接收、Router operator 和 Registry creator forwarder 仍需原 Safe 执行；没有提交主网激活、签名或 Safe 提案。
