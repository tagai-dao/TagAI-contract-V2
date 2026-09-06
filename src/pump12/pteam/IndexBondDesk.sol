// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {IIndexFund} from "../fund/IIndexFund.sol";

interface IHookIndexBondDesk {
    function validTWAP(PoolId id) external view returns (uint256);
    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256 received);
}

interface IBurnNetIndexBondDesk {
    function anchor() external view returns (uint256);
    function mintingAvailable() external view returns (bool);
}

/// @title IndexBondDesk
/// @notice Sells pTEAM inventory at a protected premium and atomically routes every USDG unit.
contract IndexBondDesk is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant RAW_USDG_TO_TOKEN_WAD_SCALE = 1e30;
    uint16 public constant DISCOUNT_BPS = 650;
    uint16 public constant ANCHOR_FLOOR_BPS = 12_000;
    uint16 public constant INVENTORY_CAP_BPS = 50;
    uint40 public constant VESTING_LENGTH = 2 days;

    error AlreadyInitialized();
    error InvalidInitialization();
    error InvalidAmount();
    error InvalidAddress();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error InsufficientInventory();
    error UnsupportedUsdGTransfer();
    error InvalidNote();
    error NotActive();

    struct Note {
        uint256 payout;
        uint256 claimed;
        uint40 start;
        uint40 end;
    }

    bool public initialized;
    IERC20 public usdg;
    IERC20 public token;
    IHookIndexBondDesk public hook;
    IBurnNetIndexBondDesk public burnNet;
    IIndexFund public indexFund;
    PoolId public poolId;
    uint256 public outstandingVestingLiability;
    mapping(address account => Note[] notes) private _notes;

    event DeskInitialized(address indexed token, PoolId indexed poolId, address indexed indexFund);
    event Subscribed(
        address indexed caller,
        address indexed recipient,
        uint256 indexed noteId,
        uint256 tokenAmount,
        uint256 totalUsdGRaw,
        uint256 anchorRemittanceRaw,
        uint256 indexProceedsRaw,
        uint256 price
    );
    event Redeemed(address indexed owner, address indexed recipient, uint256 indexed noteId, uint256 amount);

    constructor() {
        initialized = true;
    }

    function initialize(
        address usdg_,
        address token_,
        address hook_,
        address burnNet_,
        address indexFund_,
        PoolId poolId_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            usdg_.code.length == 0 || token_.code.length == 0 || hook_.code.length == 0 || burnNet_.code.length == 0
                || indexFund_.code.length == 0 || PoolId.unwrap(poolId_) == bytes32(0)
        ) revert InvalidInitialization();
        initialized = true;
        usdg = IERC20(usdg_);
        token = IERC20(token_);
        hook = IHookIndexBondDesk(hook_);
        burnNet = IBurnNetIndexBondDesk(burnNet_);
        indexFund = IIndexFund(indexFund_);
        poolId = poolId_;
        emit DeskInitialized(token_, poolId_, indexFund_);
    }

    function deskPrice() public view returns (uint256) {
        uint256 discounted = Math.mulDiv(hook.validTWAP(poolId), BPS - DISCOUNT_BPS, BPS);
        uint256 floorPrice = Math.mulDiv(burnNet.anchor(), ANCHOR_FLOOR_BPS, BPS);
        return discounted > floorPrice ? discounted : floorPrice;
    }

    function unsoldInventory() public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return balance > outstandingVestingLiability ? balance - outstandingVestingLiability : 0;
    }

    function canReceiveInventory(uint256 amount, uint256 supplyAfterMint) external view returns (bool) {
        return unsoldInventory() + amount <= Math.mulDiv(supplyAfterMint, INVENTORY_CAP_BPS, BPS);
    }

    function subscribe(uint256 tokenAmount, uint256 maxPriceWad, address recipient)
        external
        nonReentrant
        returns (uint256 noteId, uint256 totalUsdGRaw)
    {
        if (tokenAmount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        if (!burnNet.mintingAvailable()) revert NotActive();
        if (tokenAmount > unsoldInventory()) revert InsufficientInventory();
        uint256 price = deskPrice();
        if (price > maxPriceWad) revert PriceAboveMax(price, maxPriceWad);

        totalUsdGRaw = Math.mulDiv(tokenAmount, price, RAW_USDG_TO_TOKEN_WAD_SCALE, Math.Rounding.Up);
        uint256 anchorRemittanceRaw =
            Math.mulDiv(tokenAmount, burnNet.anchor(), RAW_USDG_TO_TOKEN_WAD_SCALE, Math.Rounding.Up);
        uint256 indexProceedsRaw = totalUsdGRaw - anchorRemittanceRaw;
        if (indexProceedsRaw == 0) revert InvalidAmount();

        uint256 beforeBalance = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), totalUsdGRaw);
        if (usdg.balanceOf(address(this)) - beforeBalance != totalUsdGRaw) revert UnsupportedUsdGTransfer();

        usdg.forceApprove(address(hook), anchorRemittanceRaw);
        if (hook.addPendingUSDG(poolId, anchorRemittanceRaw) != anchorRemittanceRaw) {
            revert UnsupportedUsdGTransfer();
        }
        usdg.safeTransfer(address(indexFund), indexProceedsRaw);
        indexFund.onDeskProceeds(indexProceedsRaw);

        outstandingVestingLiability += tokenAmount;
        noteId = _notes[recipient].length;
        _notes[recipient].push(
            Note({
                payout: tokenAmount,
                claimed: 0,
                start: uint40(block.timestamp),
                end: uint40(block.timestamp + VESTING_LENGTH)
            })
        );
        emit Subscribed(
            msg.sender, recipient, noteId, tokenAmount, totalUsdGRaw, anchorRemittanceRaw, indexProceedsRaw, price
        );
    }

    function redeem(uint256 noteId, address recipient) external nonReentrant returns (uint256 paid) {
        if (recipient == address(0)) revert InvalidAddress();
        if (noteId >= _notes[msg.sender].length) revert InvalidNote();
        Note storage userNote = _notes[msg.sender][noteId];
        paid = _claimable(userNote);
        if (paid == 0) return 0;
        userNote.claimed += paid;
        outstandingVestingLiability -= paid;
        token.safeTransfer(recipient, paid);
        emit Redeemed(msg.sender, recipient, noteId, paid);
    }

    function note(address account, uint256 noteId) external view returns (Note memory) {
        if (noteId >= _notes[account].length) revert InvalidNote();
        return _notes[account][noteId];
    }

    function noteCount(address account) external view returns (uint256) {
        return _notes[account].length;
    }

    function claimable(address account, uint256 noteId) external view returns (uint256) {
        if (noteId >= _notes[account].length) revert InvalidNote();
        return _claimable(_notes[account][noteId]);
    }

    function _claimable(Note storage note_) private view returns (uint256) {
        uint256 vested = block.timestamp >= note_.end
            ? note_.payout
            : Math.mulDiv(note_.payout, block.timestamp - note_.start, note_.end - note_.start);
        return vested - note_.claimed;
    }
}
