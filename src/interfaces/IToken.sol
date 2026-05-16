// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IToken {
    // ─── Errors ──────────────────────────────────────────────────────────────────

    error TokenNotListed();
    error TokenListed();
    error IPShareNotCreated();
    error TokenInitialized();
    error ClaimOrderExist();
    error InvalidClaimAmount();
    error OutOfSlippage();
    error InsufficientFund();
    error RefundFail();
    error CostFeeFail();
    error DustIssue();

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

    // ─── View Functions ──────────────────────────────────────────────────────────

    function nutboxCommunity() external view returns (address);

    function nutboxSocialPool() external view returns (address);

    function NUTBOX_ALLOCATION() external view returns (uint256);

    function listed() external view returns (bool);

    function getIPShare() external view returns (address);

    function ipshareSubject() external view returns (address);
}
