# TagAI Contract V2 版本与部署记录

本文档记录正式发布版本的源码提交、链上地址和部署批次，用于确认某一组线上合约对应的源码。

## 记录规则

- 新版本按时间倒序追加，最新版本放在最前面。
- `版本源码提交` 是该版本部署和验证所依据的固定提交；部署后不得在不变更版本记录的情况下改用其他提交。
- `部署记录提交` 是把最终地址、交易和验证结果写回本仓库的提交。由于提交只能在部署完成后产生，它通常晚于版本源码提交。
- 每个 `versionN.json` 是该版本可独立读取的累积快照；仍然有效的旧地址会复制到新版本，已被替换的地址保留在旧版本文件中。
- 一个版本可以复用旧合约。复用地址必须标明为“复用”，不能被误认为在该版本中重新部署。
- 正式发布记录应尽量包含部署交易、区块、最终 owner、Committee 白名单状态和浏览器验证状态。历史资料未保存的字段明确标记为待补充，不凭推测填写。

---

## 协议版本关系

这里的版本号对应不同的协议入口，不表示较新的编号一定替代所有较早入口。当前新发社区代币使用 Pump V11；已经存在的外部 ERC20 通过 ImportHelper V10 接入 Nutbox。V9 及更早 Pump 创建的 Token 继续使用各自部署时绑定的实现和池配置。

