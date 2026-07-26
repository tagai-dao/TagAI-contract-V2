# Nutbox NFT 矿池使用说明

NFTMiningPool 同时是 ERC721 NFT 和 Nutbox 矿池。用户不需要执行额外质押：NFT mint
成功后自动开始挖矿，转移 NFT 时挖矿权重和推荐权益一起转给新 owner。

## 创建者

### 创建矿池

通过 `Community.adminAddPool` 创建，主要参数如下：

| 参数 | 说明 |
| --- | --- |
| `fundsReceiver` | 扣除平台费和推荐佣金后的 mint 资金接收地址 |
| `renderer` | 生图合约；传 `address(0)` 使用平台默认动态 SVG |
| `levelThresholds` | 各等级需要的累计直推 NFT 数量，第一项必须为 `0` |
| `levelWeights` | 各等级挖矿权重，必须随等级严格递增 |
| `firstPaymentAsset` | 第一批支付资产；`address(0)` 表示原生币 |
| `firstMintPrice` | 第一批每个 NFT 的固定售价 |
| `firstBatchSupply` | 第一批发行量 |
| `firstReferralBps` | 第一批推荐比例；`100 = 1%` |

等级阈值、挖矿权重和 renderer 在矿池创建后锁定。矿池 owner 可以修改
`fundsReceiver`，但不能修改平台收费地址或平台费率。

### 管理发行批次

- 同一时间只有一个当前批次。
- 每批可以独立设置发行量、支付资产、售价和推荐比例。
- palette 不需要创建者传入，由批次 ID 自动计算：
  `paletteId = ((batchId - 1) % 6) + 1`。批次 1～6 依次使用 palette 1～6，
  批次 7 重新使用 palette 1。
- palette 同时决定该批次的底色、纹理和边框风格。
- owner 不能提前关闭当前批次，只能调用
  `setCurrentBatchPaused(true/false)` 暂停或恢复 mint。
- 当前批次售罄后自动结束，之后才能调用
  `createBatch(maxSupply, paymentAsset, mintPrice, referralBps)` 创建下一批。

### Mint 资金分配

每次 mint 按以下顺序自动分账，支付什么资产就分配什么资产：

1. 平台先按当前平台费率收费，初始值为 `0.3%`（30 BPS）。
2. 剩余净额按当前批次的 `referralBps` 支付推荐佣金。
3. 最后余额发送到 `fundsReceiver`。

推荐佣金接收人是 mint 执行时的 `ownerOf(referrerTokenId)`。没有推荐 NFT 时，
第二步金额为零。平台收款地址实时读取 Nutbox `Committee.getFeeRecipient()`；平台
费率实时读取 `NFTMiningPoolFactory.platformFeeBps()`。两者都由平台统一管理，费率
调整只影响调整后的 mint，不追溯已完成的交易。

## 挖矿者与 NFT 持有人

### Mint 与挖矿

- 调用 `mint(referrerTokenId)` 购买 NFT；无推荐时传 `0`。
- mint 成功即自动获得该 NFT 的挖矿权重，不需要 deposit 或 stake。
- 挖矿收益不从 NFT 矿池领取，统一调用
  `Community.withdrawPoolsRewards([poolAddress])` 领取。
- 当前批次暂停或 Community 关闭矿池时不能 mint，但已有 NFT 仍可正常转移。

### 推荐

- 分享推荐链接时选择自己持有的 NFT，并把它的 token ID 作为
  `referrerTokenId`。
- 每次成功 mint 都给该推荐 NFT 增加一次推荐数；同一地址可以多次购买并多次计数。
- 可以使用自己的 NFT 推荐自己 mint 新 NFT。
- 推荐数达到创建者设置的阈值时，推荐 NFT 自动升级并增加挖矿权重。
- 推荐记录属于 NFT，不属于地址。NFT 转移后，等级、推荐数、挖矿权重和未来佣金
  权利都跟随 NFT，新佣金支付给当时的新 owner。

### 转移与交易

NFT 支持标准 ERC721、ERC721Enumerable 和 OpenSea/Seaport 的授权、转移流程。
转移前会结算旧 owner 已产生的挖矿收益，随后由新 owner 按当前权重继续挖矿。

图片和 metadata 完全链上生成。随机种子决定个体构图，等级决定画面复杂度，批次
palette 决定底色与边框；升级后会发出 ERC-4906 metadata 更新事件。

## 查询一个地址持有的 NFT

前端先读取 `balanceOf(account)` 获取总数，再分页调用：

```solidity
tokensOfOwner(account, offset, limit)
```

例如每页查询 50 个：第一页传 `(account, 0, 50)`，第二页传
`(account, 50, 50)`。也可以直接使用标准 ERC721Enumerable 的
`tokenOfOwnerByIndex(account, index)`。推荐使用分页接口，避免持仓较多时单次 RPC
返回过大；需要跨多个 NFT 合约聚合时，应使用索引器或区块浏览器 API。
