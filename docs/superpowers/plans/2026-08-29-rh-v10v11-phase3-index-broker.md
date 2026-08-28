# 第 3 期：NutboxRouter + Index Broker NFT（RH 适配）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans。必须在第 1、2 期门禁通过后开始。官方 Token AMM 依赖第 1 期 `listingHook` / `LISTING_LP_FEE=3000` / `v4PoolId`。

**Goal:** 在 RH 上提供与 main 同逻辑的 Index Broker NFT（铸造、AMM、指数回购、双挖、Renderer），价格源和官方上市池走 Uniswap V2/V3/V4，而不是 Pancake Infinity。

**Architecture:** 从 `main` 拷贝 `src/router/` 与 `src/nutbox/dapps/index-broker-nft/`，然后改 AMM 的官方池激活与 RH 部署配置。`INutboxRouter.UniswapV4Source` 已存在，优先用它。RH 部署时 Pancake V4 CL allowlist 为空。Renderer / NFT 主体逻辑不改链假设。

**Tech Stack:** 与总计划相同。RH 的 `lib/infinity-core` 已存在，拷贝 main `NutboxRouter.sol` 可以编译；运行时不注册 Pancake manager。

## Global Constraints

总计划全部适用。额外：禁止 AMM `_activateOfficialToken` 调用 Pancake `poolIdToPoolKey`。禁止把 BSC `version11.json` 地址写进 RH 脚本。

---

## 文件

从 `main` 拷贝后修改：

- Create: `src/router/INutboxRouter.sol`
- Create: `src/router/NutboxRouter.sol`
- Create: `src/router/NutboxSpotPrice.sol`
- Create: `src/router/README.md`（改成 RH 用法，删 BSC 地址）
- Create: `src/nutbox/dapps/index-broker-nft/` 整目录（含 stonk renderer）
- Create: `script/config/RHNutboxRouterConfig.sol`
- Create: `script/DeployRHNutboxRouter.s.sol`
- Create: `script/DeployRHIndexBrokerNFT.s.sol`
- Modify: `script/DeployRH.s.sol`（可选：不把 NFT 塞进一次 deploy，保持独立脚本，统一发布时按总计划顺序手动跑）
- Create: `test/unit/NutboxRouter.t.sol`（从 main 迁，去掉 Pancake 用例或 skip）
- Create: `test/unit/IndexBrokerNFT.t.sol` 等（从 main 迁，官方 Token 夹具改用 RH Pump/Token）
- Create: `test/unit/StonkBrokerRenderer.t.sol`

拷贝命令示例（在 `rh-v10v11` 上）：

```bash
git checkout main -- src/router src/nutbox/dapps/index-broker-nft
```

不要 `git checkout main -- src/pump src/hook src/helper`。

---

### Task 1: 迁 NutboxRouter，加上 RH 配置

**Files:**
- Create: 上述 `src/router/*`
- Create: `script/config/RHNutboxRouterConfig.sol`
- Test: `test/unit/NutboxRouter.t.sol`（裁剪）

**Interfaces:** 保持 `INutboxRouter` 不变，包括 `UNISWAP_V4` 与 `PANCAKE_V4_CL` 枚举。RH 构造：

- `wrappedNative` = RH WETH（mainnet `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`）
- Uniswap V3 router / factory：写入 `RHNutboxRouterConfig`；若 RH 主网地址待填，用 `address(0)` 会让 main 版构造函数 revert——**main 构造强制 `pancakeV3Router_.code.length > 0`，RH 必须二选一，且要在本任务开头定死：**
  - **方案 A（推荐）**：把 RH 的 Uniswap V3 SwapRouter02 当作 `pancakeV3Router_` 传入。先验证 ABI 兼容：`INutboxPancakeV3Router` 用到 `factory()`、`WETH9()`、`exactInputSingle(ExactInputSingleParams)`。RH 的 SwapRouter02 的 `ExactInputSingleParams` 有 `deadline` 字段（与 main 假设的 SwapRouter02 无 deadline 不同）。若 ABI 不兼容，改 NutboxRouter 内部 V3 调用编码以适配 RH SwapRouter02，或走方案 B。
  - **方案 B**：改 NutboxRouter 构造允许 `pancakeV3Router_ == address(0)`，此时禁用 V3 指数回购路径（`swapExactInput` 遇到 V3 source revert `UnsupportedSwapSource`），NFT AMM 的社区币定价仍可用 Uniswap V4 官方池。RH 若暂时只有 V2/V4，选 B 更干净。
