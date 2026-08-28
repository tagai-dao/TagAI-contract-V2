# 第 1 期：RH 发行栈（Pump / Token / Hook）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. 规格见 `docs/superpowers/specs/2026-08-29-rh-v10v11-design.md`。行为参考 `main` 的 `src/pump/Pump.sol`、`src/pump/Token.sol`、`src/hook/TagAISwapHook.sol`，但 DEX 适配必须留在当前 `rh` 的 Uniswap v4 代码上。

**Goal:** 新 Pump 发出的 RH Token 具备 V11 的 Community 交接、anti-snipe 边界、0.3% LP Fee、`collectFees`、Hook 硬编码费率与余额制注入。

**Architecture:** 只改 RH 已有三个合约和接口。`unlockCallback` 增加 COLLECT 操作码。Hook 保留 Uniswap v4 回调签名，替换费率与 `remaining` 逻辑。

**Tech Stack:** 与总计划相同。

## Global Constraints

总计划 Global Constraints 全部适用。额外：本期内不要改 ImportHelper、Wrapper、不要拷贝 `src/nutbox/dapps/index-broker-nft/`。

## 关键耦合（顺序不可错）

Pump 删除 `armAntiSnipeBypass()` 调用，依赖 Token 已有 `_isPumpPremine()`。因此 **Task 2（Token anti-snipe）必须先于 Task 3（Pump 交接）**。否则两任务之间预购会落到 anti-snipe 高费率分支，Pump 测试在 Task 3 门禁就挂。

---

## 文件

- Modify: `src/interfaces/ICommunity.sol`
- Modify: `src/interfaces/IToken.sol`
- Modify: `src/pump/Token.sol`
- Modify: `src/pump/Pump.sol`
- Modify: `src/hook/TagAISwapHook.sol`
- Modify: `test/helpers/RHV4TestBase.sol`（`_buildPoolKey` 的 `fee` 改 3000）
- Modify: `test/security/HookSecurity.t.sol`、`test/invariant/HookInvariant.t.sol`（硬编码 `fee: 0`）
- Modify: `test/fork/RHImportWrapper.t.sol`（V4 池 `V4_FEE` 若用于官方池则对齐 3000）
- Modify: `test/unit/Pump.t.sol`、`test/unit/Token.t.sol`、`test/unit/TagAISwapHook.t.sol`、`test/unit/RHV4ListingLocal.t.sol`
- Modify: `test/property/HookProperty.t.sol`、`test/property/FeeProperty.t.sol`、`test/invariant/HookInvariant.t.sol`、`test/integration/FullLifecycle.t.sol`（`remaining` → 余额制断言）
- Modify: `test/fork/RHForkNutboxInject.t.sol`、`test/fork/RHForkTest.t.sol`、`test/fork/RHForkWhaleRoundtrip.t.sol`、`test/fork/RHForkBase.t.sol`（`tokenInfo` 解构 + `_capInjectAmount` helper）
- Create: `test/unit/TokenCollectFees.t.sol`

行为源码（只读，不要 checkout 覆盖 RH 文件）：

```bash
git show main:src/pump/Pump.sol
git show main:src/pump/Token.sol
git show main:src/hook/TagAISwapHook.sol
```

---

### Task 1: ICommunity 暴露 rewardCalculator

**Files:**
- Modify: `src/interfaces/ICommunity.sol`
- Test: 现有测试编译即可；Hook 任务会真正用到

**Interfaces:**
- Produces: `function rewardCalculator() external view returns (address);`
- 实现已在 `src/nutbox/Community.sol` 的 `address public rewardCalculator`

- [ ] **Step 1: 在 `ICommunity` 顶部、`poolActived` 之前增加**

```solidity
function rewardCalculator() external view returns (address);
```

- [ ] **Step 2: 编译**

```bash
forge build
```

Expected: PASS。`src/nutbox/interfaces/ICommunity.sol` 是 re-export，会跟着变。

- [ ] **Step 3: 提交（用户若要求按任务提交；否则和第 1 期其它任务一起提交）**

---

