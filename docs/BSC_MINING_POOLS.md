# BSC NFT Mining 与 Basket 质押矿池

本分支把 RH 上的 NFT Mining 与 Basket TVL Mining 迁移到 BSC。BSC Basket 的持有人
手续费资产是 WBNB，因此 `BasketStakePool` 使用 `BasketToken.wbnb()` 读取手续费币。

## 主网依赖

| 合约 | BSC 地址 |
| --- | --- |
| CommunityFactory | `0x5597e814399906095ecaA5769A40394F58E5E0Cf` |
| BasketRegistry | `0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe` |

上述地址默认从 `deployments/56/addresses.json` 读取，也可以通过
`BSC_COMMUNITY_FACTORY` 和 `BSC_BASKET_REGISTRY` 覆盖。

## 部署

部署脚本一次产生六个地址：

1. `NFTMiningPoolFactory`
2. `NFTMiningPoolTemplate`
3. `BSCNFTMiningRenderer`（黑金网络、赛博朋克科技风）
4. `BasketTVLMiningPoolFactory`
5. `BasketTVLMiningPoolTemplate`
6. `BasketStakePoolTemplate`

只模拟、不广播：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCMiningFactories.s.sol:DeployBSCMiningFactoriesScript \
  --rpc-url "$BSC_RPC_URL" -vvv
```

确认模拟输出后广播：

```bash
FOUNDRY_PROFILE=bsc_mainnet forge script \
  script/DeployBSCMiningFactories.s.sol:DeployBSCMiningFactoriesScript \
  --rpc-url "$BSC_RPC_URL" \
  --broadcast --slow --legacy \
  --gas-price 50000000 --gas-estimate-multiplier 150 -vvv
```

广播成功后，脚本会把六个新地址写入 `deployments/56/addresses.json`。脚本不会操作
Committee 白名单；多签需要分别对白名单加入 `NFTMiningPoolFactory` 和
`BasketTVLMiningPoolFactory`。

## 社区创建顺序

1. 先通过 `Community.adminAddPool` 创建 NFT Mining Pool。
2. 再创建 Basket TVL Mining Pool，`meta` 编码为：
   `abi.encode(nftMiningPool, nftRewardBps, lockDuration)`。
3. `nftMiningPool` 必须是同一 Community 的活跃矿池，并且由部署时绑定的
   `NFTMiningPoolFactory` 创建。
4. Basket 创建者持有该 NFT Mining Pool 的 NFT 后，才能为自己的 Basket 创建子池。

Basket 子池以 Community Token 在 Basket 合约中的实际余额作为父池挖矿权重，用户
质押 Basket ERC20 后分享 Community 奖励和 Basket 的 WBNB 持有人手续费。

Community Token 不能是 WBNB，因为 Community 奖励币和持有人手续费币必须不同，
否则两个奖励会共用余额、无法可靠区分会计来源，子池初始化会拒绝该配置。

## 验证

```bash
# 单元测试
FOUNDRY_ETH_RPC_URL= forge test --match-path test/unit/NFTMiningPool.t.sol
FOUNDRY_ETH_RPC_URL= forge test --match-path test/unit/BasketTVLMiningPool.t.sol

# BSC 最新区块 fork：创建真实 USDC Basket 并完成 NFT、质押、退出和赎回流程
FOUNDRY_PROFILE=fork BSC_RPC_URL="$BSC_RPC_URL" FOUNDRY_ETH_RPC_URL= \
  forge test --match-path test/fork/BSCMiningPools.t.sol -vvv
```
