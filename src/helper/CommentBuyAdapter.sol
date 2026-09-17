// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {TagAITradeRouter} from "../router/TagAITradeRouter.sol";
import {ICommentBuyAdapter} from "./CommentTradeVault.sol";

interface ICommentToken {
    function buyToken(uint256 expected, address subject, uint16 slippage) external payable returns (uint256);
    function listingHook() external view returns (address);
    function createdAt() external view returns (uint256);
    function getBuyFeeRatios() external view returns (uint256, uint256);
}

interface ICommentShares { function ipshareCreated(address) external view returns (bool); }
interface ICommentFeeWrapper {
    function feeAddress() external view returns (address);
    function sellsmanRatio() external view returns (uint16);
    function tagaiRatio() external view returns (uint16);
}
interface ICommentImportWrapper is ICommentFeeWrapper {
    function ipshare() external view returns (address);
    function nutboxTokenRatio() external view returns (uint16);
    function getImportedMarket(address token) external view returns (bool, address, address);
    function resolveQuoteToken(address token, uint8 sourceType, bytes calldata sourceData) external view returns (address);
    function buyToken(address token, uint8 sourceType, bytes calldata sourceData, uint256 minimum,
        address recipient, uint256 deadline, address subject) external payable returns (uint256);
}

/// @notice Permissionless buy dispatcher. Each call spends only its attached BNB.
/// Executor selects the trade kind off-chain and submits through CommentTradeVault.execute.
/// 0 = bonding-curve inner, 1 = V13 listed main pool, 2 = imported/external wrapper DEX.
/// Router/hook/wrapper fees are embedded in the quoted input; do not charge them twice in the vault.
contract CommentBuyAdapter is ICommentBuyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Kind { Inner, V13Main, External } 

    TagAITradeRouter public immutable router;
    ICommentImportWrapper public immutable wrapper;
    bytes32 public immutable approvedHookCodeHash;

    constructor(address router_, address reviewedHook, address wrapper_) {
        require(router_.code.length > 0 && reviewedHook.code.length > 0 && wrapper_.code.length > 0);
        router = TagAITradeRouter(payable(router_));
        approvedHookCodeHash = reviewedHook.codehash;
        wrapper = ICommentImportWrapper(wrapper_);
    }

    function isValidSubject(address, address subject) public view returns (bool) {
        address shares = wrapper.ipshare();
        if (subject == address(0) || !ICommentShares(shares).ipshareCreated(subject)) return false;
        // Wrapper pays feeAddress in native if IPShare attribution is omitted. Do not let the
        // publisher address collapse into that direct transfer.
        return subject != wrapper.feeAddress();
    }

    /// Output-token protocol fee is already deducted by the wrapper, never charged again in BNB.
    function outputFeeBps(address token, uint8 kind) public view returns (uint256) {
        if (kind != uint8(Kind.External)) return 0;
        (, address community,) = wrapper.getImportedMarket(token);
        return community == address(0) ? 0 : wrapper.nutboxTokenRatio();
    }

    /// Net command principal is grossed up for the fees of the executor-selected kind.
    function quoteInput(address token, uint256 principal, uint8 kind) public view
        returns (uint256 gross, uint256 platformFee, uint256 subjectFee, uint256 buybackFee) {
        uint256 platformBps;
        uint256 subjectBps;
        uint256 buybackBps;
        if (kind == uint8(Kind.Inner)) {
            // During anti-snipe the protocol can override publisher attribution; don't enter this window.
            require(block.timestamp >= ICommentToken(token).createdAt() + 15, "ANTI_SNIPE_WINDOW");
            (platformBps, subjectBps) = ICommentToken(token).getBuyFeeRatios();
        } else if (kind == uint8(Kind.V13Main)) {
            require(ICommentToken(token).listingHook().codehash == approvedHookCodeHash, "UNREVIEWED_HOOK");
            platformBps = 30; subjectBps = 30; buybackBps = 30;
        } else if (kind == uint8(Kind.External)) {
            platformBps = wrapper.tagaiRatio();
            subjectBps = wrapper.sellsmanRatio();
        } else {
            revert("INVALID_KIND");
        }
        uint256 bps = platformBps + subjectBps + buybackBps;
        require(principal > 0 && bps + outputFeeBps(token, kind) <= 1000, "PROTOCOL_FEE_CAP");
        gross = (principal * 10000 + (10000 - bps) - 1) / (10000 - bps);
        platformFee = gross * platformBps / 10000;
        subjectFee = gross * subjectBps / 10000;
        buybackFee = gross * buybackBps / 10000;
        // At most 3 wei of gross-up rounding goes to liquidity, and is disclosed separately.
        require(gross >= principal + platformFee + subjectFee + buybackFee &&
            gross - principal - platformFee - subjectFee - buybackFee <= 3, "ROUNDING");
    }

    // Refunds must not become unaccounted principal. Partial-fill routes are rejected atomically.
    receive() external payable { revert("PARTIAL_FILL_UNSUPPORTED"); }

    function buy(address token, address recipient, address subject, uint256 minimum, uint256 deadline, uint8 kind, bytes calldata route)
        external payable nonReentrant returns (uint256 received) {
        require(block.timestamp <= deadline && minimum > 0 && msg.value > 0);
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        if (kind == uint8(Kind.Inner)) {
            require(route.length == 0, "INNER_ROUTE");
            require(block.timestamp >= ICommentToken(token).createdAt() + 15, "ANTI_SNIPE_WINDOW");
            uint256 held = IERC20(token).balanceOf(address(this));
            ICommentToken(token).buyToken{value: msg.value}(minimum, subject, 0);
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)) - held);
        } else if (kind == uint8(Kind.V13Main)) {
            TagAITradeRouter.Leg[] memory legs = abi.decode(route, (TagAITradeRouter.Leg[]));
            require(legs.length == 1 && legs[0].routeIndex == 0, "MAIN_POOL_ONLY");
            router.buy{value: msg.value}(token, legs, minimum, deadline, recipient, subject);
        } else if (kind == uint8(Kind.External)) {
            (uint8 sourceType, bytes memory sourceData) = abi.decode(route, (uint8, bytes));
            require(sourceType == 0 || sourceType == 1 || sourceType == 3, "INVALID_MARKET");
            wrapper.resolveQuoteToken(token, sourceType, sourceData);
            require(isValidSubject(token, subject), "INVALID_SUBJECT");
            wrapper.buyToken{value: msg.value}(token, sourceType, sourceData, minimum, recipient, deadline, subject);
        } else {
            revert("INVALID_KIND");
        }
        received = IERC20(token).balanceOf(recipient) - beforeBalance;
        require(received >= minimum, "MINIMUM_NOT_DELIVERED");
    }
}
