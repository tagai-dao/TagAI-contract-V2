# RH 合约源码验证标准流程

2026-10-12 用户确认：**后续 RH 合约默认使用浏览器上传 Solidity Standard JSON Input 验证**。
本规则适用于 RH 主网及测试网、当前仓库和其他 RH 合约项目。
命令行只负责导出验证文件，默认不通过 Blockscout API 提交源码验证。

## 采用原因与成功案例

本次 `forge verify-contract --verifier blockscout` 在 `getabi` 阶段收到 Cloudflare
`Just a moment...` HTML，独立只读检查为 HTTP 403。浏览器验证表单可正常打开。
改为上传 Standard JSON 后，用户确认 RH ImportHelperV2 已完成源码验证。
不要将此类 API 拦截解释为部署失败，也不要为验证失败重新部署合约。

| 项目 | 本次已确认值 |
| --- | --- |
| 合约 | `src/helper/ImportHelperV2.sol:ImportHelperV2` |
| 主网地址 | `0x70eD7C79d80dEDE1828a09B3c526df283111Cb82` |
| 部署交易 | `0xc81cbd3a01a156a3697322fc64878f717597bd8de364f0f3533098023e0a44b0` |
| 部署区块 | `86448655` |
| 部署源码提交 | `3dcd8443263e80cf4d316e5a137617ed7b86546b` |
| 编译器 | `v0.8.26+commit.8a97fa7a` |
| 编译配置 | viaIR=true、optimizer=true / 200 runs、EVM Cancun |
| 验证方法 | 浏览器 `Solidity (Standard JSON input)` |
| License | MIT，与源码 SPDX 一致 |
| 验证结果 | 2026-10-12 操作员确认已验证 |

标准输入保存于 [import-helper-v2-standard-input.json](../deployments/4663/import-helper-v2-standard-input.json)，
完整部署及核验证据见 [import-helper-v2.json](../deployments/4663/import-helper-v2.json)。
该文件仅适用于上述源码和合约，不能直接用于验证其他合约。

## 每次验证的准备

1. 从成功部署收据取得真实地址、chain ID、部署交易/区块，不使用模拟地址。
2. 锁定部署使用的源码提交和 Foundry profile；使用 artifact 的完整 compiler version，
   不仅记录 `pragma` 范围。确认 viaIR、optimizer runs、evmVersion、remappings、libraries 和 metadata 设置。
3. 在相同源码和配置中导出 Standard JSON；包含依赖源码的 `content` 和原始编译设置。
   不 flatten，不为验证而修改源码或编译参数。
4. 将文件保存到 `deployments/<chainId>/<合约标识>-standard-input.json`，
   校验 JSON 语法、目标源码和 settings，并在部署记录保存其 SHA-256。
5. 仅导出 Solidity 源码和编译设置，不将 `.env`、私钥、API 凭证或缓存中的敏感数据包含在文件中。

本次实际使用的导出命令（其他合约必须替换 profile、地址、合约路径、编译器及输出文件）：

```bash
FOUNDRY_PROFILE=rh_mainnet forge verify-contract \
  0x70eD7C79d80dEDE1828a09B3c526df283111Cb82 \
  src/helper/ImportHelperV2.sol:ImportHelperV2 \
  --chain 4663 --compiler-version v0.8.26+commit.8a97fa7a \
  --show-standard-json-input \
  > deployments/4663/import-helper-v2-standard-input.json
```

`--show-standard-json-input` 只生成文件，不提交浏览器验证。
Forge 可能需要读取公开的编译器版本列表；导出失败时检查退出码，不能把空文件交给操作员。

## 浏览器提交

主网浏览器：`https://robinhoodchain.blockscout.com`；
测试网浏览器：`https://explorer.testnet.chain.robinhood.com`。
打开对应地址的 Contract / Code 页，进入 **Verify & publish**。

操作员在表单中：

1. 选择 **Solidity (Standard JSON input)**。
2. 选择与部署 artifact 相同的完整 Compiler 版本。
3. 选择与目标源码 SPDX 一致的 License，本次 ImportHelperV2 为 MIT。
4. 上传生成并校验的 Standard JSON 文件，点击 **Verify & publish**。
5. 若页面要求指定合约名或 constructor args，使用原始完整合约标识和真实 CREATE 交易中的参数。
   大多数编译设置已包含在 JSON 中，不使用界面默认值替换部署配置。

部署调试和验证继续遵守操作员逐步执行的协作方式；需要人工完成页面验证时，
交付具体文件、地址页和表单设置。未提交或尚无成功结果时，记录为 pending，不写“已验证”。

## 完成后记录

- 地址页显示已验证，合约名和 compiler/config 与部署一致；记录确认日期、方法和结果来源。
- 保存文件 SHA-256、源码提交、真实部署地址/交易/区块及浏览器链接。
- 操作员确认与 agent 独立核验分别标注，不能把操作员回传描述成 agent 已独立核验。
- 源码验证、链上部署、owner/registrar 激活和 API/UI 生效是不同状态，分别记录。
- 对不匹配结果先检查源码、依赖和编译设置；不重跑部署来修复验证问题。

## Agent 默认约定

后续 RH 开发先读本文。不要先尝试 CLI 直连 Blockscout 验证 API，再因拦截让操作员重试。
默认直接生成 Standard JSON 并给出浏览器步骤。本仓库的 `make verify-rh-import-helper-v2`
已改为导出文件并提示浏览器验证，不再调用 Blockscout 提交接口。
