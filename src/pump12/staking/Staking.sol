// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {SToken} from "./SToken.sol";

interface IDistributorStaking {
    function distribute() external returns (uint256 minted);
}

/// @title Staking
/// @notice Immediate 1:1 staking with one permissionless rebase step per eight-hour epoch.
contract Staking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant EPOCH_LENGTH = 8 hours;
    uint256 public constant WARMUP_EPOCHS = 0;

    error AlreadyInitialized();
    error InvalidInitialization();
    error InvalidAmount();
    error InvalidAddress();

    struct EpochState {
        uint64 length;
        uint64 number;
        uint64 end;
        uint256 distribute;
    }

    bool public initialized;
    IERC20 public token;
    SToken public sToken;
    IDistributorStaking public distributor;
    EpochState private _epoch;

    event StakingInitialized(address indexed token, address indexed sToken, address indexed distributor, uint64 end);
    event Staked(address indexed caller, address indexed recipient, uint256 amount);
    event Unstaked(address indexed caller, address indexed recipient, uint256 amount);
    event Rebased(uint64 indexed epoch, uint256 distributed, uint256 queued, uint64 nextEnd);

    constructor() {
        initialized = true;
    }

    function initialize(address token_, address sToken_, address distributor_, uint40 listTime_) external {
        if (initialized) revert AlreadyInitialized();
        if (token_.code.length == 0 || sToken_.code.length == 0 || distributor_.code.length == 0) {
            revert InvalidInitialization();
        }
        if (listTime_ != block.timestamp) revert InvalidInitialization();
        initialized = true;
        token = IERC20(token_);
        sToken = SToken(sToken_);
        distributor = IDistributorStaking(distributor_);
        _epoch = EpochState({length: EPOCH_LENGTH, number: 1, end: uint64(listTime_ + EPOCH_LENGTH), distribute: 0});
        emit StakingInitialized(token_, sToken_, distributor_, _epoch.end);
    }

    function epoch() external view returns (uint64 length, uint64 number, uint64 end, uint256 distribute) {
        EpochState memory state = _epoch;
        return (state.length, state.number, state.end, state.distribute);
    }

    function stake(address to, uint256 amount) external nonReentrant returns (uint256) {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        _rebaseIfDue();
        token.safeTransferFrom(msg.sender, address(this), amount);
        sToken.mint(to, amount);
        emit Staked(msg.sender, to, amount);
        return amount;
    }

    function unstake(address to, uint256 amount) external nonReentrant returns (uint256) {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        _rebaseIfDue();
        sToken.burn(msg.sender, amount);
        token.safeTransfer(to, amount);
        emit Unstaked(msg.sender, to, amount);
        return amount;
    }

    function rebase() external nonReentrant returns (uint256 distributed, uint256 queued) {
        return _rebaseIfDue();
    }

    function totalStaked() external view returns (uint256) {
        return sToken.totalSupply();
    }

    function _rebaseIfDue() private returns (uint256 distributed, uint256 queued) {
        EpochState storage state = _epoch;
        if (block.timestamp < state.end) return (0, state.distribute);

        if (sToken.totalSupply() != 0 && state.distribute != 0) {
            distributed = state.distribute;
            state.distribute = 0;
            sToken.rebase(distributed, state.number);
        }
        uint64 completedEpoch = state.number;
        state.end += state.length;
        ++state.number;
        queued = distributor.distribute();
        state.distribute += queued;
        emit Rebased(completedEpoch, distributed, queued, state.end);
    }
}
