// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IToken {
    // ─── Errors ──────────────────────────────────────────────────────────────────

    error TokenNotListed();
    error TokenListed();
    error IPShareNotCreated();
    error OnlyIPShareOwner();
    error IPShareAlreadySet();
    error ZeroIPShareSubject();
    error TokenInitialized();
    error ClaimOrderExist();
    error InvalidClaimAmount();
    error OutOfSlippage();
    error InsufficientFund();
    error RefundFail();
    error CostFeeFail();
    error DustIssue();
    /// @dev 上市动作（曲线买满 / LP 注入）在 anti-snipe 窗口内被禁止。
    error ListingDisabledDuringAntiSnipe();

    // ─── Events ──────────────────────────────────────────────────────────────────

    event Trade(
        address indexed buyer,
        address indexed sellsman,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tiptagFee,
        uint256 sellsmanFee
    );

    event TokenListedToDex(address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96);

    event AntiSnipeInjected(
        address indexed token,
        address indexed community,
        uint256 ethUsed,
        uint256 tokensPurchased
    );

    /// @notice Emitted when the community token fee subject (IPShare owner) is transferred.
    event IPShareSubjectTransferred(
        address indexed previousSubject,
        address indexed newSubject
    );

    /// @notice 领取上市 LP 费时发出；callerReward 为给调用者的 BNB 奖励。
    event ListingFeesCollected(
        address indexed collector,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 callerReward
    );

    // ─── View Functions ──────────────────────────────────────────────────────────

    function nutboxCommunity() external view returns (address);

    function nutboxSocialPool() external view returns (address);

    function NUTBOX_ALLOCATION() external view returns (uint256);

    function listed() external view returns (bool);

    function getIPShare() external view returns (address);

    function ipshareSubject() external view returns (address);

    /// @notice 上市时永久绑定的 hook 地址。
    function listingHook() external view returns (address);

    /// @notice Permissionless 领取上市 LP 费。返回 BNB 与 Token 领取量。
    function collectFees() external returns (uint256 ethAmount, uint256 tokenAmount);
}
