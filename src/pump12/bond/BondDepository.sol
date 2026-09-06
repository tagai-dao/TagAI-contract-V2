// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IHookBond {
    function validTWAP(PoolId id) external view returns (uint256);
    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256 received);
}

interface IBurnNetBond {
    function anchor() external view returns (uint256);
}

interface ITokenBond {
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ITreasuryBond {
    function mintByBond(address to, uint256 amount) external;
}

/// @title BondDepository
/// @notice Per-token USDG reserve bonds with immutable discount, caps and two-day vesting.
contract BondDepository is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant RAW_USDG_TO_TOKEN_WAD_SCALE = 1e30;
    uint16 public constant DISCOUNT_BPS = 300;
    uint16 public constant EPOCH_CAP_BPS = 25;
    uint16 public constant PERIOD_CAP_BPS = 500;
    uint40 public constant EPOCH_LENGTH = 8 hours;
    uint40 public constant PERIOD_LENGTH = 30 days;
    uint40 public constant VESTING_LENGTH = 2 days;

    error AlreadyInitialized();
    error InvalidInitialization();
    error InvalidAmount();
    error InvalidAddress();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error EpochCapExceeded();
    error PeriodCapExceeded();
    error UnsupportedUsdGTransfer();
    error InvalidNote();

    struct Note {
        uint256 payout;
        uint256 claimed;
        uint40 start;
        uint40 end;
    }

    struct Capacity {
        uint64 index;
        uint256 startSupply;
        uint256 used;
        bool initialized;
    }

    bool public initialized;
    IERC20 public usdg;
    ITokenBond public token;
    IHookBond public hook;
    IBurnNetBond public burnNet;
    ITreasuryBond public treasury;
    PoolId public poolId;
    uint40 public listTime;
    Capacity public epochCapacity;
    Capacity public periodCapacity;
    mapping(address account => Note[] notes) private _notes;

    event BondInitialized(address indexed token, PoolId indexed poolId, address indexed treasury);
    event BondCreated(
        address indexed caller,
        address indexed recipient,
        uint256 indexed noteId,
        uint256 usdgRaw,
        uint256 payout,
        uint256 price
    );
    event BondRedeemed(address indexed owner, address indexed recipient, uint256 indexed noteId, uint256 amount);

    constructor() {
        initialized = true;
    }

    function initialize(
        address usdg_,
        address token_,
        address hook_,
        address burnNet_,
        address treasury_,
        PoolId poolId_,
        uint40 listTime_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            usdg_.code.length == 0 || token_.code.length == 0 || hook_.code.length == 0 || burnNet_.code.length == 0
                || treasury_.code.length == 0 || PoolId.unwrap(poolId_) == bytes32(0) || listTime_ != block.timestamp
        ) revert InvalidInitialization();
        initialized = true;
        usdg = IERC20(usdg_);
        token = ITokenBond(token_);
        hook = IHookBond(hook_);
        burnNet = IBurnNetBond(burnNet_);
        treasury = ITreasuryBond(treasury_);
        poolId = poolId_;
        listTime = listTime_;
        emit BondInitialized(token_, poolId_, treasury_);
    }

    function bondPrice() public view returns (uint256 price) {
        uint256 discounted = Math.mulDiv(hook.validTWAP(poolId), BPS - DISCOUNT_BPS, BPS);
        uint256 currentAnchor = burnNet.anchor();
        return discounted > currentAnchor ? discounted : currentAnchor;
    }

    function deposit(uint256 usdgAmountRaw, uint256 maxPriceWad, address recipient)
        external
        nonReentrant
        returns (uint256 noteId, uint256 payout)
    {
        if (usdgAmountRaw == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidAddress();
        uint256 price = bondPrice();
        if (price > maxPriceWad) revert PriceAboveMax(price, maxPriceWad);
        payout = Math.mulDiv(usdgAmountRaw, RAW_USDG_TO_TOKEN_WAD_SCALE, price);
        if (payout == 0) revert InvalidAmount();
        _consumeCapacity(payout);

        uint256 beforeBalance = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), usdgAmountRaw);
        if (usdg.balanceOf(address(this)) - beforeBalance != usdgAmountRaw) revert UnsupportedUsdGTransfer();
        usdg.forceApprove(address(hook), usdgAmountRaw);
        if (hook.addPendingUSDG(poolId, usdgAmountRaw) != usdgAmountRaw) revert UnsupportedUsdGTransfer();

        treasury.mintByBond(address(this), payout);
        noteId = _notes[recipient].length;
        _notes[recipient].push(
            Note({
                payout: payout,
                claimed: 0,
                start: uint40(block.timestamp),
                end: uint40(block.timestamp + VESTING_LENGTH)
            })
        );
        emit BondCreated(msg.sender, recipient, noteId, usdgAmountRaw, payout, price);
    }

    function redeem(uint256 noteId, address recipient) external nonReentrant returns (uint256 paid) {
        if (recipient == address(0)) revert InvalidAddress();
        if (noteId >= _notes[msg.sender].length) revert InvalidNote();
        Note storage userNote = _notes[msg.sender][noteId];
        paid = _claimable(userNote);
        if (paid == 0) return 0;
        userNote.claimed += paid;
        if (!token.transfer(recipient, paid)) revert UnsupportedUsdGTransfer();
        emit BondRedeemed(msg.sender, recipient, noteId, paid);
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

    function _consumeCapacity(uint256 payout) private {
        uint64 epochIndex = uint64((block.timestamp - listTime) / EPOCH_LENGTH);
        uint64 periodIndex = uint64((block.timestamp - listTime) / PERIOD_LENGTH);
        uint256 supply = token.totalSupply();
        _refresh(epochCapacity, epochIndex, supply);
        _refresh(periodCapacity, periodIndex, supply);
        if (epochCapacity.used + payout > Math.mulDiv(epochCapacity.startSupply, EPOCH_CAP_BPS, BPS)) {
            revert EpochCapExceeded();
        }
        if (periodCapacity.used + payout > Math.mulDiv(periodCapacity.startSupply, PERIOD_CAP_BPS, BPS)) {
            revert PeriodCapExceeded();
        }
        epochCapacity.used += payout;
        periodCapacity.used += payout;
    }

    function _refresh(Capacity storage capacity, uint64 index, uint256 supply) private {
        if (!capacity.initialized || capacity.index != index) {
            capacity.initialized = true;
            capacity.index = index;
            capacity.startSupply = supply;
            capacity.used = 0;
        }
    }

    function _claimable(Note storage note_) private view returns (uint256) {
        uint256 vested = block.timestamp >= note_.end
            ? note_.payout
            : Math.mulDiv(note_.payout, block.timestamp - note_.start, note_.end - note_.start);
        return vested - note_.claimed;
    }
}
