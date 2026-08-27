// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IIPShare.sol";

interface ISPCXBPancakeV3SmartRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface ISPCXBWrappedNative {
    function withdraw(uint256 amount) external;
}

/**
 * @title SPCXBSwapExecutor
 * @notice Fee-preserving bidirectional BNB <-> USDT <-> SPCXB executor for TagAI.
 * @dev The route is restricted to the configured assets and Pancake V3 fee tiers.
 *      Creator fees are atomically injected through IPShare.valueCapture; the
 *      Buy and sell flows share the same deep-liquidity route and fee rules for
 *      Blinks, web, PWA, and App. This contract is intentionally independent
 *      from ImportedTokenSwapWrapper.
 */
contract SPCXBSwapExecutor is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_TOTAL_FEE_BPS = 2_000;
    uint24 public constant SPCXB_POOL_FEE = 2_500;

    ISPCXBPancakeV3SmartRouter public immutable smartRouter;
    IIPShare public immutable ipshare;
    address public immutable wrappedNative;
    address public immutable usdt;
    address public immutable spcxb;

    address public feeAddress;
    uint16 public creatorFeeBps = 20;
    uint16 public tagaiFeeBps = 20;

    event FeeAddressChanged(address indexed previousFeeAddress, address indexed newFeeAddress);
    event FeeRatiosChanged(uint16 creatorFeeBps, uint16 tagaiFeeBps);
    event SPCXBBought(
        address indexed buyer,
        address indexed recipient,
        address indexed creator,
        uint256 grossNativeAmount,
        uint256 swapNativeAmount,
        uint256 tokenAmount,
        uint256 creatorFee,
        uint256 tagaiFee,
        uint24 firstHopFee
    );
    event SPCXBSold(
        address indexed seller,
        address indexed recipient,
        address indexed creator,
        uint256 tokenAmount,
        uint256 grossNativeAmount,
        uint256 netNativeAmount,
        uint256 creatorFee,
        uint256 tagaiFee,
        uint24 secondHopFee
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidFeeRatio();
    error InvalidRoute();
    error NativeTransferFailed();
    error SlippageExceeded();

    constructor(
        address smartRouter_,
        address ipshare_,
        address wrappedNative_,
        address usdt_,
        address spcxb_,
        address feeAddress_
    ) {
        if (
            smartRouter_.code.length == 0 || ipshare_.code.length == 0 || wrappedNative_.code.length == 0
                || usdt_.code.length == 0 || spcxb_.code.length == 0 || feeAddress_ == address(0)
                || feeAddress_ == address(this)
        ) revert InvalidAddress();
        smartRouter = ISPCXBPancakeV3SmartRouter(smartRouter_);
        ipshare = IIPShare(ipshare_);
        wrappedNative = wrappedNative_;
        usdt = usdt_;
        spcxb = spcxb_;
        feeAddress = feeAddress_;
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert InvalidAddress();
    }

    function setFeeAddress(address newFeeAddress) external onlyOwner {
        if (newFeeAddress == address(0) || newFeeAddress == address(this)) revert InvalidAddress();
        address previousFeeAddress = feeAddress;
        feeAddress = newFeeAddress;
        emit FeeAddressChanged(previousFeeAddress, newFeeAddress);
    }

    function setFeeRatios(uint16 creatorFeeBps_, uint16 tagaiFeeBps_) external onlyOwner {
        if (uint256(creatorFeeBps_) + uint256(tagaiFeeBps_) > MAX_TOTAL_FEE_BPS) revert InvalidFeeRatio();
        creatorFeeBps = creatorFeeBps_;
        tagaiFeeBps = tagaiFeeBps_;
        emit FeeRatiosChanged(creatorFeeBps_, tagaiFeeBps_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function previewFees(uint256 nativeAmount)
        external
        view
        returns (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee)
    {
        return _feeAmounts(nativeAmount);
    }

    function validatePath(bytes calldata path) external view returns (uint24 firstHopFee) {
        return _validateBuyPath(path);
    }

    function validateSellPath(bytes calldata path) external view returns (uint24 secondHopFee) {
        return _validateSellPath(path);
    }

    function buySpcxb(bytes calldata path, uint256 minimumTokenOut, address recipient, address creator)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenOut)
    {
        if (msg.value == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        creator = _resolveCreator(creator);
        uint24 firstHopFee = _validateBuyPath(path);

        (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee) = _feeAmounts(msg.value);
        _distributeFees(creator, creatorFee, tagaiFee);

        tokenOut = smartRouter.exactInput{value: swapAmount}(
            ISPCXBPancakeV3SmartRouter.ExactInputParams({
                path: path, recipient: recipient, amountIn: swapAmount, amountOutMinimum: minimumTokenOut
            })
        );
        if (tokenOut < minimumTokenOut) revert SlippageExceeded();

        emit SPCXBBought(
            msg.sender, recipient, creator, msg.value, swapAmount, tokenOut, creatorFee, tagaiFee, firstHopFee
        );
    }

    function sellSpcxb(
        bytes calldata path,
        uint256 amountIn,
        uint256 minimumNativeOut,
        address recipient,
        address creator
    ) external nonReentrant whenNotPaused returns (uint256 nativeOut) {
        if (amountIn == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        creator = _resolveCreator(creator);
        uint24 secondHopFee = _validateSellPath(path);

        IERC20 token = IERC20(spcxb);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 receivedAmount = token.balanceOf(address(this)) - balanceBefore;
        if (receivedAmount == 0) revert InvalidAmount();
        token.forceApprove(address(smartRouter), receivedAmount);

        uint256 grossNativeOut = smartRouter.exactInput(
            ISPCXBPancakeV3SmartRouter.ExactInputParams({
                path: path, recipient: address(this), amountIn: receivedAmount, amountOutMinimum: 1
            })
        );
        ISPCXBWrappedNative(wrappedNative).withdraw(grossNativeOut);

        uint256 creatorFee;
        uint256 tagaiFee;
        (nativeOut, creatorFee, tagaiFee) = _feeAmounts(grossNativeOut);
        if (nativeOut < minimumNativeOut) revert SlippageExceeded();
        _distributeFees(creator, creatorFee, tagaiFee);
        _sendNative(recipient, nativeOut);

        emit SPCXBSold(
            msg.sender,
            recipient,
            creator,
            receivedAmount,
            grossNativeOut,
            nativeOut,
            creatorFee,
            tagaiFee,
            secondHopFee
        );
    }

    function _feeAmounts(uint256 nativeAmount)
        internal
        view
        returns (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee)
    {
        creatorFee = (nativeAmount * creatorFeeBps) / BPS_DENOMINATOR;
        tagaiFee = (nativeAmount * tagaiFeeBps) / BPS_DENOMINATOR;
        swapAmount = nativeAmount - creatorFee - tagaiFee;
    }

    function _validateBuyPath(bytes calldata path) internal view returns (uint24 firstHopFee) {
        // address + uint24 + address + uint24 + address
        if (path.length != 66) revert InvalidRoute();
        address tokenIn;
        address intermediate;
        address tokenOut;
        uint24 secondHopFee;
        assembly ("memory-safe") {
            tokenIn := shr(96, calldataload(path.offset))
            firstHopFee := shr(232, calldataload(add(path.offset, 20)))
            intermediate := shr(96, calldataload(add(path.offset, 23)))
            secondHopFee := shr(232, calldataload(add(path.offset, 43)))
            tokenOut := shr(96, calldataload(add(path.offset, 46)))
        }
        if (
            tokenIn != wrappedNative || intermediate != usdt || tokenOut != spcxb || secondHopFee != SPCXB_POOL_FEE
                || !_allowedFirstHopFee(firstHopFee)
        ) revert InvalidRoute();
    }

    function _validateSellPath(bytes calldata path) internal view returns (uint24 secondHopFee) {
        // address + uint24 + address + uint24 + address
        if (path.length != 66) revert InvalidRoute();
        address tokenIn;
        address intermediate;
        address tokenOut;
        uint24 firstHopFee;
        assembly ("memory-safe") {
            tokenIn := shr(96, calldataload(path.offset))
            firstHopFee := shr(232, calldataload(add(path.offset, 20)))
            intermediate := shr(96, calldataload(add(path.offset, 23)))
            secondHopFee := shr(232, calldataload(add(path.offset, 43)))
            tokenOut := shr(96, calldataload(add(path.offset, 46)))
        }
        if (
            tokenIn != spcxb || intermediate != usdt || tokenOut != wrappedNative || firstHopFee != SPCXB_POOL_FEE
                || !_allowedFirstHopFee(secondHopFee)
        ) revert InvalidRoute();
    }

    function _allowedFirstHopFee(uint24 fee) private pure returns (bool) {
        return fee == 100 || fee == 500 || fee == 2_500 || fee == 10_000;
    }

    function _sendNative(address recipient, uint256 amount) private {
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _resolveCreator(address creator) private view returns (address) {
        return creator == address(0) || creator == address(this) ? feeAddress : creator;
    }

    function _distributeFees(address creator, uint256 creatorFee, uint256 tagaiFee) private {
        if (creatorFee != 0) {
            if (creator != feeAddress && ipshare.ipshareCreated(creator)) {
                ipshare.valueCapture{value: creatorFee}(creator);
            } else if (!_trySendNative(creator, creatorFee)) {
                _sendNative(feeAddress, creatorFee);
            }
        }
        if (tagaiFee != 0) _sendNative(feeAddress, tagaiFee);
    }

    function _trySendNative(address recipient, uint256 amount) private returns (bool ok) {
        (ok,) = payable(recipient).call{value: amount}("");
    }
}
