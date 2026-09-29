# BSC 股票路由扩展（2026-09-29）

状态：代码、配置及本地主网 fork 验证完成；用户已反馈正在等待多签签核，尚未核验链上执行完成。多签执行前，不得标记为已上线。

复用 NutboxRouter `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` 与 Pump14
`0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34`，无需重新部署任何合约。
此次不修改已有的默认路径；如果检测到与预期不同的池或路径，准备脚本会中止供人工复核。

| 资产 | Token | PancakeSwap V3 / USDT 池 |
| --- | --- | --- |
| INTCB | `0xe614e2fc6c787035ff51f452e8e826bfd32d5283` | `0x4dD8e7C67033Ef4A745bB9f82a7C57c676eB2481` |
| AMZNB | `0x1a4b499833A79A09ad7Cf1D42D7DacF71e92eb00` | `0x7530beb7Bde5843f668cf31b996fa1F748C9b6B1` |
| SNDKB | `0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb` | `0xE4B5403f5103b02d1E8193B0D7D76D49F3F8ad77` |
| METAB | `0x7425889FE94F9d693E8daefE88BCCed6AcFEf4c0` | `0xC2151a561E928D16576d75Ea88544543ac63D80B` |

四个池费率均为 2500（0.25%），代币精度均为 18。
2026-09-29 查询的池总资产分别约为 $520,049、$238,445、$236,920、$210,634。
这些是筛选时的行情快照，不是价格附近可成交深度，也不是合约强制维持的最低流动性。
行情可通过 `https://api.dexscreener.com/token-pairs/v1/bsc/<token>` 复核。

## 配置及执行

每个代币最多四项调用，完整批次最多 16 项：

1. Router `addPricePool(V3_POOL, abi.encode(factory, pool))`。
2. Router `addRoute(token, USDT, [assetPairId])`，自动双向。
3. Router `addRoute(token, WBNB, [assetPairId, hubPairId])`，自动双向并支持原生 BNB。
4. Pump14 `adminSetConstituentApproval(token, true)`，开放新代币创建时的指数成分选择。

先在本地 fork 准备并验证交易文件（不使用私钥、不广播）：

```bash
FOUNDRY_PROFILE=fork forge script script/PrepareBSCStockRoutes.s.sol \
  --rpc-url "$BSC_RPC_URL" --chain-id 56 -vv

FOUNDRY_PROFILE=fork forge test \
  --match-path test/fork/BSCStockRouteExpansion.t.sol \
  --fork-url "$BSC_RPC_URL" --chain-id 56 -vv
```

脚本核对链 ID、当前 Router/Pump owner、Pump 绑定的 Router、Factory、池的代币对、费率及活跃流动性。
随后以 owner 身份仅在本地 fork 按顺序模拟全部调用，写出
`deployments/56/stock-routes-20260929.safe.json`，可导入 Safe Transaction Builder。
仅补缺失的配置；已存在且一致的池、路径、白名单不会重复生成交易。
测试另行执行全部四个资产的 USDT 和 BNB 双向真实池交换，验证输出、授权和 Router 无资金滞留。

将 JSON 导入当前 owner 多签，核对目标地址和顺序后发起签核。执行确认后再次运行准备脚本，
应显示 0 项待执行调用。记录执行交易哈希后再把本条状态改为已生效。

随后更新并重启 `tagai-api`，更新部署 `tiptag-ui`：

- API `config/v13-assets.json`：Pump14 API 共用的候选表。
- UI `src/utils/v13/creation-assets.json`：创建页面的链上读取回退候选表。
- UI `src/config/baskets.ts`：篮子创建候选，补 INTCB/SNDKB；AMZNB/METAB 原本已在表中。

Pump 创建选项继续以链上 `approvedConstituent` 过滤，避免在多签执行前开放未批准资产。
无需数据库迁移或 server worker 更新。

`BSCNutboxRouterConfig` 同步增加这四个资产作为将来新部署的默认目录；
该源码修改本身不会改变现有 Router 或 Pump 的链上状态。

## 本次验证记录

- 配置模拟区块：`124688580`，16 项调用全部成功；再次准备得到 0 项剩余调用。
- 当前 Router 与 Pump14 owner 均为 `0x871fb7006C5964B21695Ba20006021777A26146C`。
- 买卖测试 fork 区块：`124688594`。四个资产各测试 USDT 买入/卖出、原生 BNB 买入/卖出，共 16 次池交换；检查实际到账、95% 最低输出及 Router 无新增资金滞留。1 项集成测试通过，0 失败、0 跳过。
- Router 单元测试：17 通过；API V13/V14 创建测试：32 通过；UI 创建配置和 V14 创建测试：23 通过，类型检查通过。
- Safe JSON 已重新解码核对：chain ID 56、16 项、全部 value=0，调用顺序为每个资产的池、USDT 路径、BNB 路径、Pump14 白名单。
- 助手未广播主网交易或发起多签提案。用户随后反馈正在等待多签签核；尚无已核验的执行交易哈希，本记录不是上线确认。
