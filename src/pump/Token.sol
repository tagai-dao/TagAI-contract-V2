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
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INutboxRouter} from "../router/INutboxRouter.sol";

interface IPancakeV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
}

interface ITipTagSwapHook {
    function registerPool(PoolId poolId, address token) external;
}

error OnlyPump();
error NutboxAddressesAlreadySet();

contract Token is IToken, ERC20, ReentrancyGuard, ILockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 public constant V4_TOKEN_ALLOCATION = 150_000_000 ether;
    uint256 public constant COMPONENT_TOKEN_ALLOCATION = 50_000_000 ether;
    uint256 public constant V4_NATIVE_ALLOCATION = 15 ether;
    address public constant LP_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Token-side transfer tax for every post-list transfer into or out of a component V2 pair.
    uint256 public constant COMPONENT_POOL_TAX_BPS = 10;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_COMPONENTS = 4;

    address public indexCreator;
    address public pancakeV2Factory;
    address private _listingRouter;
    address private _listingBasketHook;
    address private _listingSettlementToken;
    string public indexName;
    string public indexSymbol;
    uint16 public basketFeeBps;
    uint16 public creatorShareBps;
    address public indexToken;
    bool private _indexInitialized;
    uint256 public accIndexRewardPerToken;
    uint256 public totalIndexRewardsNotified;
    mapping(address => uint256) public pendingIndexRewards;
    mapping(address => uint256) public indexRewardDebt;

    address[] private _componentAssets;
    uint16[] private _componentWeights;
    address[] private _componentPairs;
    mapping(address => bool) public componentPair;

    event ComponentPairCreated(address indexed asset, address indexed pair, uint16 weight);
    event ComponentLiquidityBurned(
        address indexed asset,
        address indexed pair,
        uint256 nativeBudget,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint256 liquidity
    );

    error InvalidIndexConfig();
    error IndexAlreadyInitialized();
    error InvalidComponentPair();
    error ComponentSwapFailed();
    error IndexCreationFailed();

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
    bool public listingPending = false;
    bool initialized = false;

    /// @dev Filled once by Pump after the Nutbox community and component-LP staking pools exist.
    address public nutboxCommunity;

    // PCS V4 pool info
    ICLPoolManager public clPoolManager;
    IVault public vault;
    PoolId public v4PoolId;
    /// @notice Hook permanently bound to this token's listing pool.
    /// @dev Snapshotted at listing so later Pump hook upgrades cannot change this pool's identity or fee destination.
    address public listingHook;
    bytes32 public listingPoolParameters;
    uint24 public constant LISTING_LP_FEE = 0;
    /// @dev 0.5% of collected BNB LP fees rewards the permissionless caller.
    uint256 public constant COLLECT_CALLER_REWARD_BPS = 50;
    uint256 private constant ACC_REWARD_PRECISION = 1e36;
    int24 public constant TICK_SPACING = 60;
    // V13: 150M tokens / 15 BNB in V4; 50M tokens / 5 BNB across component V2 pools.
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 225060284636549774439465527763777;
    int24 private constant LISTING_TICK_LOWER = -887220;
    int24 private constant LISTING_TICK_UPPER = 191940;
    uint128 private constant LISTING_LIQUIDITY_DELTA = 52804626975085827442929;

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

    /// @notice Configures the V13 index and its component pairs once, from the canonical Pump.
    function initializeIndex(
        address pump,
        address creator,
        address v2Factory,
        address router,
        address basketHook,
        address settlement,
        address hook,
        IPump.IndexConfig calldata config
    ) external {
        if (_indexInitialized) revert IndexAlreadyInitialized();
        if (
            msg.sender != manager || pump != manager || !initialized || pump == address(0) || creator == address(0)
                || v2Factory.code.length == 0 || router.code.length == 0 || basketHook.code.length == 0
                || settlement.code.length == 0 || hook.code.length == 0
        ) {
            revert InvalidIndexConfig();
        }
        uint256 count = config.constituentAssets.length;
        if (
            count == 0 || count > MAX_COMPONENTS || count != config.targetWeights.length
                || bytes(config.name).length == 0 || bytes(config.symbol).length == 0 || config.basketFeeBps < 100
                || config.basketFeeBps > 300 || config.creatorShareBps > 3_000
        ) revert InvalidIndexConfig();

        _indexInitialized = true;
        indexCreator = creator;
        pancakeV2Factory = v2Factory;
        _listingRouter = router;
        _listingBasketHook = basketHook;
        _listingSettlementToken = settlement;
        listingHook = hook;
        indexName = config.name;
        indexSymbol = config.symbol;
        basketFeeBps = config.basketFeeBps;
        creatorShareBps = config.creatorShareBps;

        uint256 totalWeight;
        IPancakeV2Factory factory = IPancakeV2Factory(v2Factory);
        for (uint256 i; i < count; ++i) {
            address asset = config.constituentAssets[i];
            uint16 weight = config.targetWeights[i];
            if (asset == address(0) || asset == address(this) || asset.code.length == 0 || weight == 0) {
                revert InvalidIndexConfig();
            }
            for (uint256 j; j < i; ++j) {
                if (_componentAssets[j] == asset) revert InvalidIndexConfig();
            }
            totalWeight += weight;

            address pair = factory.getPair(address(this), asset);
            if (pair == address(0)) pair = factory.createPair(address(this), asset);
            if (pair.code.length == 0) revert InvalidComponentPair();
            address token0 = IPancakeV2Pair(pair).token0();
            address token1 = IPancakeV2Pair(pair).token1();
            if (!((token0 == address(this) && token1 == asset) || (token0 == asset && token1 == address(this)))) {
                revert InvalidComponentPair();
            }

            _componentAssets.push(asset);
            _componentWeights.push(weight);
            _componentPairs.push(pair);
            componentPair[pair] = true;
            emit ComponentPairCreated(asset, pair, weight);
        }
        if (totalWeight != BPS) revert InvalidIndexConfig();
    }

    function componentCount() external view returns (uint256) {
        return _componentAssets.length;
    }

    function componentAt(uint256 index) external view returns (address asset, uint16 weight, address pair) {
        return (_componentAssets[index], _componentWeights[index], _componentPairs[index]);
    }

    /// @notice Infrastructure snapshot selected when this Token was created.
    /// @dev Later Pump configuration changes only affect newly-created Tokens.
    function listingInfrastructure()
        external
        view
        returns (address router, address basketHook, address settlement, address poolManager)
    {
        return (_listingRouter, _listingBasketHook, _listingSettlementToken, address(clPoolManager));
    }

    /// @notice Records the Nutbox community; its staking pools are enumerable through Community.activedPools.
    function setNutboxCommunity(address community) external {
        if (msg.sender != manager) revert OnlyPump();
        if (nutboxCommunity != address(0)) revert NutboxAddressesAlreadySet();
        require(community != address(0));
        nutboxCommunity = community;
    }

    /********************************** bonding curve ********************************/
    function buyToken(uint256 expectAmount, address sellsman, uint16 slippage)
        public
        payable
        nonReentrant
        returns (uint256)
    {
        if (msg.sender == address(clPoolManager)) revert TokenListed();
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
        if (actualAmount == 0) revert TokenListingPending();
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
        listingPending = true;
        emit TokenListingQueued(address(this));
        return actualAmount;
    }

    function _checkBondingCurveState(address sellsman) private returns (address) {
        if (listingPending) revert TokenListingPending();
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

    function finalizeListing(uint256[] calldata componentMinOuts, uint256 deadline)
        external
        nonReentrant
        returns (address)
    {
        if (msg.sender != manager) revert OnlyPump();
        if (listed || (!listingPending && bondingCurveSupply != bondingCurveTotalAmount)) {
            revert TokenNotListingPending();
        }
        if (block.timestamp > deadline) revert ListingDeadlineExpired();
        if (componentMinOuts.length != _componentAssets.length) revert InvalidComponentMinOuts();
        _makeLiquidityPool(componentMinOuts, deadline);
        return indexToken;
    }

    /// @notice Clears a failed pending listing without moving funds, reopening bonding-curve sells.
    function recoverFailedListing() external {
        if (msg.sender != manager) revert OnlyPump();
        if (!listingPending || listed) revert TokenNotListingPending();
        listingPending = false;
    }

    function notifyBuybackReward(uint256 amount) external nonReentrant {
        if (msg.sender != listingHook) revert OnlyPump();
        if (indexToken == address(0)) revert IndexTokenNotReady();
        uint256 eligibleSupply = _rewardEligibleSupply();
        if (eligibleSupply == 0) revert NoEligibleRewardSupply();

        uint256 balanceBefore = IERC20(indexToken).balanceOf(address(this));
        IERC20(indexToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(indexToken).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidRewardAmount();

        accIndexRewardPerToken += received * ACC_REWARD_PRECISION / eligibleSupply;
        totalIndexRewardsNotified += received;
        emit BuybackRewardNotified(indexToken, received, accIndexRewardPerToken);
    }

    function claimBuybackReward(address account) external nonReentrant returns (uint256 amount) {
        _accrueIndexReward(account);
        amount = pendingIndexRewards[account];
        if (amount == 0) return 0;
        pendingIndexRewards[account] = 0;
        IERC20(indexToken).safeTransfer(account, amount);
        emit BuybackRewardClaimed(msg.sender, account, amount);
    }

    function pendingBuybackReward(address account) external view returns (uint256 amount) {
        amount = pendingIndexRewards[account];
        if (_isRewardExcluded(account)) return amount;
        uint256 accumulated = balanceOf(account) * accIndexRewardPerToken / ACC_REWARD_PRECISION;
        if (accumulated > indexRewardDebt[account]) {
            amount += accumulated - indexRewardDebt[account];
        }
    }

    /// @notice Native amount available to component V2 pools after the deterministic V4 seed is paid.
    /// @dev Useful for the listing keeper to calculate per-leg minimum outputs without assuming exactly 5 BNB.
    function componentListingNativeBudget() public view returns (uint256) {
        uint256 v4NativeRequired = _v4NativeRequired();
        uint256 nativeBalance = address(this).balance;
        return nativeBalance > v4NativeRequired ? nativeBalance - v4NativeRequired : 0;
    }

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

    function _makeLiquidityPool(uint256[] calldata componentMinOuts, uint256 deadline) private {
        if (_inAntiSnipeWindow()) revert ListingDisabledDuringAntiSnipe();
        if (!_indexInitialized) revert InvalidIndexConfig();
        if (componentListingNativeBudget() == 0) revert ComponentSwapFailed();
        if (balanceOf(address(this)) < V4_TOKEN_ALLOCATION + COMPONENT_TOKEN_ALLOCATION + NUTBOX_ALLOCATION) {
            revert InvalidIndexConfig();
        }

        address hookAddr = listingHook;
        _transfer(address(this), hookAddr, NUTBOX_ALLOCATION);

        uint16 hookBitmap = IHooks(hookAddr).getHooksRegistrationBitmap();
        listingPoolParameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), TICK_SPACING);
        PoolKey memory poolKey = _listingPoolKey();

        clPoolManager.initialize(poolKey, INITIAL_SQRT_PRICE_X96);
        PoolId poolId = poolKey.toId();
        v4PoolId = poolId;
        ITipTagSwapHook(hookAddr).registerPool(poolId, address(this));

        vault.lock(abi.encode(LOCK_OP_SEED, poolKey, LISTING_TICK_LOWER, LISTING_TICK_UPPER, address(0)));

        // Spend every wei left after the deterministic V4 seed across the component pools.
        _seedComponentPools(componentMinOuts, deadline, address(this).balance);
        listingPending = false;
        listed = true;
        indexToken = IPump(manager).finalizeTokenListing();
        if (indexToken == address(0)) revert IndexCreationFailed();

        uint256 remainingNative = address(this).balance;
        if (remainingNative != 0) {
            (bool sent,) = IPump(manager).getFeeReceiver().call{value: remainingNative}("");
            if (!sent) revert RefundFail();
        }

        emit TokenListedToDex(address(this), PoolId.unwrap(poolId), INITIAL_SQRT_PRICE_X96);
    }

    function _seedComponentPools(uint256[] calldata componentMinOuts, uint256 deadline, uint256 totalNativeBudget)
        private
    {
        INutboxRouter router = INutboxRouter(_listingRouter);
        uint256 count = _componentAssets.length;
        uint256 allocatedNative;
        uint256 allocatedToken;

        for (uint256 i; i < count; ++i) {
            require(componentMinOuts[i] != 0);
            uint256 nativeBudget =
                i + 1 == count ? totalNativeBudget - allocatedNative : totalNativeBudget * _componentWeights[i] / BPS;
            uint256 tokenAmount = i + 1 == count
                ? COMPONENT_TOKEN_ALLOCATION - allocatedToken
                : COMPONENT_TOKEN_ALLOCATION * _componentWeights[i] / BPS;
            allocatedNative += nativeBudget;
            allocatedToken += tokenAmount;

            address asset = _componentAssets[i];
            uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
            router.swapExactInput{value: nativeBudget}(
                address(0), asset, nativeBudget, componentMinOuts[i], address(this), deadline
            );
            uint256 assetAmount = IERC20(asset).balanceOf(address(this)) - balanceBefore;
            if (assetAmount == 0) revert ComponentSwapFailed();

            address pair = _componentPairs[i];
            _transfer(address(this), pair, tokenAmount);
            uint256 pairAssetBefore = IERC20(asset).balanceOf(pair);
            IERC20(asset).safeTransfer(pair, assetAmount);
            if (IERC20(asset).balanceOf(pair) - pairAssetBefore != assetAmount) revert ComponentSwapFailed();
            uint256 liquidity = IPancakeV2Pair(pair).mint(LP_BURN_ADDRESS);
            if (liquidity == 0) revert InvalidComponentPair();
            emit ComponentLiquidityBurned(asset, pair, nativeBudget, tokenAmount, assetAmount, liquidity);
        }
    }

    function _v4NativeRequired() private pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(
            INITIAL_SQRT_PRICE_X96, TickMath.getSqrtRatioAtTick(LISTING_TICK_UPPER), LISTING_LIQUIDITY_DELTA, true
        );
    }

    function _rewardEligibleSupply() private view returns (uint256 supply) {
        supply = totalSupply() - balanceOf(address(this));
        if (listingHook != address(0)) {
            uint256 hookBalance = balanceOf(listingHook);
            if (hookBalance < supply) supply -= hookBalance;
            else supply = 0;
        }
        if (address(vault) != address(0)) {
            uint256 vaultBalance = balanceOf(address(vault));
            if (vaultBalance < supply) supply -= vaultBalance;
            else supply = 0;
        }
        uint256 deadBalance = balanceOf(LP_BURN_ADDRESS);
        if (deadBalance < supply) supply -= deadBalance;
        else supply = 0;
        uint256 count = _componentPairs.length;
        for (uint256 i; i < count; ++i) {
            uint256 pairBalance = balanceOf(_componentPairs[i]);
            if (pairBalance < supply) supply -= pairBalance;
            else return 0;
        }
    }

    function _isRewardExcluded(address account) private view returns (bool) {
        return account == address(0) || account == address(this) || account == listingHook || account == address(vault)
            || account == LP_BURN_ADDRESS || componentPair[account];
    }

    function _accrueIndexReward(address account) private {
        if (_isRewardExcluded(account)) {
            indexRewardDebt[account] = 0;
            return;
        }
        uint256 accumulated = balanceOf(account) * accIndexRewardPerToken / ACC_REWARD_PRECISION;
        uint256 debt = indexRewardDebt[account];
        if (accumulated > debt) {
            pendingIndexRewards[account] += accumulated - debt;
        }
        indexRewardDebt[account] = accumulated;
    }

    function _syncIndexRewardDebt(address account) private {
        if (_isRewardExcluded(account)) {
            indexRewardDebt[account] = 0;
            return;
        }
        indexRewardDebt[account] = balanceOf(account) * accIndexRewardPerToken / ACC_REWARD_PRECISION;
    }

    /// @notice ILockCallback — seed listing LP or collect accrued LP fees (liquidityDelta=0).
    function lockAcquired(bytes calldata data) public override returns (bytes memory) {
        require(msg.sender == address(vault));

        (uint8 op, PoolKey memory poolKey, int24 tickLower, int24 tickUpper, address collector) =
            abi.decode(data, (uint8, PoolKey, int24, int24, address));

        if (op == LOCK_OP_SEED) {
            _modifyAndSettleLiquidity(poolKey, tickLower, tickUpper, int256(uint256(LISTING_LIQUIDITY_DELTA)));
        } else if (op == LOCK_OP_COLLECT) {
            _collectListingFees(poolKey, tickLower, tickUpper, collector);
        } else {
            revert();
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
            if (ethToSettle > V4_NATIVE_ALLOCATION) revert InvalidIndexConfig();
            vault.settle{value: ethToSettle}();
        }

        if (tokenOwed < 0) {
            uint256 tokenToSettle = uint256(uint128(-tokenOwed));
            if (tokenToSettle > V4_TOKEN_ALLOCATION) revert InvalidIndexConfig();
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

    /// @dev Applies the component-pool tax once to the gross amount. Internal protocol transfers, including
    ///      initial liquidity seeding, deliberately use `_transfer` and are not taxed.
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithComponentPoolTax(msg.sender, to, amount);
        return true;
    }

    /// @dev Allowance is consumed once against the gross amount, matching ordinary ERC20 semantics.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transferWithComponentPoolTax(from, to, amount);
        return true;
    }

    function _transferWithComponentPoolTax(address from, address to, uint256 amount) private {
        address pair;
        if (listed) {
            if (componentPair[from]) pair = from;
            else if (componentPair[to]) pair = to;
        }

        uint256 taxAmount = pair == address(0) ? 0 : amount * COMPONENT_POOL_TAX_BPS / BPS;
        if (taxAmount == 0) {
            _transfer(from, to, amount);
            return;
        }

        _transfer(from, to, amount - taxAmount);
        // This is an internal balance move, so it neither re-enters transfer() nor incurs a second tax.
        _transfer(from, LP_BURN_ADDRESS, taxAmount);
        emit ComponentPoolTaxBurned(pair, from, to, amount, taxAmount);
    }

    // only listed token can do erc20 transfer functions
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!listed && componentPair[to] && from != address(this)) revert TokenNotListed();
        // Before listing, prevent unauthorized token transfers to Vault
        if (!listed && to == address(vault) && from != address(this)) {
            revert TokenNotListed();
        }
        if (amount != 0 && accIndexRewardPerToken != 0) {
            _accrueIndexReward(from);
            _accrueIndexReward(to);
        }
        return super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (amount != 0 && accIndexRewardPerToken != 0) {
            _syncIndexRewardDebt(from);
            _syncIndexRewardDebt(to);
        }
        super._afterTokenTransfer(from, to, amount);
    }
}
