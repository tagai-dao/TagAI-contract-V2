// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IPump.sol";
import "../interfaces/IBondingCurve.sol";
import "../interfaces/IHourlyTickCalculator.sol";
import "../interfaces/ICommunity.sol";

// PancakeSwap V4 (Infinity)
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

interface ITipTagSwapHook {
    function registerPool(PoolId poolId, address token) external;
}

error OnlyPump();
error NutboxAddressesAlreadySet();

contract Token is IToken, ERC20, ReentrancyGuard, ILockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    string private _name;
    string private _symbol;
    uint256 private constant divisor = 10000;

    /// @dev 15% supply for Nutbox community rewards vault (Token transfers to Hook at listing).
    uint256 public constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 private constant bondingCurveTotalAmount = 650000000 ether;
    uint256 private constant liquidityAmount = 200000000 ether;

    uint256 public bondingCurveSupply = 0;

    // Anti-snipe: within 15s after creation, sellsmanFee decays quadratically from 80% to Pump's feeRatio[1]
    uint256 public createdAt;
    uint256 private constant ANTI_SNIPE_WINDOW = 15;
    uint256 private constant ANTI_SNIPE_SELLSMAN_FEE_MAX = 8000; // 80%
    uint256 private constant ANTI_SNIPE_DENOM = 225; // 15^2, used for quadratic decay

    // state
    address private manager; // pump contract address
    address public ipshareSubject;
    IBondingCurve public bondingCurve;
    bool public listed = false;
    bool initialized = false;

    /// @dev Filled once by Pump after Nutbox community + SocialCuration pool exist.
    address public nutboxCommunity;
    address public nutboxSocialPool;

    // PCS V4 pool info
    ICLPoolManager public clPoolManager;
    IVault public vault;
    PoolId public v4PoolId;
    /// @notice Hook permanently bound to this token's listing pool.
    /// @dev Snapshotted at listing so later Pump hook upgrades cannot change this pool's identity or fee destination.
    address public listingHook;
    bytes32 public listingPoolParameters;
    // In V4, tickSpacing and fee are fully decoupled.
    // fee=3000 sets native LP fee to 0.3%; TipTagSwapHook collects additional swap fees on top.
    // tickSpacing=60 controls price-tick granularity only (independent of fee tier).
    uint24 public constant LISTING_LP_FEE = 3000;
    /// @dev 0.5% of collected BNB LP fees rewards the permissionless caller.
    uint256 public constant COLLECT_CALLER_REWARD_BPS = 50;
    int24 public constant TICK_SPACING = 60;
    // Listing LP: 200M token 全进池 + 配对 BNB（~19.174，来自内盘收入）；tickLower=MIN；
    // tickUpper 校准使 800M 外部卖压抽干池内 BNB。
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 229333670737072535143449936330532;
    uint256 private constant LISTING_ETH_BUDGET = 19174083034210496243; // ~19.174 BNB
    uint256 private constant LISTING_TOKEN_AMOUNT = 200000000 ether;
    int24 private constant LISTING_TICK_LOWER = -887220;
    int24 private constant LISTING_TICK_UPPER = 191940;
    // 离线标定（ListingParamsCalc.test_computeTokenFirstListingConstants）：200M token-first 单次 add
    uint128 private constant LISTING_LIQUIDITY_DELTA = 69094226120069552406389;

    /// @dev vault.lock callback op codes — seed listing LP vs collect fees only.
    uint8 private constant LOCK_OP_SEED = 0;
    uint8 private constant LOCK_OP_COLLECT = 1;

    /// @dev Populated by collect callback; read and cleared by collectFees().
    uint256 private _collectBnbAmount;
    uint256 private _collectTokenAmount;

    receive() external payable nonReentrant {
        if (listed) {
            // Post-listing: only Vault may send ETH (LP fee collect via take).
            if (msg.sender != address(vault)) revert TokenListed();
            return;
        }
        _buyTokenDirect();
    }

    function _buyTokenDirect() private {
        address sellsman = _checkBondingCurveState(address(0));
        (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) = _getBuyFeeRatiosView(_isPumpPremine());
        uint256 buyFunds = msg.value;
        uint256 tiptagFee = (buyFunds * tiptagFeePercent) / divisor;
        uint256 sellsmanFee = (buyFunds * sellsmanFeePercent) / divisor;
        if (sellsmanFee < 100000000) revert DustIssue();
        uint256 tokenReceived = bondingCurve.getBuyAmountByValue(bondingCurveSupply, buyFunds - tiptagFee - sellsmanFee);
        address tiptapFeeAddress = IPump(manager).getFeeReceiver();
        if (tokenReceived + bondingCurveSupply >= bondingCurveTotalAmount) {
            uint256 actualAmount = bondingCurveTotalAmount - bondingCurveSupply;
            _buyTokenFillToCap(actualAmount, tiptagFeePercent, sellsmanFeePercent, sellsman);
        } else {
            bondingCurveSupply += tokenReceived;
            this.transfer(msg.sender, tokenReceived);
            (bool success,) = tiptapFeeAddress.call{value: tiptagFee}("");
            if (!success) revert CostFeeFail();
            address feeRecipient = _getFeeRecipient(sellsman);
            _handleSellsmanFee(sellsmanFee, feeRecipient);
            emit Trade(msg.sender, feeRecipient, true, tokenReceived, buyFunds, tiptagFee, sellsmanFee);
        }
    }

    function getIPShare() external view returns (address) {
        return ipshareSubject;
    }

    /// @notice Transfer default sellsman / IPShare fee recipient to another registered IPShare subject.
    /// @dev Callable only by current `ipshareSubject`. Updates bonding-curve defaults and Hook fallback via `getIPShare()`.
    function transferIPShareOwner(address newIPShareSubject) external {
        if (msg.sender != ipshareSubject) revert OnlyIPShareOwner();
        if (newIPShareSubject == address(0)) revert ZeroIPShareSubject();
        if (newIPShareSubject == ipshareSubject) revert IPShareAlreadySet();
        if (!IIPShare(IPump(manager).getIPShare()).ipshareCreated(newIPShareSubject)) revert IPShareNotCreated();

        address previousSubject = ipshareSubject;
        ipshareSubject = newIPShareSubject;
        emit IPShareSubjectTransferred(previousSubject, newIPShareSubject);
    }

    function initialize(address manager_, address ipshareSubject_, string memory tick) public {
        if (initialized) {
            revert TokenInitialized();
        }
        initialized = true;
        createdAt = block.timestamp;
        manager = manager_;
        ipshareSubject = ipshareSubject_;
        bondingCurve = IBondingCurve(manager_);
        _name = tick;
        _symbol = tick;
        // All tokens minted to Token itself
        _mint(address(this), bondingCurveTotalAmount + liquidityAmount + NUTBOX_ALLOCATION);

        // Set PCS V4 references
        clPoolManager = ICLPoolManager(IPump(manager).getPoolManager());
        vault = IVault(IPump(manager).getVault());
    }

    /// @notice Records Nutbox `Community` and SocialCuration pool; callable once by Pump only.
    function setNutboxAddresses(address community, address pool) external {
        if (msg.sender != manager) revert OnlyPump();
        if (nutboxCommunity != address(0)) revert NutboxAddressesAlreadySet();
        require(community != address(0) && pool != address(0));
        nutboxCommunity = community;
        nutboxSocialPool = pool;
    }

    /********************************** bonding curve ********************************/
    function buyToken(uint256 expectAmount, address sellsman, uint16 slippage)
        public
        payable
        nonReentrant
        returns (uint256)
    {
        require(msg.sender != address(clPoolManager), "can't buy token from pool");
        sellsman = _checkBondingCurveState(sellsman);
        (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) = _getBuyFeeRatiosView(_isPumpPremine());
        uint256 buyFunds = msg.value;
        uint256 tiptagFee = (msg.value * tiptagFeePercent) / divisor;
        uint256 sellsmanFee = (msg.value * sellsmanFeePercent) / divisor;

        if (sellsmanFee < 100000000) {
            revert DustIssue();
        }

        uint256 tokenReceived = bondingCurve.getBuyAmountByValue(bondingCurveSupply, buyFunds - tiptagFee - sellsmanFee);

        address tiptapFeeAddress = IPump(manager).getFeeReceiver();

        if (tokenReceived + bondingCurveSupply >= bondingCurveTotalAmount) {
            uint256 actualAmount = bondingCurveTotalAmount - bondingCurveSupply;
            if (slippage > 0 && (actualAmount < (expectAmount * (divisor - slippage)) / divisor)) {
                revert OutOfSlippage();
            }
            return _buyTokenFillToCap(actualAmount, tiptagFeePercent, sellsmanFeePercent, sellsman);
        } else {
            // Normal buy: fees already computed at entry using dynamic ratios from _getBuyFeeRatiosView()
            if (slippage > 0 && (tokenReceived < (expectAmount * (divisor - slippage)) / divisor)) {
                revert OutOfSlippage();
            }

            // CEI: update state before external calls
            bondingCurveSupply += tokenReceived;
            this.transfer(msg.sender, tokenReceived);

            (bool success,) = tiptapFeeAddress.call{value: tiptagFee}("");
            if (!success) {
                revert CostFeeFail();
            }

            address feeRecipient = _getFeeRecipient(sellsman);
            _handleSellsmanFee(sellsmanFee, feeRecipient);
            emit Trade(msg.sender, feeRecipient, true, tokenReceived, msg.value, tiptagFee, sellsmanFee);
            return tokenReceived;
        }
    }

    function sellToken(uint256 amount, uint256 expectReceive, address sellsman, uint16 slippage) public nonReentrant {
        sellsman = _checkBondingCurveState(sellsman);

        uint256 sellAmount = amount;
        if (balanceOf(msg.sender) < sellAmount) {
            sellAmount = balanceOf(msg.sender);
        }

        if (sellAmount < 100000000) {
            revert DustIssue();
        }

        uint256 afterSupply = bondingCurveSupply - sellAmount;

        uint256 price = bondingCurve.getPrice(afterSupply, sellAmount);

        uint256[2] memory feeRatio = IPump(manager).getFeeRatio();
        address tiptagFeeAddress = IPump(manager).getFeeReceiver();

        uint256 tiptagFee = (price * feeRatio[0]) / divisor;
        uint256 sellsmanFee = (price * feeRatio[1]) / divisor;
        uint256 receivedEth = price - tiptagFee - sellsmanFee;

        if (expectReceive > 0 && slippage > 0 && (receivedEth < ((divisor - slippage) * expectReceive) / divisor)) {
            revert OutOfSlippage();
        }

        // CEI: update state before external calls
        transfer(address(this), sellAmount);
        bondingCurveSupply -= sellAmount;

        {
            (bool success1,) = tiptagFeeAddress.call{value: tiptagFee}("");
            (bool success2,) = msg.sender.call{value: receivedEth}("");
            if (!success1 || !success2) {
                revert RefundFail();
            }
        }

        address feeRecipient = _getFeeRecipient(sellsman);
        IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanFee}(feeRecipient);
        emit Trade(msg.sender, feeRecipient, false, sellAmount, price, tiptagFee, sellsmanFee);
    }

    /**
     * Get current buy fee ratios (basis points, e.g. 100 = 1%).
     * 1. A Pump premine before the Community is linked uses Pump's feeRatio as-is.
     * 2. Public buys within 15s use the anti-snipe fee, including the first buy.
     * 3. After 15s: uses Pump's configured feeRatio.
     */
    function getBuyFeeRatios() external view returns (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) {
        return _getBuyFeeRatiosView(false);
    }

    function _getBuyFeeRatiosView(bool pumpPremine)
        private
        view
        returns (uint256 tiptagFeePercent, uint256 sellsmanFeePercent)
    {
        uint256[2] memory feeRatio = IPump(manager).getFeeRatio();
        if (pumpPremine) {
            return (feeRatio[0], feeRatio[1]);
        }
        uint256 elapsed = block.timestamp - createdAt;
        if (elapsed >= ANTI_SNIPE_WINDOW) {
            return (feeRatio[0], feeRatio[1]);
        }
        uint256 remaining = ANTI_SNIPE_WINDOW - elapsed;
        sellsmanFeePercent =
            feeRatio[1] + ((ANTI_SNIPE_SELLSMAN_FEE_MAX - feeRatio[1]) * remaining * remaining) / ANTI_SNIPE_DENOM;
        return (feeRatio[0], sellsmanFeePercent);
    }

    /// @notice Handles sellsman fee: during anti-snipe window, injects into Calculator; otherwise sends to IPShare.
    function _handleSellsmanFee(uint256 sellsmanFee, address feeRecipient) private {
        if (_inAntiSnipeWindow()) {
            _antiSnipeInject(sellsmanFee);
        } else {
            IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanFee}(feeRecipient);
        }
    }

    /// @notice During anti-snipe window, use sellsman ETH to buy tokens on bonding curve and inject into Calculator.
    function _antiSnipeInject(uint256 sellsmanEth) private {
        // Pump premine runs before its Community exists. At that point there is
        // no canonical Community calculator, so route the fee to IPShare.
        if (nutboxCommunity == address(0)) {
            IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanEth}(ipshareSubject);
            return;
        }

        // Use sellsman ETH to buy tokens on the bonding curve
        uint256 tokensPurchased = bondingCurve.getBuyAmountByValue(bondingCurveSupply, sellsmanEth);
        uint256 remaining = bondingCurveTotalAmount - bondingCurveSupply;
        if (tokensPurchased >= remaining) {
            revert ListingDisabledDuringAntiSnipe();
        }
        if (tokensPurchased == 0) {
            IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanEth}(ipshareSubject);
            return;
        }
        bondingCurveSupply += tokensPurchased;

        // The Community's calculator is canonical for its entire lifetime.
        address calculator = ICommunity(nutboxCommunity).rewardCalculator();

        // Approve calculator to pull tokens (inject does transferFrom(msg.sender=Token, community, amount))
        _approve(address(this), calculator, tokensPurchased);

        try IHourlyTickCalculator(calculator).inject(nutboxCommunity, tokensPurchased) {
            emit AntiSnipeInjected(address(this), nutboxCommunity, sellsmanEth, tokensPurchased);
        } catch {
            // The failed external call rolls back its transferFrom, but not the
            // approval made above in this frame. Revoke it before falling back.
            _approve(address(this), calculator, 0);
            bondingCurveSupply -= tokensPurchased;
            IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanEth}(ipshareSubject);
        }
    }

    function _buyTokenFillToCap(
        uint256 actualAmount,
        uint256 tiptagFeePercent,
        uint256 sellsmanFeePercent,
        address sellsman
    ) private returns (uint256) {
        if (_inAntiSnipeWindow()) revert ListingDisabledDuringAntiSnipe();

        uint256 priceBeforeFee = bondingCurve.getPrice(bondingCurveSupply, actualAmount);
        uint256 usedEth = (priceBeforeFee * divisor) / (divisor - tiptagFeePercent - sellsmanFeePercent);
        if (usedEth > msg.value) revert InsufficientFund();
        if (usedEth < msg.value) {
            (bool ok,) = msg.sender.call{value: msg.value - usedEth}("");
            if (!ok) revert RefundFail();
        }
        uint256 tiptagFee = (usedEth * tiptagFeePercent) / divisor;
        uint256 sellsmanFee = (usedEth * sellsmanFeePercent) / divisor;
        address tiptapFeeAddress = IPump(manager).getFeeReceiver();
        // CEI: update state before external calls
        bondingCurveSupply += actualAmount;
        this.transfer(msg.sender, actualAmount);

        (bool success1,) = tiptapFeeAddress.call{value: tiptagFee}("");
        if (!success1) revert CostFeeFail();
        address feeRecipient = _getFeeRecipient(sellsman);
        _handleSellsmanFee(sellsmanFee, feeRecipient);
        emit Trade(msg.sender, feeRecipient, true, actualAmount, usedEth, tiptagFee, sellsmanFee);
        _makeLiquidityPool();
        return actualAmount;
    }

    function _checkBondingCurveState(address sellsman) private returns (address) {
        if (listed) {
            revert TokenListed();
        }
        if (sellsman == address(0)) {
            sellsman = ipshareSubject;
        } else if (!IIPShare(IPump(manager).getIPShare()).ipshareCreated(sellsman)) {
            revert IPShareNotCreated();
        }
        return sellsman;
    }

    /// @notice 动态交易期（15s 内）费用固定归部署者，防止 MEV 攻击者通过传入自己为 sellsman 回收费用
    function _getFeeRecipient(address sellsman) private view returns (address) {
        if (_inAntiSnipeWindow()) {
            return ipshareSubject;
        }
        return sellsman;
    }

    function _isPumpPremine() private view returns (bool) {
        return msg.sender == manager && nutboxCommunity == address(0) && bondingCurveSupply == 0;
    }

    function _inAntiSnipeWindow() private view returns (bool) {
        return block.timestamp - createdAt < ANTI_SNIPE_WINDOW;
    }

    /********************************** to dex (PancakeSwap V4 Infinity) ********************************/

    /// @notice Permissionless: collect listing LP fees, reward caller, and route BNB→platform, Token→Hook.
    function collectFees() external nonReentrant returns (uint256 bnbAmount, uint256 tokenAmount) {
        if (!listed) revert TokenNotListed();

        bytes memory callbackData =
            abi.encode(LOCK_OP_COLLECT, _listingPoolKey(), LISTING_TICK_LOWER, LISTING_TICK_UPPER, msg.sender);
        vault.lock(callbackData);

        bnbAmount = _collectBnbAmount;
        tokenAmount = _collectTokenAmount;
        _collectBnbAmount = 0;
        _collectTokenAmount = 0;

        uint256 callerReward = (bnbAmount * COLLECT_CALLER_REWARD_BPS) / divisor;
        emit ListingFeesCollected(msg.sender, bnbAmount, tokenAmount, callerReward);
    }

    function _makeLiquidityPool() private {
        if (_inAntiSnipeWindow()) revert ListingDisabledDuringAntiSnipe();
        require(address(this).balance >= LISTING_ETH_BUDGET, "Insufficient ETH for listing");
        require(balanceOf(address(this)) >= LISTING_TOKEN_AMOUNT + NUTBOX_ALLOCATION, "Insufficient token for listing");

        // Transfer NUTBOX_ALLOCATION to Hook before creating the pool
        address hookAddr = IPump(manager).getHookAddress();
        require(hookAddr != address(0), "Hook not set");
        _transfer(address(this), hookAddr, NUTBOX_ALLOCATION);

        uint16 hookBitmap = IHooks(hookAddr).getHooksRegistrationBitmap();
        listingHook = hookAddr;
        listingPoolParameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), TICK_SPACING);

        PoolKey memory poolKey = _listingPoolKey();

        // 2. Use fixed initial price to avoid runtime price drift and overflow edge-cases.
        uint160 sqrtPriceX96 = INITIAL_SQRT_PRICE_X96;

        // 3. Use precomputed bounded ticks to avoid per-list tick math.
        int24 tickLower = LISTING_TICK_LOWER;
        int24 tickUpper = LISTING_TICK_UPPER;

        // 4. Initialize the pool
        clPoolManager.initialize(poolKey, sqrtPriceX96);

        // 5. Register pool in Hook for fee collection
        PoolId poolId = poolKey.toId();
        v4PoolId = poolId;
        ITipTagSwapHook(hookAddr).registerPool(poolId, address(this));

        // 6. Add bounded-range liquidity via vault.lock() callback.
        bytes memory callbackData = abi.encode(LOCK_OP_SEED, poolKey, tickLower, tickUpper, address(0));
        vault.lock(callbackData);

        // 7. After LP is settled, send all remaining ETH to platform. Remaining token stays in this contract.
        address tiptagFeeAddress = IPump(manager).getFeeReceiver();
        uint256 remainEth = address(this).balance;
        if (remainEth > 0) {
            (bool success1,) = tiptagFeeAddress.call{value: remainEth}("");
            require(success1, "Transfer ETH failed");
        }

        listed = true;
        emit TokenListedToDex(address(this), PoolId.unwrap(poolId), sqrtPriceX96);
    }

    /// @notice ILockCallback — seed listing LP or collect accrued LP fees (liquidityDelta=0).
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "Only Vault");

        (uint8 op, PoolKey memory poolKey, int24 tickLower, int24 tickUpper, address collector) =
            abi.decode(data, (uint8, PoolKey, int24, int24, address));

        if (op == LOCK_OP_SEED) {
            _modifyAndSettleLiquidity(poolKey, tickLower, tickUpper, int256(uint256(LISTING_LIQUIDITY_DELTA)));
        } else if (op == LOCK_OP_COLLECT) {
            _collectListingFees(poolKey, tickLower, tickUpper, collector);
        } else {
            revert("Invalid lock op");
        }

        return "";
    }

    /// @dev Rebuild the immutable listing PoolKey from values snapshotted when this token listed.
    function _listingPoolKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(this)),
            hooks: IHooks(listingHook),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: LISTING_LP_FEE,
            parameters: listingPoolParameters
        });
    }

    /// @dev Collect listing LP fees via modifyLiquidity(0); route only this feeDelta batch.
    function _collectListingFees(PoolKey memory poolKey, int24 tickLower, int24 tickUpper, address collector) private {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)
        });

        (, BalanceDelta feeDelta) = clPoolManager.modifyLiquidity(poolKey, params, "");

        int128 ethFee = feeDelta.amount0();
        int128 tokenFee = feeDelta.amount1();

        uint256 bnbAmount;
        uint256 tokenAmount;

        if (ethFee > 0) {
            bnbAmount = uint256(uint128(ethFee));
            uint256 callerReward = (bnbAmount * COLLECT_CALLER_REWARD_BPS) / divisor;
            address feeReceiver = IPump(manager).getFeeReceiver();
            // Route directly from Vault so Token never holds collected BNB.
            if (callerReward != 0) vault.take(poolKey.currency0, collector, callerReward);
            vault.take(poolKey.currency0, feeReceiver, bnbAmount - callerReward);
        }

        if (tokenFee > 0) {
            tokenAmount = uint256(uint128(tokenFee));
            vault.take(poolKey.currency1, address(poolKey.hooks), tokenAmount);
        }

        _collectBnbAmount = bnbAmount;
        _collectTokenAmount = tokenAmount;
    }

    /// @dev Shared modifyLiquidity + vault settle/take for listing LP adds.
    function _modifyAndSettleLiquidity(PoolKey memory poolKey, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        private
    {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });

        (BalanceDelta callerDelta,) = clPoolManager.modifyLiquidity(poolKey, params, "");

        int128 ethOwed = callerDelta.amount0();
        int128 tokenOwed = callerDelta.amount1();

        if (ethOwed < 0) {
            uint256 ethToSettle = uint256(uint128(-ethOwed));
            require(ethToSettle <= LISTING_ETH_BUDGET, "ETH budget exceeded");
            vault.settle{value: ethToSettle}();
        }

        if (tokenOwed < 0) {
            uint256 tokenToSettle = uint256(uint128(-tokenOwed));
            require(tokenToSettle <= LISTING_TOKEN_AMOUNT, "Token budget exceeded");
            vault.sync(poolKey.currency1);
            _transfer(address(this), address(vault), tokenToSettle);
            vault.settle();
        }

        if (ethOwed > 0) {
            vault.take(poolKey.currency0, address(this), uint256(uint128(ethOwed)));
        }
        if (tokenOwed > 0) {
            vault.take(poolKey.currency1, address(this), uint256(uint128(tokenOwed)));
        }
    }

    /********************************** erc20 function ********************************/
    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    // only listed token can do erc20 transfer functions
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        // Before listing, prevent unauthorized token transfers to Vault
        if (!listed && to == address(vault) && from != address(this)) {
            revert TokenNotListed();
        }
        return super._beforeTokenTransfer(from, to, amount);
    }
}
