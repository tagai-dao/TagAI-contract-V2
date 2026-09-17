// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {TagAITradeRouter} from "../router/TagAITradeRouter.sol";
import {ICommentBuyAdapter} from "./CommentTradeVault.sol";

interface ICommentToken {
    function listed() external view returns (bool);
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
interface ICommentLegacyWrapper is ICommentFeeWrapper {
    function buyToken(address subject, uint256 minimum, address[] calldata path, address recipient,
        uint256 deadline, address ipshare) external payable;
}
interface ICommentImportWrapper is ICommentFeeWrapper {
    function ipshare() external view returns (address);
    function nutboxTokenRatio() external view returns (uint16);
    function getImportedMarket(address token) external view returns (bool, address, address);
    function resolveQuoteToken(address token, uint8 sourceType, bytes calldata sourceData) external view returns (address);
    function buyToken(address token, uint8 sourceType, bytes calldata sourceData, uint256 minimum,
        address recipient, uint256 deadline, address subject) external payable returns (uint256);
}

/// @notice Typed routes only: V13, reviewed legacy V2, and the multi-quote imported-token wrapper.
/// Non-V13 markets require explicit administrator registration AND vault allowlisting.
/// Router/hook fees are embedded in the quoted input; do not charge them a second time in the vault.
contract CommentBuyAdapter is ICommentBuyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;
    TagAITradeRouter public immutable router;
    bytes32 public immutable approvedHookCodeHash;
    address public immutable admin;
    enum Kind { V13, LegacyV2, Imported }
    struct Market {
        Kind kind;
        address wrapper;
        address shares;
        address wrappedNative;
        uint8 sourceType;
        bytes sourceData;
        bytes32 codeHash;
        uint256 revision;
    }
    mapping(address => Market) private markets;
    event MarketConfigured(address indexed token, Kind kind, address wrapper, uint256 revision);

    constructor(address router_, address reviewedHook) {
        require(router_.code.length > 0 && reviewedHook.code.length > 0);
        router = TagAITradeRouter(payable(router_));
        approvedHookCodeHash = reviewedHook.codehash;
        admin = msg.sender;
    }

    /// Reviewed non-proxy wrapper only. Legacy paths are always [wrappedNative, token].
    function configureLegacy(address token, address wrapper, address shares, address wrappedNative) external {
        require(msg.sender == admin, "ADMIN_ONLY");
        require(token.code.length > 0 && wrapper.code.length > 0 && shares.code.length > 0 &&
            wrappedNative.code.length > 0 && ICommentToken(token).listed(), "INVALID_MARKET");
        uint256 revision = markets[token].revision + 1;
        markets[token] = Market(Kind.LegacyV2, wrapper, shares, wrappedNative, 0, "", wrapper.codehash, revision);
        emit MarketConfigured(token, Kind.LegacyV2, wrapper, revision);
    }

    /// Uses the NEW wrapper's full source descriptor, including non-native quote pools.
    /// Source targets/pools must be reviewed; never populate this from untrusted X content.
    function configureImported(address token, address wrapper, uint8 sourceType, bytes calldata sourceData) external {
        require(msg.sender == admin, "ADMIN_ONLY");
        require(token.code.length > 0 && wrapper.code.length > 0 &&
            (sourceType == 0 || sourceType == 1 || sourceType == 3), "INVALID_MARKET");
        ICommentImportWrapper w = ICommentImportWrapper(wrapper);
        address shares = w.ipshare();
        require(shares.code.length > 0, "INVALID_SHARES");
        w.resolveQuoteToken(token, sourceType, sourceData); // rejects a pool not containing this token
        uint256 revision = markets[token].revision + 1;
        markets[token] = Market(Kind.Imported, wrapper, shares, address(0), sourceType, sourceData, wrapper.codehash, revision);
        emit MarketConfigured(token, Kind.Imported, wrapper, revision);
    }

    /// Snapshot commitment prevents executing a quote after a market/fee/registry change.
    function routeContext(address token) public view returns (Kind kind, address shares, bytes32 commitment) {
        Market storage m = markets[token];
        kind = m.kind;
        if (kind == Kind.V13) {
            require(router.pump().createdTokens(token), "UNSUPPORTED_TOKEN");
            shares = router.pump().getIPShare();
            return (kind, shares, bytes32(0));
        }
        require(m.wrapper.codehash == m.codeHash, "WRAPPER_CHANGED");
        shares = m.shares;
        if (kind == Kind.LegacyV2) require(ICommentToken(token).listed(), "NOT_LISTED");
        else require(ICommentImportWrapper(m.wrapper).ipshare() == shares, "REGISTRY_CHANGED");
        commitment = keccak256(abi.encode(block.chainid, address(this), token, m,
            ICommentFeeWrapper(m.wrapper).tagaiRatio(), ICommentFeeWrapper(m.wrapper).sellsmanRatio(),
            ICommentFeeWrapper(m.wrapper).feeAddress(), outputFeeBps(token)));
        if (kind == Kind.Imported) {
            (bool registered, address community, address deployer) = ICommentImportWrapper(m.wrapper).getImportedMarket(token);
            commitment = keccak256(abi.encode(commitment, registered, community, deployer));
        }
    }

