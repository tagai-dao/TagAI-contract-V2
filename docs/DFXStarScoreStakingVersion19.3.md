# DFXStar Score Staking version 19.3

网络：BSC 主网，chain ID 56。状态：已部署，BscScan 已验证，**待 Committee 白名单**。

## 已上线地址

| 合约 | 地址 |
| --- | --- |
| DFXStarScoreStakingFactory | [`0xC3C8180A675E9Fd83Cb0deB15b4af3e95613820F`](https://bscscan.com/address/0xC3C8180A675E9Fd83Cb0deB15b4af3e95613820F#code) |
| DFXStarScoreStaking 模板 | [`0x2cCf6fd4A38faB4e39053Ca8F6091a08058E1B80`](https://bscscan.com/address/0x2cCf6fd4A38faB4e39053Ca8F6091a08058E1B80#code) |

- 部署交易：[0x0c5f8f90cc23899cfe6986492b15f6fd6252009ea5655b8ca94d4a00c7b6843a](https://bscscan.com/tx/0x0c5f8f90cc23899cfe6986492b15f6fd6252009ea5655b8ca94d4a00c7b6843a)
- 部署账户：`0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`
- 正式记录：[deployments/56/version19.3.json](../deployments/56/version19.3.json)

## 相对 19.2 的修复

- `depositFromGame`：先按旧仓位结算社区奖励并 `appendUserReward`，再加仓更新 debt，避免加仓冲掉已赚奖励。
- `_refundEthToUser`：合约 ETH 余额退给 `tx.origin`（不是 `msg.sender`），避免 World/中间合约吞掉退款。

19.2 工厂 `0xd436Bb8f…` 仍在链上；新 World 建池应使用本 19.3 工厂（白名单完成后）。

## 复用 Nutbox

| 合约 | 地址 |
| --- | --- |
| CommunityFactory | `0x5597e814399906095ecaA5769A40394F58E5E0Cf` |
| Committee | `0xe10F967DD356504EDB731612789D0D0f0ba2929f` |

## 部署后

1. Committee owner 调用 `adminAddContract(0xC3C8180A675E9Fd83Cb0deB15b4af3e95613820F)`。
2. 游戏 World 部署完成后，社区 owner `adminAddPool(name, ratios, newFactory, abi.encode(world))`。