### Task 2: Token anti-snipe 与禁止窗口内上市（先于 Pump 任务）

**Files:**
- Modify: `src/pump/Token.sol`
- Modify: `src/interfaces/IToken.sol`
- Test: `test/unit/Token.t.sol`

**Interfaces:**
- Produces: `_isPumpPremine()`、`_inAntiSnipeWindow()`、error `ListingDisabledDuringAntiSnipe`
- 删除 `armAntiSnipeBypass` / `antiSnipeBypassArmed`（Pump 在 Task 3 才删调用，本任务可先保留函数空壳 `revert`，避免编译断裂；Task 3 删 Pump 调用后即可彻底删函数）

> 注意：RH Token 现有 `_getFeeRecipient` 在窗口内已返回 `ipshareSubject`（line 386），与 V11 一致，**不要重写**。本任务只改费率判定与上市禁用。

- [ ] **Step 1: 写失败测试**

```solidity
function test_publicFirstBuy_paysAntiSnipeFee() public onlyReady {
    vm.prank(creator, creator);
    address tokenAddr = pump.createToken{value: 0.02 ether}("SNIPE", bytes32("snipe"));
    Token t = Token(payable(tokenAddr));
    (uint256 tip, uint256 sellsman) = t.getBuyFeeRatios();
    uint256[2] memory ratio = pump.getFeeRatio();
    assertEq(tip, ratio[0]);
    assertGt(sellsman, ratio[1]);
}

function test_pumpPremineUsesNormalFee() public onlyReady {
    // Pump 捆绑预购走普通 feeRatio，不走高卖费
    vm.prank(creator, creator);
    address tokenAddr = pump.createToken{value: 0.02 ether}("PREMINE", bytes32("premine"));
    // 预购到账量应与按 feeRatio 计算的净买入一致（用 getBuyAmountByValue 反推校验）
}

function test_listingDisabledDuringAntiSnipeWindow() public onlyReady {
    vm.prank(creator, creator);
    address tokenAddr = pump.createToken{value: 0.02 ether}("NOLIST", bytes32("nolist"));
    Token t = Token(payable(tokenAddr));
    vm.deal(buyer, 10_000 ether);
    vm.prank(buyer, buyer);
    vm.expectRevert(Token.ListingDisabledDuringAntiSnipe.selector);
    t.buyToken{value: 9_000 ether}(0, address(0), 0);
}
```

`buyToken` 在窗口内把曲线买满应 revert，不是上市。资金量按 RH 曲线估算；若 9000 ETH 不够/过多，用 `getBuyAmountByValue` 算到刚好超过剩余 bonding 供应。

- [ ] **Step 2: 跑测试确认失败**

```bash
forge test --match-test test_publicFirstBuy_paysAntiSnipeFee --match-test test_listingDisabledDuringAntiSnipeWindow -vv
```

- [ ] **Step 3: 实现**

参考 main Token：

```solidity
function _isPumpPremine() private view returns (bool) {
    return msg.sender == manager && nutboxCommunity == address(0) && bondingCurveSupply == 0;
}

function _inAntiSnipeWindow() private view returns (bool) {
    return block.timestamp - createdAt < ANTI_SNIPE_WINDOW;
}
```

`_getBuyFeeRatios` / `_getBuyFeeRatiosView` 改为接收 `bool pumpPremine` 参数（参考 main `_getBuyFeeRatiosView(bool pumpPremine)`）：premine 或窗口外用 `feeRatio`；窗口内非 premine 用动态 sellsman 费。删除对 `antiSnipeBypassArmed` 的依赖。`_buyTokenDirect` 与公开 `buyToken` 调用处传 `_isPumpPremine()`。

`_buyTokenFillToCap` 和 `_makeLiquidityPool` 开头：

```solidity
if (_inAntiSnipeWindow()) revert ListingDisabledDuringAntiSnipe();
```

`_antiSnipeInject` **必须保留 main 的 community 未绑定回退**（premine 时 `nutboxCommunity == address(0)`，不能读 `ICommunity(address(0))`）：

