// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ImportedTokenSwapWrapper} from "./ImportedTokenSwapWrapper.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";

/**
 * @notice Direct BSC Agent-wallet trades through V2, V3 and Pancake Infinity CL pools.
 * @dev Every buy/sell authenticates msg.sender using the Binance Handle registry and ensures
 *      its IPShare exists before moving trade funds. No tx.origin or forwarding exemption.
 *      Default fees are 20 bps platform + 20 bps referral, both in native coin. No token-side
 *      Nutbox fee can be enabled, even for a registered Community. Existing DEX/Hook fees remain.
 *      Quotes stay public and side-effect-free with respect to Handle/IPShare registration.
 */
contract AgentSwapWrapper is ImportedTokenSwapWrapper {
    address public constant HANDLE_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address private _activeSubject;
    mapping(address => bytes32) public referralHookCodeHash;

    error HandleNotRegistered(address account);
    error IPShareCreationFeeRequired(uint256 fee);
    error IPShareCreationFailed(address account);
    error NutboxFeeDisabled();
    error ReferralHookCodeChanged(address hook);
    event ReferralHookSet(address indexed hook, bool enabled, bytes32 codeHash);

    constructor(address nutboxRouter_, address feeAddress_, address ipshare_)
        ImportedTokenSwapWrapper(nutboxRouter_, feeAddress_, ipshare_)
    {
        if (HANDLE_REGISTRY.code.length == 0) revert InvalidAddress();
        nutboxTokenRatio = 0;
    }

    /// @notice Enable address-encoded referral data only for reviewed compatible Hooks.
    /// @dev Other external Hooks retain the legacy empty hookData rather than receiving an unknown ABI.
    function setReferralHook(address hook, bool enabled) external onlyOwner {
        if (hook == address(0) || enabled && hook.code.length == 0) revert InvalidAddress();
        bytes32 codeHash = enabled ? hook.codehash : bytes32(0);
        referralHookCodeHash[hook] = codeHash;
        emit ReferralHookSet(hook, enabled, codeHash);
    }

    /// @notice Retains the legacy fee-setting ABI, but the third argument must always be zero.
    function setFeeRatios(uint16 sellsmanRatio_, uint16 tagaiRatio_, uint16 nutboxTokenRatio_)
        external
        override
        onlyOwner
    {
        if (nutboxTokenRatio_ != 0) revert NutboxFeeDisabled();
        if (uint256(sellsmanRatio_) + tagaiRatio_ > MAX_TOTAL_FEE_BPS) revert InvalidFeeRatio();
        sellsmanRatio = sellsmanRatio_;
        tagaiRatio = tagaiRatio_;
        emit FeeRatiosChanged(sellsmanRatio_, tagaiRatio_, 0);
    }

    function _beforeTrade(address subject) internal override {
        if (bytes(IHandleRegistry(HANDLE_REGISTRY).handleOf(msg.sender)).length == 0) {
            revert HandleNotRegistered(msg.sender);
        }
        if (!ipshare.ipshareCreated(msg.sender)) {
            uint256 fee = ipshare.createFee();
            if (fee != 0) revert IPShareCreationFeeRequired(fee);
            // Zero value: never pay for creation out of trade principal or a prior user balance.
            // IPShare independently enforces EOA/EIP-7702 subject compatibility and pause state.
            ipshare.createShare(msg.sender);
            if (!ipshare.ipshareCreated(msg.sender)) revert IPShareCreationFailed(msg.sender);
        }
        _activeSubject = subject;
    }

    function _afterTrade() internal override {
        _activeSubject = address(0);
    }

    /// @dev TagAI listed main-pool Hooks recognize abi.encode(subject). Zero uses their creator fallback.
    function _swapHookData(address hook) internal view override returns (bytes memory) {
        bytes32 reviewed = referralHookCodeHash[hook];
        if (reviewed == bytes32(0)) return "";
        if (hook.codehash != reviewed) revert ReferralHookCodeChanged(hook);
        return abi.encode(_activeSubject);
    }

    function _tokenFeeAmounts(uint256 tokenAmount, address)
        internal
        pure
        override
        returns (uint256 amountAfterFee, uint256 nutboxFee)
    {
        return (tokenAmount, 0);
    }
}
