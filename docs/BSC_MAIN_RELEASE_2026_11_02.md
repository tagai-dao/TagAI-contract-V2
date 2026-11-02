# BSC main 源码发布 — 2026-11-02

本次将 `bsc-version18` 的 15 个提交以非快进合并纳入 `main`，包括 V18、AgentSwapWrapper v1、ImportHelper V3，以及对应测试、部署、验证和多签激活记录。没有部署新合约或广播链上写交易。

## Git 版本

| 项目 | 记录 |
| --- | --- |
| 合并前 main | `b1239a9`，V17 主分支发布 |
| 合并来源 | `bsc-version18` / `c03c0b0`，完整 SHA 见发布清单 |
| 合并方式 | `--no-ff`，保留完整版本提交历史 |
| 本次发布标签 | `version18-main-20261102`，annotated tag 指向包含本记录的合并提交 |
| 原 `version18` 标签 | 保持指向原部署记录 `7a8eb52`，不移动、不重建 |

[机器可读清单](../deployments/56/main-release-2026-11-02.json) 包含完整父提交、纳入提交列表、历史标签对象、真实部署源码引用与测试结果。合并提交是源码发布归档点，不替代各组件部署时的固定源码提交。

## 合约及真实部署来源

| 组件 | 地址 | 部署源码 |
| --- | --- | --- |
| Pump V18 | `0x3B174dB24A44d7172C1f4Fb8Ab387F3931681C24` | `6eae99e` |
| Token V18 implementation | `0x02DC3D9bd600C147F347e584167b58953353BDbF` | `6eae99e` |
| TagAISwapHook V18 | `0x4dA421377b1dbf739f409919a07EAa7284BE0Cc1` | `6eae99e` |
| TagAIBuybackRouter V18 | `0x3468210f9d4522d20d120F122fcCd56c0C5e5074` | `6eae99e` |
| AgentSwapWrapper v1 | `0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577` | `9c0a55b` |
| ImportHelper V3 | `0xDcCc7428338Db3a7480bEcAa9dAc2965425E0EDF` | `170d28e`（功能提交 `452baa0`） |

V18 内盘买卖自动创建缺失的交易者 IPShare；Agent Wrapper 提供外盘 Binance Handle 准入和自动创建 IPShare；V3 创建同一个社区并原子登记到普通/Agent 两个 Wrapper，原钱包通过 V3 管理 Agent 绑定及逐币 Nutbox 费率。登记默认不启用 Agent Nutbox 费。普通 Wrapper `0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F`、NutboxRouter `0x72dc4F38A7E4159e97d826a6ab594748C6b68f17` 等现有基础设施复用。

旧 Token 固定使用原模板。V2 源码为继承 V3 增加扩展点，已部署 V2 字节码不变；其回执继续由 API 历史白名单识别。RH 合约和独立版本不在本次发布范围内。

## 权限状态复核

北京时间 2026-11-02 16:05:33，在 BSC 固定区块 **131205917**，通过 Multicall3 `aggregate3` 同一快照读取 19 个必需子调用；目标、calldata、顺序、区块哈希及完整结果见 [状态证据](../deployments/56/main-release-2026-11-02-state.json)。没有独立 RPC 批量读取降级。

- Pump V18 owner 为 Safe `0x871fb7006C5964B21695Ba20006021777A26146C`，pendingOwner 为零；NutboxRouter operator 与 BasketRegistry creator forwarder 都是 true，确认激活完成。
- Agent Wrapper、普通 Wrapper、V3 的 owner 均为同一 Safe。
- Agent operator、普通 Wrapper registrar 均为 V3；V3 managementOperator 为原钱包 `0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611`，两个 Wrapper 目标地址正确。
- V3 的双授权由用户 Safe 交易 `0x9ed6b5022bcb1374eec47fcd21455659bce02e8080f0da9b83b4dd9e5fc3b69b`（区块 `131204085`）完成；本次仅只读复核。

更新了 V18 最新状态记录，保留 [2026-10-28 未激活的历史快照](../deployments/56/version18-activation-status-2026-10-28.json)。本次没有回溯 V18 原激活交易哈希，不把部署日的 fork 模拟当作主网执行证据。原 Safe 文件仅供历史核对，不要重复提交。

## 合并验证

- 合并无冲突，合并结果中的 8 个核心源码指纹与各自正式部署记录一致：Pump、Token、TagAISwapHook、TagAIBuybackRouter、AgentSwapWrapper、ImportedTokenSwapWrapper、ImportHelperV2、ImportHelperV3。
- 全量离线非 fork 回归：49 个套件，**930 通过、0 失败、2 个既有跳过**。
- 外部 Multicall 回归：**19 通过、0 失败**，覆盖固定区块、目标、子调用集合、缺失数据和失败时拒绝降级。
- [测试日志](../deployments/56/main-release-2026-11-02-tests)。本次不重复运行既有 fork 测试；各组件部署时的真实合约 fork 证据保留在原版本记录。

UI `main` 提交 `8b909bfc`、API `bsc` 提交 `6a12451` 已选择 V3，BSC 创建配置为 V18/V14；生产应用发布独立于此次 Git 合并。若环境有 `VITE_BSC_IMPORT_HELPER` / `BSC_IMPORT_HELPER` 覆盖项，需要使用 V3 地址。本次不确认生产环境已重新部署，不做数据库迁移或历史绑定批量迁移。