```solidity
function _antiSnipeInject(uint256 sellsmanEth) private {
    if (nutboxCommunity == address(0)) {
        IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanEth}(ipshareSubject);
        return;
    }
    uint256 tokensPurchased = bondingCurve.getBuyAmountByValue(bondingCurveSupply, sellsmanEth);
    uint256 remaining = bondingCurveTotalAmount - bondingCurveSupply;
    if (tokensPurchased >= remaining) revert ListingDisabledDuringAntiSnipe();
    if (tokensPurchased == 0) {
        IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanEth}(ipshareSubject);
        return;
    }
    bondingCurveSupply += tokensPurchased;
    address calculator = ICommunity(nutboxCommunity).rewardCalculator();
    _approve(address(this), calculator, tokensPurchased);
    try IHourlyTickCalculator(calculator).inject(nutboxCommunity, tokensPurchased) {
        emit AntiSnipeInjected(address(this), nutboxCommunity, sellsmanEth, tokensPurchased);
    } catch {
        bondingCurveSupply -= tokensPurchased;
        _approve(address(this), calculator, 0);
        _tryValueCapture(ipshareSubject, sellsmanEth);
    }
}
```

`_getFeeRecipient` 不改（已满足）。

- [ ] **Step 4: 跑 Token 测试**

```bash
forge test --match-contract TokenTest -vv
```

Expected: PASS。`test_publicFirstBuy_paysAntiSnipeFee`、`test_listingDisabledDuringAntiSnipeWindow` 通过；`test_pumpPremineUsesNormalFee` 此刻可能仍走旧 `armAntiSnipeBypass` 路径，Task 3 删 Pump 调用后才会真正走 `_isPumpPremine`，所以本门禁只要求前两个通过。

---

### Task 3: Pump 设置 devFund，去掉 armAntiSnipeBypass 调用

**Files:**
- Modify: `src/pump/Pump.sol`
- Modify: `src/pump/Token.sol`（彻底删 `armAntiSnipeBypass` 函数与 `antiSnipeBypassArmed` 字段）
- Test: `test/unit/Pump.t.sol`

**Interfaces:**
- Consumes: `Community.adminSetDev(address)`（已有）、Token `_isPumpPremine()`（Task 2 已加）

- [ ] **Step 1: 写失败测试**

```solidity
function test_createToken_setsCommunityDevFundToCreator() public onlyReady {
    vm.prank(creator, creator);
    address tokenAddr = pump.createToken{value: 1 ether}("DEVFUND", bytes32("devfund"));
    address community = Token(payable(tokenAddr)).nutboxCommunity();
    assertEq(Community(community).devFund(), creator);
}
```

- [ ] **Step 2: 跑确认失败**（当前只 transferOwnership，devFund 仍是 Pump）

- [ ] **Step 3: 改 `createToken` 交接块**

```solidity
(bool setDevOk,) = community.call(abi.encodeWithSignature("adminSetDev(address)", creator));
require(setDevOk, "Set dev failed");
(bool txOk,) = community.call(abi.encodeWithSignature("transferOwnership(address)", creator));
require(txOk, "Transfer ownership failed");
```

删除预购前的 `Token(payable(instance)).armAntiSnipeBypass();`。在 `feeRatio` 字段加注释：只管内盘，上市后 Hook 不读。同步在 Token 里删 `armAntiSnipeBypass` 函数与 `antiSnipeBypassArmed` 字段。

- [ ] **Step 4: 跑 Pump + Token + 预购测试**

```bash
forge test --match-contract PumpTest --match-contract TokenTest --match-test test_pumpPremineUsesNormalFee -vv
```

Expected: PASS。

---

### Task 4: 上市 fee=3000、listingHook 快照、Uniswap v4 collectFees

**Files:**
- Modify: `src/pump/Token.sol`
- Modify: `src/interfaces/IToken.sol`
- Modify: `test/helpers/RHV4TestBase.sol`
- Modify: `test/security/HookSecurity.t.sol`、`test/invariant/HookInvariant.t.sol`
- Create: `test/unit/TokenCollectFees.t.sol`
- Modify: `test/unit/RHV4ListingLocal.t.sol`