    function isValidSubject(address token, address subject) public view returns (bool) {
        (Kind kind, address shares,) = routeContext(token);
        if (subject == address(0) || !ICommentShares(shares).ipshareCreated(subject)) return false;
        // Imported wrapper deliberately pays its feeAddress directly, even if that address has shares.
        // Do not silently turn publisher IPShare attribution into a direct native transfer.
        return kind != Kind.Imported || subject != ICommentFeeWrapper(markets[token].wrapper).feeAddress();
    }

    /// Output-token protocol fee is already deducted by the wrapper, never charged again in BNB.
    function outputFeeBps(address token) public view returns (uint256) {
        Market storage m = markets[token];
        if (m.kind != Kind.Imported) return 0;
        (, address community,) = ICommentImportWrapper(m.wrapper).getImportedMarket(token);
        return community == address(0) ? 0 : ICommentImportWrapper(m.wrapper).nutboxTokenRatio();
    }

    /// Net command principal is grossed up for existing fees, never charged twice. V13 only.
    /// The reviewed listing Hook charges 30/30/30 bps. Its runtime code hash is pinned at deployment.
    function quoteInput(address token, uint256 principal) external view
        returns (uint256 gross, uint256 platformFee, uint256 subjectFee, uint256 buybackFee) {
        uint256 platformBps;
        uint256 subjectBps;
        uint256 buybackBps;
        (Kind kind,,) = routeContext(token);
        if (kind != Kind.V13) {
            ICommentFeeWrapper w = ICommentFeeWrapper(markets[token].wrapper);
            platformBps = w.tagaiRatio();
            subjectBps = w.sellsmanRatio();
        } else if (ICommentToken(token).listed()) {
            require(ICommentToken(token).listingHook().codehash == approvedHookCodeHash, "UNREVIEWED_HOOK");
            platformBps = 30; subjectBps = 30; buybackBps = 30;
        } else {
            // During anti-snipe the protocol can override publisher attribution; don't enter this window.
            require(block.timestamp >= ICommentToken(token).createdAt() + 15, "ANTI_SNIPE_WINDOW");
            (platformBps, subjectBps) = ICommentToken(token).getBuyFeeRatios();
        }
        uint256 bps = platformBps + subjectBps + buybackBps;
        require(principal > 0 && bps + outputFeeBps(token) <= 1000, "PROTOCOL_FEE_CAP");
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

    function buy(address token, address recipient, address subject, uint256 minimum, uint256 deadline, bytes calldata route)
        external payable nonReentrant returns (uint256 received) {
        require(block.timestamp <= deadline && minimum > 0 && msg.value > 0);
        (Kind kind, address shares, bytes32 commitment) = routeContext(token);
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        if (kind != Kind.V13) {
            require(route.length == 32 && abi.decode(route, (bytes32)) == commitment, "ROUTE_CHANGED");
            require(isValidSubject(token, subject), "INVALID_SUBJECT");
            Market storage m = markets[token];
            if (kind == Kind.LegacyV2) {
                address[] memory path = new address[](2);
                path[0] = m.wrappedNative; path[1] = token;
                ICommentLegacyWrapper(m.wrapper).buyToken{value: msg.value}(subject, minimum, path, recipient, deadline, shares);
            } else {
                ICommentImportWrapper(m.wrapper).buyToken{value: msg.value}(token, m.sourceType, m.sourceData,
                    minimum, recipient, deadline, subject);
            }
        } else if (ICommentToken(token).listed()) {
            TagAITradeRouter.Leg[] memory legs = abi.decode(route, (TagAITradeRouter.Leg[]));
            router.buy{value: msg.value}(token, legs, minimum, deadline, recipient, subject);
        } else {
            require(route.length == 0);
            uint256 held = IERC20(token).balanceOf(address(this));
            ICommentToken(token).buyToken{value: msg.value}(minimum, subject, 0);
            IERC20(token).safeTransfer(recipient, IERC20(token).balanceOf(address(this)) - held);
        }
        received = IERC20(token).balanceOf(recipient) - beforeBalance;
        require(received >= minimum, "MINIMUM_NOT_DELIVERED");
    }
}
