// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IHookPTeam {
    function validTWAP(PoolId id) external view returns (uint256);
}
interface IBurnNetPTeam {
    function anchor() external view returns (uint256);
    function mintingAvailable() external view returns (bool);
}

interface ITreasuryPTeam {
    function mintByPTeam(address to, uint256 amount) external;
}

interface IIndexBondDeskInventory {
    function canReceiveInventory(uint256 amount, uint256 supplyAfterMint) external view returns (bool);
}

/// @title PTeam
/// @notice Zero-strike team issuance whose output is forced into the per-token IndexBondDesk.
contract PTeam is ReentrancyGuard {
    uint256 private constant BPS = 10_000;
    uint16 public constant CUMULATIVE_CAP_BPS = 1_000;
    uint16 public constant DESK_INVENTORY_CAP_BPS = 50;
    uint16 public constant MIN_PREMIUM_BPS = 12_000;
    uint40 public constant ACTIVATION_DELAY = 24 hours;

    error AlreadyInitialized();
    error InvalidInitialization();
    error OnlyHolder();
    error NotActive();
    error ExceedsCumulativeCap();
    error ExceedsDeskInventoryCap();

    bool public initialized;
    IERC20 public token;
    address public holder;
    ITreasuryPTeam public treasury;
    IIndexBondDeskInventory public desk;
    IHookPTeam public hook;
    IBurnNetPTeam public burnNet;
    PoolId public poolId;
    uint40 public activationTime;
    uint256 public exercised;

    event PTeamInitialized(address indexed token, address indexed holder, address indexed desk);
    event Exercised(address indexed holder, uint256 amount, uint256 cumulativeExercised, uint256 twap);

    constructor() {
        initialized = true;
    }

    function initialize(
        address token_,
        address holder_,
        address treasury_,
        address desk_,
        address hook_,
        address burnNet_,
        PoolId poolId_,
        uint40 listTime_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            token_.code.length == 0 || holder_ == address(0) || treasury_.code.length == 0 || desk_.code.length == 0
                || hook_.code.length == 0 || burnNet_.code.length == 0 || PoolId.unwrap(poolId_) == bytes32(0)
                || listTime_ != block.timestamp
        ) revert InvalidInitialization();
        initialized = true;
        token = IERC20(token_);
        holder = holder_;
        treasury = ITreasuryPTeam(treasury_);
        desk = IIndexBondDeskInventory(desk_);
        hook = IHookPTeam(hook_);
        burnNet = IBurnNetPTeam(burnNet_);
        poolId = poolId_;
        activationTime = listTime_ + ACTIVATION_DELAY;
        emit PTeamInitialized(token_, holder_, desk_);
    }

    function exercisableNow() public view returns (uint256) {
        uint256 cap = Math.mulDiv(token.totalSupply(), CUMULATIVE_CAP_BPS, BPS);
        return cap > exercised ? cap - exercised : 0;
    }

    function exercise(uint256 amount) external nonReentrant {
        if (msg.sender != holder) revert OnlyHolder();
        if (amount == 0 || block.timestamp < activationTime || !burnNet.mintingAvailable()) revert NotActive();
        if (amount > exercisableNow()) revert ExceedsCumulativeCap();
        uint256 twap = hook.validTWAP(poolId);
        if (twap < Math.mulDiv(burnNet.anchor(), MIN_PREMIUM_BPS, BPS)) revert NotActive();

        uint256 supplyAfterMint = token.totalSupply() + amount;
        if (!desk.canReceiveInventory(amount, supplyAfterMint)) revert ExceedsDeskInventoryCap();
        exercised += amount;
        treasury.mintByPTeam(address(desk), amount);
        emit Exercised(holder, amount, exercised, twap);
    }
}
