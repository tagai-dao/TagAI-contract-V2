// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IPump.sol";
import "../interfaces/IBondingCurve.sol";
import "../interfaces/IHourlyTickCalculator.sol";

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
    // In V4, tickSpacing and fee are fully decoupled.
    // fee=0 means zero native pool fee; all fees are collected by TipTagSwapHook.
    // tickSpacing=60 controls price-tick granularity only (no 0.3% DEX fee implied).
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
    uint256 private constant MAX_LISTING_TOKEN_DUST = 1 ether;

    receive() external payable nonReentrant {
        if (listed) revert TokenListed();
        _buyTokenDirect();
    }

    function _buyTokenDirect() private {
        address sellsman = _checkBondingCurveState(address(0));
        (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) = _getBuyFeeRatiosView();
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
            (bool success, ) = tiptapFeeAddress.call{value: tiptagFee}("");
            if (!success) revert CostFeeFail();
            address feeRecipient = _getFeeRecipient(sellsman);
            _handleSellsmanFee(sellsmanFee, feeRecipient);
            emit Trade(msg.sender, feeRecipient, true, tokenReceived, buyFunds, tiptagFee, sellsmanFee);
        }
    }

    function getIPShare() external view returns (address) {
        return ipshareSubject;
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
    function buyToken(
        uint256 expectAmount,
        address sellsman,
        uint16 slippage
    ) public payable nonReentrant returns (uint256) {
        require(msg.sender != address(clPoolManager), "can't buy token from pool");
        sellsman = _checkBondingCurveState(sellsman);
        (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) = _getBuyFeeRatiosView();
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

            (bool success, ) = tiptapFeeAddress.call{value: tiptagFee}("");
            if (!success) {
                revert CostFeeFail();
            }

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
            (bool success1, ) = tiptagFeeAddress.call{value: tiptagFee}("");
            (bool success2, ) = msg.sender.call{value: receivedEth}("");
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
     * 1. First buy (bondingCurveSupply == 0): uses Pump's feeRatio as-is.
     * 2. Within 15s after creation: tiptag = feeRatio[0]; sellsman decays quadratically from 80% to feeRatio[1].
     * 3. After 15s: uses Pump's configured feeRatio.
     */
    function getBuyFeeRatios() external view returns (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) {
        return _getBuyFeeRatiosView();
    }

    function _getBuyFeeRatiosView() private view returns (uint256 tiptagFeePercent, uint256 sellsmanFeePercent) {
        uint256[2] memory feeRatio = IPump(manager).getFeeRatio();
        if (bondingCurveSupply == 0) {
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

    /// @notice Handles sellsman fee: during anti-snipe window, injects into Calculator; otherwise sends to IPShare.
    function _handleSellsmanFee(uint256 sellsmanFee, address feeRecipient) private {
        if (block.timestamp - createdAt < ANTI_SNIPE_WINDOW) {
            _antiSnipeInject(sellsmanFee);
        } else {
            IIPShare(IPump(manager).getIPShare()).valueCapture{value: sellsmanFee}(feeRecipient);
        }
    }

    /// @notice During anti-snipe window, use sellsman ETH to buy tokens on bonding curve and inject into Calculator.
    function _antiSnipeInject(uint256 sellsmanEth) private {
        // Use sellsman ETH to buy tokens on the bonding curve
        uint256 tokensPurchased = bondingCurve.getBuyAmountByValue(bondingCurveSupply, sellsmanEth);
        uint256 remaining = bondingCurveTotalAmount - bondingCurveSupply;
        if (tokensPurchased > remaining) {
            tokensPurchased = remaining;
        }
        bondingCurveSupply += tokensPurchased;

        // Get calculator address and inject
        address calculator = IPump(manager).getCalculator();

        // Approve calculator to pull tokens (inject does transferFrom(msg.sender=Token, community, amount))
        _approve(address(this), calculator, tokensPurchased);

        try IHourlyTickCalculator(calculator).inject(nutboxCommunity, tokensPurchased) {
            emit AntiSnipeInjected(address(this), nutboxCommunity, sellsmanEth, tokensPurchased);
        } catch {
            // Fallback: revert the supply change and send ETH to IPShare
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

        (bool success1, ) = tiptapFeeAddress.call{value: tiptagFee}("");
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
        if (block.timestamp - createdAt < ANTI_SNIPE_WINDOW) {
            return ipshareSubject;
        }
        return sellsman;
    }

    /********************************** to dex (PancakeSwap V4 Infinity) ********************************/
    function _makeLiquidityPool() private {
        require(address(this).balance >= LISTING_ETH_BUDGET, "Insufficient ETH for listing");
        require(balanceOf(address(this)) >= LISTING_TOKEN_AMOUNT + NUTBOX_ALLOCATION, "Insufficient token for listing");

        // Transfer NUTBOX_ALLOCATION to Hook before creating the pool
        address hookAddr = IPump(manager).getHookAddress();
        require(hookAddr != address(0), "Hook not set");
        _transfer(address(this), hookAddr, NUTBOX_ALLOCATION);

        // 1. Build the PoolKey (PCS V4 format)
        //    currency0 = Native ETH (address(0)), currency1 = Token
        //    tickSpacing is encoded in bytes32 parameters (bits [16-39])
        uint16 hookBitmap = IHooks(hookAddr).getHooksRegistrationBitmap();
        bytes32 parameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), TICK_SPACING);

        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE, // Native ETH
            currency1: Currency.wrap(address(this)), // Token
            hooks: IHooks(hookAddr),
            poolManager: IPoolManager(address(clPoolManager)),
            fee: 0, // No native LP fee, all fees via Hook
            parameters: parameters
        });

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
        bytes memory callbackData = abi.encode(poolKey, tickLower, tickUpper);
        vault.lock(callbackData);

        // 7. After LP is settled, send all remaining ETH to platform. Remaining token stays in this contract.
        address tiptagFeeAddress = IPump(manager).getFeeReceiver();
        uint256 remainEth = address(this).balance;
        if (remainEth > 0) {
            (bool success1, ) = tiptagFeeAddress.call{value: remainEth}("");
            require(success1, "Transfer ETH failed");
        }

        listed = true;
        emit TokenListedToDex(address(this), PoolId.unwrap(poolId), sqrtPriceX96);
    }

    /// @notice ILockCallback — 单次 token-first LP：200M token 全进池，配对 ~19.174 BNB。
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "Only Vault");

        (PoolKey memory poolKey, int24 tickLower, int24 tickUpper) = abi.decode(data, (PoolKey, int24, int24));

        _modifyAndSettleLiquidity(poolKey, tickLower, tickUpper, int256(uint256(LISTING_LIQUIDITY_DELTA)));

        require(balanceOf(address(this)) <= MAX_LISTING_TOKEN_DUST, "listing token dust too large");

        return "";
    }

    /// @dev Shared modifyLiquidity + vault settle/take for listing LP adds.
    function _modifyAndSettleLiquidity(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) private {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
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