**Interfaces:**
- Produces:
  - `address public listingHook`
  - `uint24 public constant LISTING_LP_FEE = 3000`
  - `uint256 public constant COLLECT_CALLER_REWARD_BPS = 50`
  - `function collectFees() external returns (uint256 ethAmount, uint256 tokenAmount)`
  - `event ListingFeesCollected(address indexed collector, uint256 ethAmount, uint256 tokenAmount, uint256 callerReward)`
  - transient 字段 `uint256 private _collectEthAmount; uint256 private _collectTokenAmount;`（callback 写入，`collectFees` 读后清零）
- 保持：`LISTING_ETH_BUDGET`、ticks、`LISTING_LIQUIDITY_DELTA`、`INITIAL_SQRT_PRICE_X96`、`unlockCallback` 入口

- [ ] **Step 1: 把测试基座与所有硬编码 `fee: 0` 改为 3000**

`test/helpers/RHV4TestBase.sol:234`、`test/security/HookSecurity.t.sol:77`、`test/invariant/HookInvariant.t.sol:54`。`test/fork/RHImportWrapper.t.sol` 的 `V4_FEE` 若用于官方上市池也对齐 3000；若是外部任意池则保留。一次性扫干净，否则 poolId 对不上。

- [ ] **Step 2: 写 collectFees 失败测试**（本地 listed token，swap 产生 LP fee 后领取）

`test/unit/TokenCollectFees.t.sol` 继承 `V4ListedTokenTestBase`：

1. 上市后 `token.listingHook() == address(hook)`。
2. `_buildPoolKey` 的 `fee == 3000`。
3. buyer 通过 `swapRouter` 买一次，再 `collectFees()`：
   - 调用者 ETH 增加约领取额的 0.5%
   - `feeRecipient`（Pump feeReceiver）收到其余 ETH LP Fee
   - `address(hook)` 的 token 余额增加
   - Token 自身 ETH/token 余额不因本次领取净增加
   - 再读 pool liquidity，与领取前相等

- [ ] **Step 3: 跑测试确认失败**

```bash
forge test --match-contract TokenCollectFeesTest -vv
```

Expected: FAIL（尚无 `collectFees` / fee 仍为 0）。

- [ ] **Step 4: 改 Token 上市与 callback**

常量（插在 TICK_SPACING 旁，不要改 tick 数值）：

```solidity
address public listingHook;
uint24 public constant LISTING_LP_FEE = 3000;
uint256 public constant COLLECT_CALLER_REWARD_BPS = 50;
uint8 private constant UNLOCK_OP_SEED = 0;
uint8 private constant UNLOCK_OP_COLLECT = 1;
```

`_makeLiquidityPool` 里 `PoolKey.fee` 改为 `LISTING_LP_FEE`；在 `initialize` 前：

```solidity
listingHook = hookAddr;
```

`unlock` 改为：

```solidity
poolManager.unlock(abi.encode(UNLOCK_OP_SEED, poolKey, tickLower, tickUpper, address(0)));
```

`unlockCallback`：

```solidity
function unlockCallback(bytes calldata data) external override returns (bytes memory) {
    require(msg.sender == address(poolManager), "Only PoolManager");
    (uint8 op, PoolKey memory poolKey, int24 tickLower, int24 tickUpper, address collector) =
        abi.decode(data, (uint8, PoolKey, int24, int24, address));
    if (op == UNLOCK_OP_SEED) {
        _modifyAndSettleLiquidity(poolKey, tickLower, tickUpper, int256(uint256(LISTING_LIQUIDITY_DELTA)));
    } else if (op == UNLOCK_OP_COLLECT) {
        _collectListingFees(poolKey, tickLower, tickUpper, collector);
    } else {
        revert("Invalid unlock op");
    }
    return "";
}
```

`_listingPoolKey()` 用 `listingHook`、`LISTING_LP_FEE`、`TICK_SPACING`、`poolManager` 重建，禁止再读 `Pump.getHookAddress()`。

`collectFees()`：