| 版本 | 状态 | 功能定位 |
| --- | --- | --- |
| V1–V7 | 历史版本 | 早期 bonding curve、IPShare 和 PCS Hook 迭代，源码与历史地址位于旧版 [`tagai-contract`](https://github.com/tagai-dao/tagai-contract) 仓库。 |
| V8 | 已被新发行入口替代 | 面向 Agent 社区，bonding curve 上市前只允许 Agent 交易，并为 Nutbox Community 自动分配 15% 供应量。 |
| V9 | 历史发行入口 | 通过 Pump 创建新社区代币，支持开放 bonding curve 交易、反狙击、PCS V4 上市、TagAISwapHook 和 Nutbox 奖励注入；既有 Token 保持原实现。 |
| V10 | 当前外部代币导入入口 | 通过 ImportHelper 将已部署 ERC20 接入 Nutbox，创建不可增发 Community 和默认 SocialCuration Pool；不创建 Token、bonding curve、PCS V4 池或 Hook。 |
| V11 | 当前新发行入口 | 更新 Pump、Token implementation 和 TagAISwapHook，并增加 Index Broker NFT、NFT AMM、指数回购与指数挖矿。所有新合约均已部署并完成源码验证。 |

---

## V11 — BSC 正式版本

V11 使用累积部署快照。`version11.json` 从 V10 继承仍然有效的合约地址，并记录本次新部署的 Pump、Token implementation、TagAISwapHook 和 Index Broker NFT 合约组。

| 项目 | 记录 |
| --- | --- |
| 状态 | Pump V11 已上线；升级后的 Index Broker NFT 合约已部署、完成 BscScan 源码验证和主网 Fork 测试，Factory 在最终 Owner 交接前保持未授权状态 |
| 网络 | BNB Smart Chain（chain ID `56`） |
| 来源版本 | V10 |
| 版本源码提交 | [`a573440387b079252bb936bcfa2ae14d52cacdc6`](https://github.com/tagai-dao/TagAI-contract-V2/commit/a573440387b079252bb936bcfa2ae14d52cacdc6) |
| Index Broker NFT 升级源码提交 | [`cac9b4e8e4c5e6ecc0fbbf2f3b046b5af1435442`](https://github.com/tagai-dao/TagAI-contract-V2/commit/cac9b4e8e4c5e6ecc0fbbf2f3b046b5af1435442) |
| Pump 部署记录提交 | [`9a7f9f77441304e2f27744fa8773786ca74015f9`](https://github.com/tagai-dao/TagAI-contract-V2/commit/9a7f9f77441304e2f27744fa8773786ca74015f9) |
| Index Broker 部署记录提交 | [`43aa618e4f221720a849dbe6d52506849730bbf4`](https://github.com/tagai-dao/TagAI-contract-V2/commit/43aa618e4f221720a849dbe6d52506849730bbf4) |
| 部署日期 | Pump V11：2026-08-14；NutboxRouter 与 NFT 升级：2026-08-18 |
| 部署账户 | [`0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`](https://bscscan.com/address/0x78c2af38330c5b41ae7946a313e43cdceeaf8611) |
| 目标管理地址 | [`0x871fb7006C5964B21695Ba20006021777A26146C`](https://bscscan.com/address/0x871fb7006c5964b21695ba20006021777a26146c) |
| 部署快照 | [`deployments/56/version11.json`](deployments/56/version11.json) |
| Pump/Token/Hook 详细更新 | [`docs/PUMP_TOKEN_HOOK_V11.md`](docs/PUMP_TOKEN_HOOK_V11.md) |
| Index Broker NFT 详细说明 | [`src/nutbox/dapps/index-broker-nft/README.md`](src/nutbox/dapps/index-broker-nft/README.md) |

### Pump、Token implementation 与 Hook

| 合约 | BSC 主网地址 | 部署交易 / 区块 |
| --- | --- | --- |
| Pump | [`0x8fEF5b4c0f761a0cc447800e3019B089ac306F28`](https://bscscan.com/address/0x8fef5b4c0f761a0cc447800e3019b089ac306f28) | [`0x4e450e...36307`](https://bscscan.com/tx/0x4e450e816c1e752172fc60568f636a2dcc4b019ef2b86c56d31220ccaff36307) / `115869783` |
| Token implementation | [`0xfD40C112F39D372786265a032C546D05Feec4D66`](https://bscscan.com/address/0xfd40c112f39d372786265a032c546d05feec4d66) | 由 Pump 构造函数在同一交易中创建 / `115869783` |
| TagAISwapHook | [`0x9E38747072F326b4e614EfF6FdCA8529db090cc1`](https://bscscan.com/address/0x9e38747072f326b4e614eff6fdca8529db090cc1) | [`0xaf2a6f...cf98c2`](https://bscscan.com/tx/0xaf2a6fe984638464dda75399c55e3ebcac512f18bf2ab4ec507adc936c7aee58) / `115869796` |

Hook CREATE2 salt 为 `5845`，权限位图为 `0x0cc1`。三个地址均已完成 BscScan 源码验证。

本次 Pump/Token/Hook 的主要变化：

- 新上市池启用原生 0.3% LP Fee，上市流动性继续永久保存在 Token 合约仓位中；
- 任何地址可调用 `Token.collectFees()`，BNB LP Fee 的 0.5% 奖励调用者、其余发送平台，社区 Token LP Fee 进入原上市 Hook；
- Token 在上市时固定 Hook 和 Pool 参数，Pump 后续更换默认 Hook 不会改变旧池；
- Hook 上市后不再读取 Pump 的内盘 `feeRatio`：买入收取 BNB 侧 0.3% 给 IPShare 和社区 Token 输出侧 0.3% 给 Nutbox；卖出按同一 BNB 毛金额分别收取 0.3% 给 IPShare、0.3% 给平台；
- Hook 注入预算改为实际 Token 余额，可由初始 150M、买入 Token Fee、LP Token Fee 和外部转账持续补充；
- 修正公开第一笔买入绕过 anti-snipe、窗口内触发上市、Calculator 选择及失败授权残留；
- Pump 在创建 Community 后把 `devFund` 设置为 Token 创建者，并向创建者发起 Community 管理权交接。

完整资金流、兼容范围和安全不变量见 [`Pump、Token 与 TagAISwapHook V11 更新说明`](docs/PUMP_TOKEN_HOOK_V11.md)。

### Index Broker NFT 合约组

| 合约 | BSC 主网地址 | 部署交易 / 区块 |
| --- | --- | --- |
| StonkBrokerRenderer | [`0xd4B6120f566CDecD88b7Be6f994a6c7493F8a068`](https://bscscan.com/address/0xd4b6120f566cdecd88b7be6f994a6c7493f8a068) | [`0x03bf54...128bf`](https://bscscan.com/tx/0x03bf54163e7379b91fbd300e994861f5508ec7c58ad0ce165793eb40d38128bf) / `115870623` |
| StonkBrokerFaceRenderer | [`0x42f24CfAaaE018c24f44820bfA9C0694981551CC`](https://bscscan.com/address/0x42f24cfaaae018c24f44820bfa9c0694981551cc) | Renderer 构造函数内部创建 / `115870623` |
| StonkBrokerBodyRenderer | [`0xA6269124844addc89A62CBb760b0b58a28977b42`](https://bscscan.com/address/0xa6269124844addc89a62cbb760b0b58a28977b42) | Renderer 构造函数内部创建 / `115870623` |
| StonkBrokerAccessoryRenderer | [`0xc76717354091DcFb177c3B4e162aBC4Fca202D87`](https://bscscan.com/address/0xc76717354091dcfb177c3b4e162abc4fca202d87) | Renderer 构造函数内部创建 / `115870623` |
| NutboxRouter（平台共享） | [`0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f`](https://bscscan.com/address/0x04e2d43ba38e3f3f0d0dab3a30d1b58bfe9b659f) | [`0xf7dc70...27246`](https://bscscan.com/tx/0xf7dc700379de2c8003838b35f393804a4834840aa4bcf88d7e9b2a5518a27246) / `116637869` |
| IndexBrokerNFTBurn template | [`0x1D875946C87a650AF2Aa5B04427D44E647a480B9`](https://bscscan.com/address/0x1d875946c87a650af2aa5b04427d44e647a480b9) | [`0x73d7a4...7361a`](https://bscscan.com/tx/0x73d7a4026fef4d3e661875e76803392c52d28a06df686f1febc0c85f0c07361a) / `116652658` |
| IndexBrokerNFTStake template | [`0xc24Ff0009fF1AaD70eF8714ee32ebc8f6b7983a5`](https://bscscan.com/address/0xc24ff0009ff1aad70ef8714ee32ebc8f6b7983a5) | [`0x874a2e...15d05`](https://bscscan.com/tx/0x874a2ece2eca36ee87facc6a09dc1980b3f135cd4f4ce43b1945f0e96da15d05) / `116652661` |
| IndexBrokerNFTAMM template | [`0x698680412e34db49CdBa62c46a0Faad31D05ce0A`](https://bscscan.com/address/0x698680412e34db49cdba62c46a0faad31d05ce0a) | [`0x7aa9a4...1405`](https://bscscan.com/tx/0x7aa9a457cdb5863d4ad725e4050fdee0133cb240e14a251a027b27ed2f8a1405) / `116652664` |
| IndexBrokerNFTFactory | [`0xB1708D2F3A504846a47cdB2e4Dfb48b3ea1c9b5F`](https://bscscan.com/address/0xb1708d2f3a504846a47cdb2e4dfb48b3ea1c9b5f) | [`0x472ac6...ffdb`](https://bscscan.com/tx/0x472ac65e4f2ba424b9965377b2deea90511f131d0f2b3d087c6e14c6f55fffdb) / `116652670` |

以上当前地址均已完成 BscScan 源码验证，并在 BSC 区块 `116653696` 完成部署后 Fork 生命周期测试。Renderer 及三个子 Renderer 沿用原部署；旧 `IndexBrokerNFTPriceOracle` 和未公开的旧 Factory、Pool、AMM 地址已被共享 NutboxRouter 与本表新地址取代。Index Broker NFT 的铸造模式、动态模板、白名单、AMM、DEX 价格源、指数回购、社区/指数双挖、揭图和 Renderer 接口，统一以 [`Index Broker NFT 矿池说明`](src/nutbox/dapps/index-broker-nft/README.md) 为准。

---

## Pump V9 / ImportHelper V10 — V11 之前的 BSC 基线

这是合并 Index Broker NFT 以及 Pump、Token、Hook 下一次升级之前，`main` 分支上的完整生产基线。V9 和 V10 是并行入口：V9 用于发行新社区代币，V10 用于导入已有 ERC20。

| 项目 | 记录 |
| --- | --- |
| 状态 | V11 发布前的生产基线；历史地址继续服务既有 Token 和外部代币导入 |
| 网络 | BNB Smart Chain（chain ID `56`） |
| 完整基线提交 | [`06933725e6bc684a1e9c59da8a03c787e23e3a75`](https://github.com/tagai-dao/TagAI-contract-V2/commit/06933725e6bc684a1e9c59da8a03c787e23e3a75) |
| 源码分支 | `main` |
| 基线记录日期 | 2026-08-14 |
| V9 部署快照 | [`deployments/56/version9.json`](deployments/56/version9.json) |
| V10 部署快照 | [`deployments/56/version10.json`](deployments/56/version10.json) |
| 历史标签 | `version9` → [`a5e58f75cf98cf12adf68cb6f7bbb9932ea8af50`](https://github.com/tagai-dao/TagAI-contract-V2/commit/a5e58f75cf98cf12adf68cb6f7bbb9932ea8af50) |

> `version9` 标签早于 NFT Mining 和 Basket Mining 的提交，因此该标签不能单独代表本节列出的完整线上基线。完整基线以 `06933725e6bc684a1e9c59da8a03c787e23e3a75` 为准。

### 部署账户

| 项目 | 地址 |
| --- | --- |
| 历史部署账户 | [`0xf0a27ec9bb8AC28007cB474fC1ea0A9396fe6991`](https://bscscan.com/address/0xf0a27ec9bb8ac28007cb474fc1ea0a9396fe6991) |

### Pump V9 核心合约

本批地址由提交 [`149ba65b6bded78c7c59b1792f0c6837fbedb8f9`](https://github.com/tagai-dao/TagAI-contract-V2/commit/149ba65b6bded78c7c59b1792f0c6837fbedb8f9) 写入部署记录；该提交同时包含对应的 Pump/Hook 源码调整。仓库记录日期为 2026-05-25。

| 合约 | BSC 主网地址 | 备注 |
| --- | --- | --- |
| Pump | [`0x327a473c763bcf0d60CCd6811F832332939110D5`](https://bscscan.com/address/0x327a473c763bcf0d60ccd6811f832332939110d5) | V9 工厂 |
| Token implementation | [`0x69B1B0635220e5f16A36Ad44c3B2B1FB9ca65e16`](https://bscscan.com/address/0x69b1b0635220e5f16a36ad44c3b2b1fb9ca65e16) | Pump 创建 Token 使用的实现 |
| TagAISwapHook | [`0x78443e75aD3D70DAAab0De33d2D5Dea0cBae0cC1`](https://bscscan.com/address/0x78443e75ad3d70daaab0de33d2d5dea0cbae0cc1) | PCS V4 Hook；CREATE2 salt 为 `1105` |

### ImportHelper V10

本批地址及源码由提交 [`33d26e54c5ad5bb2cef859bab0cb9eed9cf641f5`](https://github.com/tagai-dao/TagAI-contract-V2/commit/33d26e54c5ad5bb2cef859bab0cb9eed9cf641f5) 记录。仓库记录日期为 2026-06-01。

| 合约 | BSC 主网地址 |
| --- | --- |
| ImportHelper | [`0xF346A700830633bB27a46fC1e7eAAE49F593A4c6`](https://bscscan.com/address/0xf346a700830633bb27a46fc1e7eaae49f593a4c6) |

ImportHelper V10 与 Pump V9 的用途不同：它只为已有 ERC20 创建绑定该代币的不可增发 Community，设置调用者为 `devFund`，挂载默认 100% 奖励比例的 SocialCuration Pool，并把 Community 所有权交给调用者。它不部署 ERC20、Pump Token、bonding curve、PCS V4 流动性池或 TagAISwapHook。

### NFT Mining 与 Basket Mining

本批地址及源码由版本源码提交 [`06933725e6bc684a1e9c59da8a03c787e23e3a75`](https://github.com/tagai-dao/TagAI-contract-V2/commit/06933725e6bc684a1e9c59da8a03c787e23e3a75) 记录。仓库记录日期为 2026-08-03。

| 合约 | BSC 主网地址 |
| --- | --- |
| NFTMiningPoolFactory | [`0x21155400f915A239ca2228243cFE3761caF60128`](https://bscscan.com/address/0x21155400f915a239ca2228243cfe3761caf60128) |
| NFTMiningPoolTemplate | [`0x0a937898800444497175316f925a2aE1CA83E592`](https://bscscan.com/address/0x0a937898800444497175316f925a2ae1ca83e592) |
| BSCNFTMiningRenderer | [`0x9e2878532240d79470bf4dE615eAc2A1E85546C9`](https://bscscan.com/address/0x9e2878532240d79470bf4de615eac2a1e85546c9) |
| BasketTVLMiningPoolFactory | [`0x6B1B18336E774164dF01EfDC0901559909f2d074`](https://bscscan.com/address/0x6b1b18336e774164df01efdc0901559909f2d074) |
| BasketTVLMiningPoolTemplate | [`0xcbe3A0441D2f60dCc09A707C7F9B2dA42C3b8af1`](https://bscscan.com/address/0xcbe3a0441d2f60dcc09a707c7f9b2da42c3b8af1) |
| BasketStakePoolTemplate | [`0x34E5fC87f95816c3144EA16a8EDD52F2Df9D1D28`](https://bscscan.com/address/0x34e5fc87f95816c3144ea16a8edd52f2df9d1d28) |

### 复用的 Nutbox、Basket、IPShare 与 PCS V4 基础设施

以下地址是 V9 依赖或复用的正式合约，不是上述三个部署批次中新部署的合约。

| 合约 | BSC 主网地址 |
| --- | --- |
| Committee | [`0xe10F967DD356504EDB731612789D0D0f0ba2929f`](https://bscscan.com/address/0xe10f967dd356504edb731612789d0d0f0ba2929f) |
| CommunityFactory | [`0x5597e814399906095ecaA5769A40394F58E5E0Cf`](https://bscscan.com/address/0x5597e814399906095ecaa5769a40394f58e5e0cf) |
| BasketRegistry | [`0x5B45ad2c3A2B8b8989579162C4faE2D64598Cefe`](https://bscscan.com/address/0x5b45ad2c3a2b8b8989579162c4fae2d64598cefe) |
| HourlyTickCalculator | [`0x6cCEC02E7D371FED954D7D16eCb7F2f57cccF54d`](https://bscscan.com/address/0x6ccec02e7d371fed954d7d16ecb7f2f57cccf54d) |
| SocialCurationFactory | [`0xc4674D3fBbD201Ea401a8B7e7285F956178593D8`](https://bscscan.com/address/0xc4674d3fbbd201ea401a8b7e7285f956178593d8) |
| DFXStarScoreStakingFactory | [`0x77Fb65140B746e639bB512c2C25604d1924aE774`](https://bscscan.com/address/0x77fb65140b746e639bb512c2c25604d1924ae774) |
| DFXStarScoreStaking | [`0x2D91b9a98A49C8dd2CF68Be2F8ABbFB3a78C2eae`](https://bscscan.com/address/0x2d91b9a98a49c8dd2cf68be2f8abbfb3a78c2eae) |
| IPShare | [`0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922`](https://bscscan.com/address/0x95450aad4cc195e03bb4791b7f6f04ac6d9ba922) |
| PancakeSwap V4 CLPoolManager | [`0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b`](https://bscscan.com/address/0xa0ffb9c1ce1fe56963b0321b32e7a0302114058b) |
| PancakeSwap V4 Vault | [`0x238a358808379702088667322f80aC48bAd5e6c4`](https://bscscan.com/address/0x238a358808379702088667322f80ac48bad5e6c4) |

### 历史记录缺口

当前仓库只保存了以上地址，没有保存全部部署交易哈希和部署区块。以下信息后续如能从广播文件、部署钱包或区块浏览器可靠恢复，应补充到本节：

- 每个部署批次的交易哈希和区块号；
- 各 Ownable 合约当前 owner，以及两步所有权是否已完成接收；
- NFTMiningPoolFactory、BasketTVLMiningPoolFactory 等合约的 Committee 白名单交易；
- BscScan 源码验证状态及对应验证参数。
