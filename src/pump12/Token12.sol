// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {CurveMath} from "./libraries/CurveMath.sol";

/// @title Token12
/// @notice Pump12 的固定供应 Token 与 USDG 内盘交易账本。
contract Token12 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CURVE_ALLOCATION = 750_000_000e18;
    uint256 public constant BASE_POL_ALLOCATION = 250_000_000e18;
    uint256 internal constant FEE_PRODUCT_DENOMINATOR = 100_000_000;
    uint256 internal constant TAGAI_SHARE_BPS = 1_000;

    error AlreadyInitialized();
    error OnlyManager();
    error CurveClosed();
    error InvalidAmount();
    error SlippageExceeded();
    error UnsupportedUsdGTransfer();
    error InsufficientCurveReserve();
    error CurveNotComplete();
    error AlreadyListed();

    event CurveTrade(
        address indexed trader,
        bool indexed isBuy,
        uint256 tokenAmount,
        uint256 curveAmountRaw,
        uint256 tagAIFeeRaw,
        uint256 creatorFeeRaw
    );
    event InnerFeeClaimed(address indexed recipient, bool indexed isTagAI, uint256 amountRaw);
    event Listed(bytes32 indexed poolId, address indexed liquidityVault, uint256 initialAnchor, uint256 listTime);

    string private _tokenName;
    string private _tokenSymbol;
    bool private initialized;

    address public manager;
    address public creator;
    address public tagAI;
    address public creatorFeeRecipient;
    address public indexToken;
    address public pTeamHolder;
    IERC20 public usdg;

    uint16 public totalFeeBps;
    uint16 public creatorShareBps;
    uint256 public bondingCurveSupply;
    uint256 public curveReserveRaw;
    uint256 public claimableTagAI;
    uint256 public claimableCreator;
    bool public listed;
    bytes32 public v4PoolId;
    address public liquidityVault;
    uint256 public initialAnchor;
    uint256 public listTime;

    constructor() {
        initialized = true;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    function initialize(
        address manager_,
        address creator_,
        address tagAI_,
        address usdg_,
        string calldata name_,
        string calldata symbol_,
        uint16 totalFeeBps_,
        uint16 creatorShareBps_,
        address creatorFeeRecipient_,
        address indexToken_,
        address pTeamHolder_
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        manager = manager_;
        creator = creator_;
        tagAI = tagAI_;
        usdg = IERC20(usdg_);
        _tokenName = name_;
        _tokenSymbol = symbol_;
        totalFeeBps = totalFeeBps_;
        creatorShareBps = creatorShareBps_;
        creatorFeeRecipient = creatorFeeRecipient_;
        indexToken = indexToken_;
        pTeamHolder = pTeamHolder_;

        _mint(address(this), INITIAL_SUPPLY);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function buy(uint256 maxInputRaw, uint256 minTokens)
        external
        nonReentrant
        returns (uint256 tokenOut, uint256 grossUsedRaw)
    {
        if (listed) revert CurveClosed();
        if (maxInputRaw == 0) revert InvalidAmount();

        uint256 balanceBefore = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), maxInputRaw);
        if (usdg.balanceOf(address(this)) - balanceBefore != maxInputRaw) revert UnsupportedUsdGTransfer();

        uint256 curveRaw;
        uint256 tagAIFeeRaw;
        uint256 creatorFeeRaw;
        (tokenOut, grossUsedRaw, curveRaw, tagAIFeeRaw, creatorFeeRaw) = quoteBuy(maxInputRaw);
        if (tokenOut == 0) revert InvalidAmount();
        if (tokenOut < minTokens) revert SlippageExceeded();

        bondingCurveSupply += tokenOut;
        curveReserveRaw += curveRaw;
        claimableTagAI += tagAIFeeRaw;
        claimableCreator += creatorFeeRaw;
        _transfer(address(this), msg.sender, tokenOut);

        uint256 refundRaw = maxInputRaw - grossUsedRaw;
        if (refundRaw != 0) usdg.safeTransfer(msg.sender, refundRaw);

        emit CurveTrade(msg.sender, true, tokenOut, curveRaw, tagAIFeeRaw, creatorFeeRaw);
    }

    function sell(uint256 tokenAmount, uint256 minOutputRaw) external nonReentrant returns (uint256 netRefundRaw) {
        if (listed) revert CurveClosed();
        if (tokenAmount == 0 || tokenAmount > balanceOf(msg.sender)) revert InvalidAmount();

        uint256 grossRefundRaw;
        uint256 tagAIFeeRaw;
        uint256 creatorFeeRaw;
        (grossRefundRaw, netRefundRaw, tagAIFeeRaw, creatorFeeRaw) = quoteSell(tokenAmount);
        if (grossRefundRaw == 0) revert InvalidAmount();
        if (netRefundRaw < minOutputRaw) revert SlippageExceeded();
        if (grossRefundRaw > curveReserveRaw) revert InsufficientCurveReserve();

        _transfer(msg.sender, address(this), tokenAmount);
        bondingCurveSupply -= tokenAmount;
        curveReserveRaw -= grossRefundRaw;
        claimableTagAI += tagAIFeeRaw;
        claimableCreator += creatorFeeRaw;

        usdg.safeTransfer(msg.sender, netRefundRaw);
        emit CurveTrade(msg.sender, false, tokenAmount, grossRefundRaw, tagAIFeeRaw, creatorFeeRaw);
    }

    function quoteBuy(uint256 maxInputRaw)
        public
        view
        returns (uint256 tokenOut, uint256 grossUsedRaw, uint256 curveRaw, uint256 tagAIFeeRaw, uint256 creatorFeeRaw)
    {
        if (listed || maxInputRaw == 0) return (0, 0, 0, 0, 0);

        uint256 netBudgetRaw = _netOfGross(maxInputRaw);
        tokenOut = CurveMath.amountForRawUSDG(bondingCurveSupply, netBudgetRaw);
        if (tokenOut == 0) return (0, 0, 0, 0, 0);

        curveRaw = CurveMath.costRawUSDG(bondingCurveSupply, tokenOut);
        grossUsedRaw = grossForCurveRaw(curveRaw);
        uint256 feeRaw = grossUsedRaw - curveRaw;
        (tagAIFeeRaw, creatorFeeRaw) = _splitInnerFee(feeRaw);
    }

    function quoteSell(uint256 tokenAmount)
        public
        view
        returns (uint256 grossRefundRaw, uint256 netRefundRaw, uint256 tagAIFeeRaw, uint256 creatorFeeRaw)
    {
        if (listed || tokenAmount == 0 || tokenAmount > bondingCurveSupply) return (0, 0, 0, 0);

        grossRefundRaw = CurveMath.refundRawUSDG(bondingCurveSupply, tokenAmount);
        uint256 feeRaw = _innerFee(grossRefundRaw);
        netRefundRaw = grossRefundRaw - feeRaw;
        (tagAIFeeRaw, creatorFeeRaw) = _splitInnerFee(feeRaw);
    }

    /// @notice 返回能为 curveRaw 提供精确净本金的最小用户毛支付。
    function grossForCurveRaw(uint256 curveRaw) public view returns (uint256 grossRaw) {
        if (curveRaw == 0) return 0;
        uint256 feeNumerator = _innerFeeNumerator();
        uint256 netNumerator = FEE_PRODUCT_DENOMINATOR - feeNumerator;
        grossRaw = Math.mulDiv(curveRaw, FEE_PRODUCT_DENOMINATOR, netNumerator, Math.Rounding.Up);

        while (_netOfGross(grossRaw) < curveRaw) ++grossRaw;
        while (grossRaw > 0 && _netOfGross(grossRaw - 1) >= curveRaw) --grossRaw;
    }

    function claimTagAIFees() external nonReentrant returns (uint256 amountRaw) {
        amountRaw = claimableTagAI;
        if (amountRaw == 0) return 0;
        claimableTagAI = 0;
        usdg.safeTransfer(tagAI, amountRaw);
        emit InnerFeeClaimed(tagAI, true, amountRaw);
    }

    function claimCreatorFees() external nonReentrant returns (uint256 amountRaw) {
        amountRaw = claimableCreator;
        if (amountRaw == 0) return 0;
        claimableCreator = 0;
        usdg.safeTransfer(creatorFeeRecipient, amountRaw);
        emit InnerFeeClaimed(creatorFeeRecipient, false, amountRaw);
    }

    function curveEndPrice() public pure returns (uint256) {
        return CurveMath.endPriceWad();
    }

    /// @notice Pump12 在单一原子 Listing 流程内关闭曲线并迁移基础 POL。
    function prepareListing(address vault, bytes32 poolId_) external onlyManager {
        if (listed) revert AlreadyListed();
        if (bondingCurveSupply != CURVE_ALLOCATION || curveReserveRaw != 15_000e6) revert CurveNotComplete();

        listed = true;
        liquidityVault = vault;
        v4PoolId = poolId_;
        initialAnchor = CurveMath.endPriceWad();
        listTime = block.timestamp;
        curveReserveRaw = 0;

        _transfer(address(this), vault, BASE_POL_ALLOCATION);
        usdg.safeTransfer(vault, 15_000e6);
        emit Listed(poolId_, vault, initialAnchor, listTime);
    }

    function _innerFee(uint256 grossRaw) internal view returns (uint256) {
        return Math.mulDiv(grossRaw, _innerFeeNumerator(), FEE_PRODUCT_DENOMINATOR);
    }

    function _netOfGross(uint256 grossRaw) internal view returns (uint256) {
        return grossRaw - _innerFee(grossRaw);
    }

    function _innerFeeNumerator() internal view returns (uint256) {
        return uint256(totalFeeBps) * (TAGAI_SHARE_BPS + uint256(creatorShareBps));
    }

    function _splitInnerFee(uint256 feeRaw) internal view returns (uint256 tagAIFeeRaw, uint256 creatorFeeRaw) {
        uint256 totalShares = TAGAI_SHARE_BPS + uint256(creatorShareBps);
        creatorFeeRaw = Math.mulDiv(feeRaw, creatorShareBps, totalShares);
        tagAIFeeRaw = feeRaw - creatorFeeRaw;
    }
}