```solidity
function collectFees() external nonReentrant returns (uint256 ethAmount, uint256 tokenAmount) {
    if (!listed) revert TokenNotListed();
    poolManager.unlock(
        abi.encode(UNLOCK_OP_COLLECT, _listingPoolKey(), LISTING_TICK_LOWER, LISTING_TICK_UPPER, msg.sender)
    );
    ethAmount = _collectEthAmount;
    tokenAmount = _collectTokenAmount;
    _collectEthAmount = 0;
    _collectTokenAmount = 0;
    uint256 callerReward = (ethAmount * COLLECT_CALLER_REWARD_BPS) / divisor;
    emit ListingFeesCollected(msg.sender, ethAmount, tokenAmount, callerReward);
}
```

`_collectListingFees`：`modifyLiquidity` 的 `liquidityDelta = 0`。Uniswap v4 返回 `(callerDelta, feesAccrued)`——**用 `feesAccrued` 计费，不要把本金 delta 当手续费**。然后：

```solidity
if (ethFee > 0) {
    uint256 callerReward = (ethAmount * COLLECT_CALLER_REWARD_BPS) / divisor;
    if (callerReward != 0) {
        CurrencySettler.take(poolKey.currency0, poolManager, collector, callerReward, false);
    }
    CurrencySettler.take(
        poolKey.currency0, poolManager, IPump(manager).getFeeReceiver(), ethAmount - callerReward, false
    );
}
if (tokenFee > 0) {
    CurrencySettler.take(poolKey.currency1, poolManager, listingHook, tokenAmount, false);
}
```

`listed` 后 `receive()` 继续 `revert TokenListed()`。PoolManager 的 take 直达目标，Token 不收 ETH。

IToken 增加 `listingHook`、`collectFees`、`ListingFeesCollected`、`ListingDisabledDuringAntiSnipe`。

- [ ] **Step 5: 跑上市与领费测试**

```bash
forge test --match-contract TokenCollectFeesTest --match-contract RHV4ListingLocal --match-contract TokenTest -vv
```

Expected: PASS。`test_local_800mExternalSellDrainsPoolEth` 仍通过（fee=3000 会略减少卖出所得，若断言过严则改为容忍 LP fee，不要改 tick）。

---

### Task 5: Hook 硬编码费率 + 余额制注入

**Files:**
- Modify: `src/hook/TagAISwapHook.sol`
- Test: `test/unit/TagAISwapHook.t.sol`、`test/property/HookProperty.t.sol`、`test/invariant/HookInvariant.t.sol`、`test/integration/FullLifecycle.t.sol`、`test/fork/RHForkNutboxInject.t.sol`、`test/fork/RHForkTest.t.sol`、`test/fork/RHForkWhaleRoundtrip.t.sol`、`test/fork/RHForkBase.t.sol`

**Interfaces:**
- 删除对 `pump.getFeeRatio()` 的运行时读取
- `HookTokenInfo` 去掉 `remaining`，`tokenInfo` 解构从 3 元组变 2 元组 `(community, calculator)`——所有测试解构点要同步改
- `registerPool` 使用 `ICommunity(community).rewardCalculator()`
- `NutboxInjected` 最后一个参数改为注入后 Hook 余额 `uint256 balanceAfter`

> **关键：RH Hook 用 Uniswap v4 return-delta 抽费，不是 main 的 take 模型。** 当前 `beforeSwap` 返回 `toBeforeSwapDelta(fee, 0)`、`afterSwap` 返回 `afterSwapFee`，且内部 `poolManager.take(currency0,...)`。V11 要新增「买入侧 0.3% Token 输出留给 Hook」，这需要：
> - 买入（`zeroForOne=true`，token 增加）：在 `afterSwap` 里对 currency1（token）侧 `poolManager.take(key.currency1, address(this), tokenFee)`，并把对应 `afterSwapFee` 返回值反映 token 侧扣减；或用 `beforeSwap` 在 currency1 侧返回 delta。**优先用 afterSwap take token**，因为它能拿到实际成交 delta，比 beforeSwap 估算准。
> - BNB 侧：买入与卖出都抽 0.3% 给 IPShare；卖出额外 0.3% 给平台。买入 BNB 侧 0.3% 走 `valueCapture`，卖出 BNB 侧 0.3% IPShare + 0.3% 平台，按同一笔 ETH 毛额算，不先扣一项再算另一项。
>
> 不要照搬 main 的 `_collectBeforeSwapBnbFee` / `_takeAndDistributeBnbFees` 函数名——那些是 Pancake take 模型。留在当前文件的 `beforeSwap` / `afterSwap` Uniswap v4 签名上，只替换内部费率常量与分发目标。