- `uniswapV4Managers_` = `[RH PoolManager]`
- `pancakeV4CLManagers_` = `[]`

- [ ] **Step 1: 拷贝 router 文件并 `forge build`**
- [ ] **Step 2: 改构造 / allowlist，使空 Pancake 列表可部署**
- [ ] **Step 3: 本地测试 quote/swap 仅覆盖 V2 + Uniswap V4（可用第 1 期 listed token）**

```bash
forge test --match-contract NutboxRouterTest -vv
```

Expected: PASS。Pancake Infinity 测试删除或 `vm.skip`。

---

### Task 2: 迁 Index Broker 主体，改官方 Token 激活

**Files:**
- Create: `src/nutbox/dapps/index-broker-nft/*`
- Modify: `IndexBrokerNFTAMM.sol` 的 `IIndexBrokerTagAIToken` 与 `_activateOfficialToken`

第 1 期 Token 已提供：

```solidity
function listingHook() external view returns (address);
function LISTING_LP_FEE() external view returns (uint24);
function TICK_SPACING() external view returns (int24);
function poolManager() / getPoolManager  — RH Token 字段是 `IPoolManager public poolManager`
function v4PoolId() external view returns (PoolId);
function listed() external view returns (bool);
```

把 AMM 里 Pancake 专用接口换成：

```solidity
interface IIndexBrokerTagAIToken {
    function listed() external view returns (bool);
    function poolManager() external view returns (address);
    function v4PoolId() external view returns (bytes32);
    function listingHook() external view returns (address);
    function LISTING_LP_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
}
```

`_activateOfficialToken`：

```solidity
IIndexBrokerTagAIToken token = IIndexBrokerTagAIToken(communityToken);
if (!token.listed()) revert /* 保持原错误 */;
address manager = token.poolManager();
INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
    poolManager: manager,
    currency0: address(0),
    currency1: communityToken,
    fee: token.LISTING_LP_FEE(),
    tickSpacing: token.TICK_SPACING(),
    hooks: token.listingHook()
});
// 用与 Token 上市相同的 PoolKey.toId() 校验 == token.v4PoolId()
_activate(INutboxRouter.SourceType.UNISWAP_V4, abi.encode(source), true);
```

> **排序校验（必须做）**：RH Token 上市池固定 `currency0 = ADDRESS_ZERO`（native）、`currency1 = token`。重建 `UniswapV4Source` 时 `currency0`/`currency1` 必须与上市时一致，否则 `PoolKey.toId()` 算出的 poolId ≠ `token.v4PoolId()`，激活校验 revert。在 Step 2 加一个断言：用同样字段本地算 `PoolKey.toId()` 与 `token.v4PoolId()` 相等后再 `_activate`。

Factory 的 `supportedPump` 指向**新** RH Pump。指数回购用的 V3 router 改读 `RHNutboxRouterConfig` 的 Uniswap V3；若地址未定，Factory 允许 `indexV3Router = address(0)` 时禁用「用 native 买指数」路径，NFT AMM 的社区币定价仍可用 Uniswap V4 官方池。

main 上 `test/unit/IndexBrokerNFT.t.sol` 2000+ 行、夹具强绑 BSC Pump/Token/Pancake。**拆成以下子任务，每个独立 review，不要单任务堆完。**

- [ ] **Step 1: 拷贝 NFT 目录并编译**

```bash
git checkout main -- src/nutbox/dapps/index-broker-nft
forge build
```

