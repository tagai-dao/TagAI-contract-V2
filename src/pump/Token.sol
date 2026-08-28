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
import "../utils/CurrencySettler.sol";

// Uniswap v4
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface ITipTagSwapHook {
    function registerPool(PoolId poolId, address token) external;
}

error OnlyPump();
error NutboxAddressesAlreadySet();
error ListingDisabledDuringAntiSnipe();

contract Token is IToken, ERC20, ReentrancyGuard, IUnlockCallback {
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

    // Uniswap v4 pool info
    IPoolManager public poolManager;
    PoolId public v4PoolId;
    // fee=0：池子本身不收 swap fee，全部由 TipTagSwapHook 收取
    int24 public constant TICK_SPACING = 60;
    // RH listing LP: 双边 ~200M + ~4.8 ETH；tickLower=MIN；tickUpper 校准使池外 800M 卖压抽干池内 ETH。
    // 离线标定：ListingParamsCalc.test_solveRH_listingConstants
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 458583950375716805416895042066315;
    uint256 private constant LISTING_ETH_BUDGET = 48 ether / 10; // 4.8 ETH（实际配对 ~4.792）
    uint256 private constant LISTING_TOKEN_AMOUNT = 200000000 ether;
    int24 private constant LISTING_TICK_LOWER = -887220;
    int24 private constant LISTING_TICK_UPPER = 205740;
    uint128 private constant LISTING_LIQUIDITY_DELTA = 34553395272273650725680;

    receive() external payable nonReentrant {
        if (listed) revert TokenListed();
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
            _sendPlatformFee(tiptapFeeAddress, tiptagFee);
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

        poolManager = IPoolManager(IPump(manager_).getPoolManager());
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
    function buyToken(
        uint256 expectAmount,
        address sellsman,
        uint16 slippage
    ) public payable nonReentrant returns (uint256) {
        require(msg.sender != address(poolManager), "can't buy token from pool");
        sellsman = _checkBondingCurveState(sellsman);
        (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) = _getBuyFeeRatiosView(_isPumpPremine());
        uint256 buyFunds = msg.value;
        uint256 tiptagFee = (msg.value * tiptagFeePercent) / divisor;
        uint256 sellsmanFee = (msg.value * sellsmanFeePercent) / divisor;

        if (sellsmanFee < 100000000) {
            revert DustIssue();
        }

        uint256 tokenReceived = bondingCurve.getBuyAmountByValue(
            bondingCurveSupply,
            buyFunds - tiptagFee - sellsmanFee
        );

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

            _sendPlatformFee(tiptapFeeAddress, tiptagFee);

            address feeRecipient = _getFeeRecipient(sellsman);
            _handleSellsmanFee(sellsmanFee, feeRecipient);
            emit Trade(msg.sender, feeRecipient, true, tokenReceived, msg.value, tiptagFee, sellsmanFee);
            return tokenReceived;
        }
    }

    function sellToken(
        uint256 amount,
        uint256 expectReceive,
        address sellsman,
        uint16 slippage
    ) public nonReentrant {
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
            (bool success2, ) = msg.sender.call{value: receivedEth}("");
            if (!success2) {
                revert RefundFail();
            }
        }

        _sendPlatformFee(tiptagFeeAddress, tiptagFee);

        address feeRecipient = _getFeeRecipient(sellsman);
        _tryValueCapture(feeRecipient, sellsmanFee);
        emit Trade(msg.sender, feeRecipient, false, sellAmount, price, tiptagFee, sellsmanFee);
    }

    /**
     * Get current buy fee ratios (basis points, e.g. 100 = 1%).
     * 1. Pump 预购（Community 未绑定）用 Pump 的 feeRatio。
     * 2. 公开买入在 15s 窗口内用 anti-snipe 费率（含第一笔）。
     * 3. 15s 后用 Pump 配置的 feeRatio。
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
            feeRatio[1] +
            ((ANTI_SNIPE_SELLSMAN_FEE_MAX - feeRatio[1]) * remaining * remaining) /
            ANTI_SNIPE_DENOM;
        return (feeRatio[0], sellsmanFeePercent);
    }

    /// @dev Platform fee transfer must not block bonding-curve trades.
    function _sendPlatformFee(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        success; // recipient is feeReceiver; if it rejects, ETH stays in Token
    }

    /// @dev IPShare valueCapture must not block trades; on failure route to Pump.feeReceiver.
    function _tryValueCapture(address subject, uint256 amount) private {
        if (amount == 0) return;
        try IIPShare(IPump(manager).getIPShare()).valueCapture{value: amount}(subject) {} catch {
            _sendToFeeReceiver(amount);
        }
    }

    /// @dev Fallback recipient is always Pump.getFeeReceiver().
    function _sendToFeeReceiver(uint256 amount) private {
        if (amount == 0) return;
        address feeReceiver = IPump(manager).getFeeReceiver();
        (bool success,) = feeReceiver.call{value: amount}("");
        success;
    }

    /// @notice Handles sellsman fee: during anti-snipe window, injects into Calculator; otherwise sends to IPShare.
    function _handleSellsmanFee(uint256 sellsmanFee, address feeRecipient) private {
        if (_inAntiSnipeWindow()) {
            _antiSnipeInject(sellsmanFee);
        } else {
            _tryValueCapture(feeRecipient, sellsmanFee);
        }
    }

    /// @notice During anti-snipe window, use sellsman ETH to buy tokens on bonding curve and inject into Calculator.
    function _antiSnipeInject(uint256 sellsmanEth) private {
        // Pump 预购发生在 Community 绑定前，此时没有 canonical calculator，走 IPShare valueCapture。
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

        // Community 的 calculator 在其整个生命周期内是 canonical 的。
        address calculator = ICommunity(nutboxCommunity).rewardCalculator();

        _approve(address(this), calculator, tokensPurchased);

        try IHourlyTickCalculator(calculator).inject(nutboxCommunity, tokensPurchased) {
            emit AntiSnipeInjected(address(this), nutboxCommunity, sellsmanEth, tokensPurchased);
        } catch {
            // 失败外部调用会回滚其 transferFrom，但本帧的 approve 不会回滚，先撤销再回退。
            _approve(address(this), calculator, 0);
            bondingCurveSupply -= tokensPurchased;
            _tryValueCapture(ipshareSubject, sellsmanEth);
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
            (bool ok, ) = msg.sender.call{value: msg.value - usedEth}("");
            if (!ok) revert RefundFail();
        }
        uint256 tiptagFee = (usedEth * tiptagFeePercent) / divisor;
        uint256 sellsmanFee = (usedEth * sellsmanFeePercent) / divisor;
        address tiptapFeeAddress = IPump(manager).getFeeReceiver();
        // CEI: update state before external calls
        bondingCurveSupply += actualAmount;
        this.transfer(msg.sender, actualAmount);

        _sendPlatformFee(tiptapFeeAddress, tiptagFee);
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

    /// @dev Pump 捆绑预购：msg.sender 是 Pump，且 Community 尚未绑定、曲线尚未售出。
    function _isPumpPremine() private view returns (bool) {
        return msg.sender == manager && nutboxCommunity == address(0) && bondingCurveSupply == 0;
    }

    /// @dev 上市前的 15 秒 anti-snipe 窗口。
    function _inAntiSnipeWindow() private view returns (bool) {
        return block.timestamp - createdAt < ANTI_SNIPE_WINDOW;
    }

    /********************************** to dex (Uniswap v4) ********************************/
    function _makeLiquidityPool() private {
        if (_inAntiSnipeWindow()) revert ListingDisabledDuringAntiSnipe();
        require(address(this).balance >= LISTING_ETH_BUDGET, "Insufficient ETH for listing");
        require(balanceOf(address(this)) >= LISTING_TOKEN_AMOUNT + NUTBOX_ALLOCATION, "Insufficient token for listing");

        // Transfer NUTBOX_ALLOCATION to Hook before creating the pool
        address hookAddr = IPump(manager).getHookAddress();
        require(hookAddr != address(0), "Hook not set");
        _transfer(address(this), hookAddr, NUTBOX_ALLOCATION);

        // currency0 = native ETH, currency1 = this token (address sort order)
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(this)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        uint160 sqrtPriceX96 = INITIAL_SQRT_PRICE_X96;
        int24 tickLower = LISTING_TICK_LOWER;
        int24 tickUpper = LISTING_TICK_UPPER;

        poolManager.initialize(poolKey, sqrtPriceX96);

        PoolId poolId = poolKey.toId();
        v4PoolId = poolId;
        ITipTagSwapHook(hookAddr).registerPool(poolId, address(this));

        // Add bounded-range liquidity inside unlock callback
        poolManager.unlock(abi.encode(poolKey, tickLower, tickUpper));

        // After LP is settled, send all remaining ETH to platform. Remaining token stays in this contract.
        address tiptagFeeAddress = IPump(manager).getFeeReceiver();
        uint256 remainEth = address(this).balance;
        if (remainEth > 0) {
            (bool success1, ) = tiptagFeeAddress.call{value: remainEth}("");
            require(success1, "Transfer ETH failed");
        }

        listed = true;
        emit TokenListedToDex(address(this), PoolId.unwrap(poolId), sqrtPriceX96);
    }

    /// @notice IUnlockCallback — 双边 LP：~200M token + ~4.8 ETH 进池。
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        (PoolKey memory poolKey, int24 tickLower, int24 tickUpper) = abi.decode(data, (PoolKey, int24, int24));

        _modifyAndSettleLiquidity(poolKey, tickLower, tickUpper, int256(uint256(LISTING_LIQUIDITY_DELTA)));

        return "";
    }

    /// @dev modifyLiquidity + settle open deltas against PoolManager.
    function _modifyAndSettleLiquidity(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) private {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(poolKey, params, "");

        int128 ethOwed = callerDelta.amount0();
        int128 tokenOwed = callerDelta.amount1();

        if (ethOwed < 0) {
            uint256 ethToSettle = uint256(uint128(-ethOwed));
            require(ethToSettle <= LISTING_ETH_BUDGET, "ETH budget exceeded");
            CurrencySettler.settle(poolKey.currency0, poolManager, address(this), ethToSettle, false);
        }

        if (tokenOwed < 0) {
            uint256 tokenToSettle = uint256(uint128(-tokenOwed));
            require(tokenToSettle <= LISTING_TOKEN_AMOUNT, "Token budget exceeded");
            CurrencySettler.settle(poolKey.currency1, poolManager, address(this), tokenToSettle, false);
        }

        if (ethOwed > 0) {
            CurrencySettler.take(poolKey.currency0, poolManager, address(this), uint256(uint128(ethOwed)), false);
        }
        if (tokenOwed > 0) {
            CurrencySettler.take(poolKey.currency1, poolManager, address(this), uint256(uint128(tokenOwed)), false);
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
        // Before listing, prevent unauthorized token transfers to PoolManager
        if (!listed && to == address(poolManager) && from != address(this)) {
            revert TokenNotListed();
        }
        return super._beforeTokenTransfer(from, to, amount);
    }
}