常量：

```solidity
uint256 private constant IPSHARE_FEE_BPS = 30;
uint256 private constant DIRECTIONAL_FEE_BPS = 30;
```

`_settlePeriod` 改余额制：

```solidity
uint256 balance = IERC20(token).balanceOf(address(this));
if (injectAmount > balance) injectAmount = balance;
if (injectAmount < MIN_INJECT_OUTPUT) { /* skip */ return; }
try IHourlyTickCalculator(info.calculator).inject(info.community, injectAmount) {
    emit NutboxInjected(token, info.community, injectAmount, IERC20(token).balanceOf(address(this)));
} catch (bytes memory reason) {
    IERC20(token).approve(info.calculator, 0);
    emit NutboxInjectionFailed(token, info.community, injectAmount, reason);
}
```

`_tryInject` 的 `remaining == 0` 守卫改为 `balance == 0` 守卫。

- [ ] **Step 1: 更新 / 新增测试**
  - 管理员改 `pump.adminChangeFeeRatio([100,100])` 后，已注册池 Hook 仍按 30/30 抽。
  - 给 Hook 多转 Token 后，settle 注入可以超过 150M 计数（旧 `remaining` 逻辑会卡住）。
  - 买入 Token 侧 0.3% 留在 Hook（Hook token 余额增加）。
  - 卖出平台费按 ETH 毛额 0.3%，不是扣完 IPShare 再算。
  - 所有 `hook.tokenInfo(token)` 解构从 `(community, uint96 remaining, calculator)` 改为 `(community, calculator)`；注入断言改为「Hook token 余额减少 == 注入量」。

- [ ] **Step 2: 实现后跑**

```bash
forge test --match-contract TagAISwapHookTest --match-contract HookPropertyTest --match-contract HookInvariantTest --match-contract HookSecurity --match-contract FullLifecycle -vv
```

Expected: PASS。现有注入档位测试（10 分钟、420M cap、低于 MIN_INJECT 跳过）必须仍然成立。fork 注入测试在 Step 3 单独跑。

- [ ] **Step 3: fork 注入回归**

```bash
FOUNDRY_PROFILE=rh_fork forge test --match-path test/fork/RHForkNutboxInject.t.sol --match-path test/fork/RHForkTest.t.sol --match-path test/fork/RHForkWhaleRoundtrip.t.sol -vv
```

无 RPC 时标为发布前必跑。

---

### Task 6: 第 1 期回归门禁

- [ ] **Step 1: 跑门禁**

```bash
forge test \
  --match-contract PumpTest \
  --match-contract TokenTest \
  --match-contract TagAISwapHookTest \
  --match-contract TokenCollectFeesTest \
  --match-contract RHV4ListingLocal \
  --match-contract HookPropertyTest \
  --match-contract FeePropertyTest \
  --match-contract HookInvariantTest \
  --match-contract FullLifecycle \
  --match-contract HookSecurity \
  -vv
```

Expected: 全部 PASS。`test_local_800mExternalSellDrainsPoolEth` 仍通过（fee=3000 + Hook 0.3%×2 会略减卖出所得，若断言过严则改容忍，不要改 tick）。

- [ ] **Step 2: 确认未改导入与 Index Broker 文件**

```bash
git diff --stat -- src/helper src/nutbox/dapps/index-broker-nft src/router
```

Expected: 空，或仅第 1 期误碰——若有误碰则 revert 那些文件。

第 1 期到此结束。不要部署。进入第 2 期计划。