修复 `clPoolManager` / Pancake import 导致的 RH 编译错误（删 Pancake 专用 import，改 Uniswap v4）。本步只求编译通过，不改行为。

- [ ] **Step 2: 改 `_activateOfficialToken` 与 `IIndexBrokerTagAIToken`**

按上面的接口与排序校验实现。加断言：本地 `PoolKey.toId()` == `token.v4PoolId()` 后再 `_activate`。

- [ ] **Step 3: 子任务 A — 铸造夹具适配**

从 main 迁 `IndexBrokerNFT.t.sol` 的铸造相关用例，listed token 创建改成 RH `V4PumpTestBase._createAndListToken`。只跑铸造路径（mint / reroll / commit-reveal）。

```bash
forge test --match-contract IndexBrokerNFTMintTest -vv
```

- [ ] **Step 4: 子任务 B — AMM 买卖与官方池激活**

迁 AMM 用例，官方池激活用 Step 2 的 Uniswap v4 路径。非官方池定价用 RH V2。

```bash
forge test --match-contract IndexBrokerNFTAMMTest -vv
```

- [ ] **Step 5: 子任务 C — 指数回购与双挖**

迁回购 / 双挖用例。依赖 V3 指数回购的用例在 RH 无 V3 地址时 `vm.skip`，并在发布清单标明。

```bash
forge test --match-contract IndexBrokerBuybackTest -vv
```

- [ ] **Step 6: 子任务 D — 持币手续费回收**

迁 fee 回收用例。

```bash
forge test --match-contract IndexBrokerFeeTest -vv
```

Expected: 各子任务 PASS。依赖 Pancake V3 指数回购的用例 skip。

---

### Task 3: Renderer 与 Niulai

**Files:** 已在目录内的 `StonkBrokerRenderer` 与子 renderer、`NiulaiIPFSRenderer.sol`

RH 无 BSC 预览脚本依赖。拷贝后跑：

```bash
forge test --match-contract StonkBrokerRendererTest --match-contract NiulaiIPFSRendererTest -vv
```

若 main 测试强依赖 BSC fork，改成纯单元测试（metadata / URI）。不要为 Renderer 去 fork BSC。

---

### Task 4: RH 部署脚本（不广播）

**Files:**
- Create: `script/DeployRHNutboxRouter.s.sol`
- Create: `script/DeployRHIndexBrokerNFT.s.sol`
- Modify: `script/DeployRH.s.sol` 只增加注释：完整发布顺序见总计划；本脚本仍只部署 Nutbox+Pump+Hook+Import。

脚本必须：

- 读 `deployments/<chainid>/addresses.json` 里的新 Pump / PoolManager / WETH
- 挖 Hook 的方式继续用 `src/utils/HookMiner.sol` 与现 `HOOK_FLAGS`
- 写回同一 JSON 的新字段：`NutboxRouter`、`IndexBrokerNFTFactory`、templates、renderer
- `broadcast` 不是本任务的一部分；`forge script ... --chain-id 46630` dry-run 能跑通即可

```bash
forge script script/DeployRHNutboxRouter.s.sol --fork-url $RH_RPC_URL --chain-id 4663 -vv
forge script script/DeployRHIndexBrokerNFT.s.sol --fork-url $RH_RPC_URL --chain-id 4663 -vv
```

Expected: 模拟成功。不要 `--broadcast`。

---

### Task 5: 全量门禁（发布前）

```bash
forge test --match-contract PumpTest --match-contract TokenTest --match-contract TagAISwapHookTest --match-contract TokenCollectFeesTest --match-contract ImportHelperTest --match-contract TagAISwapWrapperSellsmanTest --match-contract TagAISwapWrapperNutboxFeeTest --match-contract IndexBrokerNFTTest -vv
```

有 RPC 时：

```bash
FOUNDRY_PROFILE=rh_fork forge test --match-path test/fork -vv
```

Expected: 全绿。之后才允许按总计划「统一发布清单」广播。Factory 授权与 Owner 交接仍留到链上发布步骤，不在开发计划里提前打开。
