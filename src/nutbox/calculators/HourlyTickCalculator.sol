// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IHourlyTickCalculator.sol";
import "../../interfaces/ICommunity.sol";

/**
 * @title HourlyTickCalculator
 * @notice Hourly-bucketed reward calculator with 168-hour (7-day) linear vesting.
 *
 * Algorithm: Cumulative function F(t) + single-array binary search.
 * - inject() is O(1) append (same-hour merges into last entry)
 * - calculateReward() is O(log N) via 4 binary searches (2 per F(t) call)
 *
 * Tokens are transferred directly to the Community contract on inject.
 */
contract HourlyTickCalculator is IHourlyTickCalculator, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant VEST_WINDOW = 168; // 7 days in hours

    // ─── Custom Errors ────────────────────────────────────────────────────────
    error CommunityNotRegistered();
    error ZeroAmount();
    error OnlyFactory();
    error AlreadyRegistered();

    // ─── Events ───────────────────────────────────────────────────────────────
    event Injected(
        address indexed community,
        uint256 hourIndex,
        uint256 amount,
        uint256 totalInjectedSoFar
    );
    event CommunityRegistered(address indexed community, address token);

    // ─── Data Structures ──────────────────────────────────────────────────────
    struct Injection {
        uint256 startHour;      // Hour index when injection starts
        uint256 amount;         // Token amount (dust removed)
        uint256 cumAmount;      // Prefix sum: Σ amount from entry 0 to this entry
        uint256 cumAmountStart; // Weighted prefix sum: Σ (amount × startHour)
    }

    // ─── State Variables ──────────────────────────────────────────────────────
    address public immutable communityFactory;

    mapping(address => bool) public registered;
    mapping(address => address) public communityToken;
    mapping(address => uint256) public totalInjected;
    mapping(address => Injection[]) internal _injections;

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyFactory() {
        if (msg.sender != communityFactory) revert OnlyFactory();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _communityFactory) {
        communityFactory = _communityFactory;
    }

    // ─── ICalculator Implementation ───────────────────────────────────────────

    /// @inheritdoc ICalculator
    function setDistributionEra(
        address community,
        bytes calldata /* policy */
    ) external onlyFactory returns (bool) {
        if (registered[community]) revert AlreadyRegistered();

        registered[community] = true;
        communityToken[community] = ICommunity(community).getCommunityToken();

        emit CommunityRegistered(community, communityToken[community]);
        return true;
    }

    /// @inheritdoc ICalculator
    function rewardHead() external view returns (uint256) {
        return (block.timestamp / 3600) * 3600;
    }

    /// @inheritdoc ICalculator
    function calculateReward(
        address community,
        uint256 lastCursor,
        uint256 head
    ) external view returns (uint256) {
        if (head <= lastCursor) return 0;

        uint256 a = lastCursor / 3600; // Convert to hour index
        uint256 b = head / 3600;

        return _cumulativeReward(community, b) - _cumulativeReward(community, a);
    }

    /// @inheritdoc ICalculator
    function getCurrentRewardRate(address community) external view returns (uint256) {
        Injection[] storage injs = _injections[community];
        if (injs.length == 0) return 0;

        uint256 currentHour = block.timestamp / 3600;
        uint256 totalRate = 0;

        // Find all active injections: startHour < currentHour AND startHour + 168 > currentHour
        // Active means: startHour < currentHour (has started) and currentHour < startHour + 168 (not ended)
        for (uint256 i = injs.length; i > 0; ) {
            unchecked { --i; }
            uint256 sh = injs[i].startHour;
            // If startHour >= currentHour, injection hasn't started contributing yet
            if (sh >= currentHour) continue;
            // If startHour + 168 <= currentHour, injection fully ended; earlier ones also ended
            if (sh + VEST_WINDOW <= currentHour) break;
            // Active injection
            totalRate += injs[i].amount / VEST_WINDOW;
        }

        return totalRate;
    }

    /// @inheritdoc ICalculator
    function getStartCursor(address community) external view returns (uint256) {
        Injection[] storage injs = _injections[community];
        if (injs.length == 0) return 0;
        return injs[0].startHour * 3600; // Convert back to seconds
    }

    // ─── IHourlyTickCalculator Implementation ─────────────────────────────────

    /// @inheritdoc IHourlyTickCalculator
    function inject(address community, uint256 amount) external nonReentrant {
        if (!registered[community]) revert CommunityNotRegistered();
        if (amount == 0) revert ZeroAmount();

        address token = communityToken[community];
        // Transfer tokens directly to the community contract
        IERC20(token).safeTransferFrom(msg.sender, community, amount);

        uint256 H = block.timestamp / 3600; // Current hour index

        Injection[] storage injs = _injections[community];

        if (injs.length > 0 && injs[injs.length - 1].startHour == H) {
            // Same hour: merge into last entry
            Injection storage last = injs[injs.length - 1];
            last.amount += amount;
            last.cumAmount += amount;
            last.cumAmountStart += amount * H;
        } else {
            // New entry
            uint256 prevCumAmount = injs.length > 0
                ? injs[injs.length - 1].cumAmount
                : 0;
            uint256 prevCumAmountStart = injs.length > 0
                ? injs[injs.length - 1].cumAmountStart
                : 0;

            injs.push(
                Injection({
                    startHour: H,
                    amount: amount,
                    cumAmount: prevCumAmount + amount,
                    cumAmountStart: prevCumAmountStart + amount * H
                })
            );
        }

        totalInjected[community] += amount;
        emit Injected(community, H, amount, totalInjected[community]);
    }

    /// @inheritdoc IHourlyTickCalculator
    function getHourlyRewards(
        address community,
        uint256 startTimestamp,
        uint256 numHours
    ) external view returns (uint256[] memory rewards) {
        rewards = new uint256[](numHours);
        uint256 startHourIdx = startTimestamp / 3600;

        // Reuse previous F(t) to avoid redundant binary searches
        uint256 prevF = _cumulativeReward(community, startHourIdx);

        for (uint256 i = 0; i < numHours; i++) {
            uint256 nextF = _cumulativeReward(community, startHourIdx + i + 1);
            rewards[i] = nextF - prevF;
            prevF = nextF;
        }
    }

    // ─── Internal Functions ───────────────────────────────────────────────────

    /**
     * @dev Compute cumulative reward F(t) up to hour index `t`.
     *
     * F(t) = Σ amount_i (for all startHour_i + 168 <= t, fully ended)
     *       + Σ [amount_i × (t - startHour_i) / 168] (for all startHour_i < t <= startHour_i + 168)
     *
     * Uses 2 binary searches + prefix sums for O(log N) computation.
     */
    function _cumulativeReward(address community, uint256 t) internal view returns (uint256) {
        Injection[] storage injs = _injections[community];
        if (injs.length == 0) return 0;

        // Binary search 1: endIdx = last entry where startHour <= t - 168
        // These injections have fully ended, contributing their entire amount
        uint256 F1 = 0;
        int256 endIdx;
        if (t >= VEST_WINDOW) {
            endIdx = int256(_upperBound(injs, t - VEST_WINDOW)) - 1;
        } else {
            endIdx = -1;
        }
        if (endIdx >= 0) {
            F1 = injs[uint256(endIdx)].cumAmount;
        }

        // Binary search 2: curIdx = last entry where startHour < t
        // i.e., last entry where startHour <= t - 1
        int256 curIdx;
        if (t > 0) {
            curIdx = int256(_upperBound(injs, t - 1)) - 1;
        } else {
            curIdx = -1;
        }

        // Entries in (endIdx, curIdx] are in-progress
        uint256 F2 = 0;
        if (curIdx > endIdx) {
            uint256 sumAmount = injs[uint256(curIdx)].cumAmount
                - (endIdx >= 0 ? injs[uint256(endIdx)].cumAmount : 0);
            uint256 sumAmountStart = injs[uint256(curIdx)].cumAmountStart
                - (endIdx >= 0 ? injs[uint256(endIdx)].cumAmountStart : 0);

            // F2 = (t × sumAmount - sumAmountStart) / 168
            F2 = (t * sumAmount - sumAmountStart) / VEST_WINDOW;
        }

        return F1 + F2;
    }

    /**
     * @dev Standard upper_bound: returns the index of the first entry with startHour > target.
     *      If all entries have startHour <= target, returns injs.length.
     *      If all entries have startHour > target, returns 0.
     */
    function _upperBound(
        Injection[] storage injs,
        uint256 target
    ) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = injs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (injs[mid].startHour <= target) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
}
