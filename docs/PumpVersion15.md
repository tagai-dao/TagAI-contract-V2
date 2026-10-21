# Pump V15 — BSC 内盘注册资格

分支 `version15`，基于 2026-10-21 拉取的最新 `origin/main`：
`2a8c13705f1b4742b23aa988486ee2eb25d26989`。部署源码已归档为 `886309b`，文件 SHA-256 与部署记录逐一一致。2026-10-21 已部署至 BSC 主网；用户已报告完成多签，区块 `128870733` 核验时授权与所有权接收仍待链上执行。正式地址、部署记录与兼容范围见 [PumpVersion15Deployment.md](PumpVersion15Deployment.md)。

## 规则

- 只有 `Pump.createToken` 交易内的创建预买免检；创建代币本身也不要求注册。
- 创建完成后，每次内盘买入都要检查，包含部署者后续买入。没有创建预买时，部署者创建后的第一笔买入也要检查。
- 内盘买方只调用 BSC 合约 `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`
  的 `handleOf(msg.sender)`，返回字符串非空即可买入。空字符串回滚 `HandleNotRegistered(buyer)`。
- 同时覆盖 `buyToken` 和直接转入 BNB 的购买，包括反狙击期及填满内盘。
- 不增加注册合约存在性探测、字符串内容/格式校验或模板兼容性检查。
- 卖出、普通 ERC20 转账及上市后交易不增加注册限制。

接口已通过 [Sourcify 已验证 ABI](https://sourcify.dev/server/v2/contract/56/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F?fields=abi,sources)
核对：`handleOf(address)` 返回 `string`。源码的函数名为小写 `handleOf`。

## 编译与部署

`Pump.VERSION()` 为 `15`。Solidity 保持 `0.8.26`、viaIR=true；optimizer runs 从 200 调整为 100，
以满足 EIP-170 的 24,576 字节上限，并保持上述业务实现为普通 Solidity 字符串非空判断。

V15 部署脚本 `DeployBSCPump15.s.sol` 强制为 Pump 的 `existingTokenImplementation` 传 `address(0)` 创建新模板。
V14 部署脚本默认复用旧模板，不能用于这次功能发布。
旧模板和已部署代币不会自动获得新限制。本次已由用户广播部署成功；源码浏览器验证尚未核查或提交，权限激活按独立的链上状态记录。

## 测试

新增 `test/unit/PumpVersion15.t.sol` 验证空/非空 handle、普通购买、直接 BNB 购买、
两种创建重载的预买免检、部署者创建后的首笔及后续买入必须注册、失败回滚、反狙击、填满内盘、卖出与转账、任意非空字符串，
并继承原有生命周期、上市、回购和奖励回归测试。

```bash
FOUNDRY_ETH_RPC_URL='' forge test --offline --match-path test/unit/PumpVersion15.t.sol -vv
FOUNDRY_ETH_RPC_URL='' forge test --offline \
  --no-match-path 'test/fork/*' --no-match-contract CommentMarketsForkTest
```

2026-10-21 最新规则本地验证：42 个套件，760 通过、0 失败、2 个原有用例跳过。
Token runtime 为 24,372 字节，通过部署尺寸检查；另已在 BSC 固定区块 `128866480` 完成无广播部署模拟及真实 Nutbox/Basket/NFT/DEX 全流程 fork，1 通过。
发布前再次执行 V15 与 Multicall 两组定向回归，48 通过、0 失败、0 跳过；格式及差异空白检查通过。
