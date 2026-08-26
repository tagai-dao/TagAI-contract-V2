// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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

/**
 * @title SPCXBSwapExecutor
 * @notice Fee-preserving BNB -> USDT -> SPCXB executor for TagAI Blinks.
 * @dev The route is restricted to the configured assets and Pancake V3 fee tiers.
 *      Creator fees are atomically injected through IPShare.valueCapture; the
 *      remaining BNB is sent directly to Pancake SmartRouter. This contract is
 *      intentionally independent from ImportedTokenSwapWrapper.
 */
contract SPCXBSwapExecutor is Ownable2Step, Pausable, ReentrancyGuard {
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
        return _validatePath(path);
    }

    function buySpcxb(bytes calldata path, uint256 minimumTokenOut, address recipient, address creator)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenOut)
    {
        if (msg.value == 0) revert InvalidAmount();
        if (recipient == address(0) || creator == address(0)) revert InvalidAddress();
        uint24 firstHopFee = _validatePath(path);

        (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee) = _feeAmounts(msg.value);
        if (creatorFee != 0) {
            if (creator != feeAddress && ipshare.ipshareCreated(creator)) {
                ipshare.valueCapture{value: creatorFee}(creator);
            } else if (!_trySendNative(creator, creatorFee)) {
                _sendNative(feeAddress, creatorFee);
            }
        }
        if (tagaiFee != 0) _sendNative(feeAddress, tagaiFee);

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

    function _feeAmounts(uint256 nativeAmount)
        internal
        view
        returns (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee)
    {
        creatorFee = (nativeAmount * creatorFeeBps) / BPS_DENOMINATOR;
        tagaiFee = (nativeAmount * tagaiFeeBps) / BPS_DENOMINATOR;
        swapAmount = nativeAmount - creatorFee - tagaiFee;
    }

    function _validatePath(bytes calldata path) internal view returns (uint24 firstHopFee) {
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

    function _allowedFirstHopFee(uint24 fee) private pure returns (bool) {
        return fee == 100 || fee == 500 || fee == 2_500 || fee == 10_000;
    }

    function _sendNative(address recipient, uint256 amount) private {
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _trySendNative(address recipient, uint256 amount) private returns (bool ok) {
        (ok,) = payable(recipient).call{value: amount}("");
    }
}
