# DFXStar Score Staking version 19.2

网络：BSC 主网，chain ID 56。状态：已部署，BscScan 已验证，**待 Committee 白名单**。

## 已上线地址

| 合约 | 地址 |
| --- | --- |
| DFXStarScoreStakingFactory | [`0xd436Bb8fF9BdF45b85aAC0dB038F14a9Ad14610B`](https://bscscan.com/address/0xd436Bb8fF9BdF45b85aAC0dB038F14a9Ad14610B#code) |
| DFXStarScoreStaking 模板 | [`0xa0803dAD0F07a6F5C3633AF9910f5cf8DC562FaB`](https://bscscan.com/address/0xa0803dAD0F07a6F5C3633AF9910f5cf8DC562FaB#code) |

- 部署交易：[0x817a0921ad2a86d81357a4c3d546756cfe700da44aba19a312e687adcecb188e](https://bscscan.com/tx/0x817a0921ad2a86d81357a4c3d546756cfe700da44aba19a312e687adcecb188e)
- 部署账户：`0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`
- 正式记录：[deployments/56/version19.2.json](../deployments/56/version19.2.json)

## 变更

相对链上旧工厂 `0x77Fb65140B746e639bB512c2C25604d1924aE774`：

- 建池时 `meta` 必须是 `abi.encode(world)`，长度 32。
- 每个 World 只能绑一个积分池（`poolOfWorld`）。
- 池子 `initialize(community, world)`；`depositFromGame` 只接受绑定的 World。
- 工厂 `isAdmin` 仍保留，但不再决定谁能记分。

复用 Nutbox：

| 合约 | 地址 |
| --- | --- |
| CommunityFactory | `0x5597e814399906095ecaA5769A40394F58E5E0Cf` |
| Committee | `0xe10F967DD356504EDB731612789D0D0f0ba2929f` |

## 部署

记录骨架：[deployments/56/version19.2.json](../deployments/56/version19.2.json)。

```bash
# 模拟（不上链）
source .env
forge script script/DeployBSCDFXStarFactory19_2.s.sol:DeployBSCDFXStarFactory19_2Script \
  --rpc-url "$BSC_RPC_URL" --chain-id 56 -vv

# 广播 + 验证（确认后再跑）
forge script script/DeployBSCDFXStarFactory19_2.s.sol:DeployBSCDFXStarFactory19_2Script \
  --rpc-url "$BSC_RPC_URL" --chain-id 56 --broadcast --legacy \
  --verify --etherscan-api-key "$BSCSCAN_API_KEY" -vv
```

需要 `PRIVATE_KEY_MAIN`。可选 `DFX19_2_OWNER`：若与部署者不同，脚本会 `transferOwnership`，目标需再 `acceptOwnership()`。

## 部署后

1. Committee owner 调用 `adminAddContract(newFactory)`。
2. 游戏 World 部署完成后，社区 owner `adminAddPool(name, ratios, newFactory, abi.encode(world))`。
3. 回填 `version19.2.json` 中的工厂/模板地址与交易。
