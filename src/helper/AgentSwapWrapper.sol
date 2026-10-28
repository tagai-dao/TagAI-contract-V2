// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ImportedTokenSwapWrapper} from "./ImportedTokenSwapWrapper.sol";
import {IHandleRegistry} from "../interfaces/IHandleRegistry.sol";
import {ICommunity} from "../interfaces/ICommunity.sol";

/**
 * @notice Direct BSC Agent-wallet trades through V2, V3 and Pancake Infinity CL pools.
 * @dev Every buy/sell authenticates msg.sender using the Binance Handle registry and ensures
 *      its IPShare exists before moving trade funds. No tx.origin or forwarding exemption.
 *      Default fees are 20 bps platform + 20 bps referral, both in native coin.
 *      Nutbox fees default to zero and may be enabled per token by the owner or its operator. Existing DEX/Hook fees remain.
 *      Quotes stay public and side-effect-free with respect to Handle/IPShare registration.
 */
contract AgentSwapWrapper is ImportedTokenSwapWrapper {
    address public constant HANDLE_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address private _activeSubject;
    mapping(address => bytes32) public referralHookCodeHash;
    mapping(address => uint16) public tokenNutboxFeeBps;
    address public operator;

    error HandleNotRegistered(address account);
    error IPShareCreationFeeRequired(uint256 fee);
    error IPShareCreationFailed(address account);
    error UsePerTokenNutboxConfig();
    error ReferralHookCodeChanged(address hook);
    error UnauthorizedOperator(address account);
    event ReferralHookSet(address indexed hook, bool enabled, bytes32 codeHash);
    event NutboxMarketConfigured(address indexed token, address indexed community, address deployer, uint16 feeBps);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert UnauthorizedOperator(msg.sender);
        _;
    }

    constructor(address nutboxRouter_, address feeAddress_, address ipshare_)
        ImportedTokenSwapWrapper(nutboxRouter_, feeAddress_, ipshare_)
    {
        if (HANDLE_REGISTRY.code.length == 0) revert InvalidAddress();
        nutboxTokenRatio = 0;
    }

    /// @notice Delegate Nutbox market/fee configuration. Zero revokes the current operator.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(this)) revert InvalidAddress();
        address previousOperator = operator;
        operator = newOperator;
        emit OperatorChanged(previousOperator, newOperator);
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
        if (nutboxTokenRatio_ != 0) revert UsePerTokenNutboxConfig();
        if (uint256(sellsmanRatio_) + tagaiRatio_ > MAX_TOTAL_FEE_BPS) revert InvalidFeeRatio();
        sellsmanRatio = sellsmanRatio_;
        tagaiRatio = tagaiRatio_;
        emit FeeRatiosChanged(sellsmanRatio_, tagaiRatio_, 0);
    }

    /// @notice Atomically bind a token to its Nutbox Community and set its token-side fee (0 disables).
    /// @dev Pending rewards must be flushed before changing Community. Disabling keeps old rewards flushable.
    function setNutboxMarket(address token, address community, address deployer, uint16 feeBps)
        external
        onlyOwnerOrOperator
    {
        if (feeBps > MAX_TOTAL_FEE_BPS) revert InvalidFeeRatio();
        (bool registered,,) = getImportedMarket(token);
        if (registered) updateImportedMarket(token, community, deployer);
        else registerImportedToken(token, community, deployer);
        _setTokenNutboxFee(token, community, deployer, feeBps);
    }

    /// @notice Change only the fee, retaining the binding and any already accrued rewards.
    function setTokenNutboxFee(address token, uint16 feeBps) external onlyOwnerOrOperator {
        (bool registered, address community, address deployer) = getImportedMarket(token);
        if (!registered) revert MarketNotRegistered();
        _setTokenNutboxFee(token, community, deployer, feeBps);
    }

    function _setTokenNutboxFee(address token, address community, address deployer, uint16 feeBps) private {
        if (feeBps > MAX_TOTAL_FEE_BPS) revert InvalidFeeRatio();
        tokenNutboxFeeBps[token] = feeBps;
        emit NutboxMarketConfigured(token, community, deployer, feeBps);
    }

    /// @dev Registrars cannot add fee bindings to this Agent entry point. Registration alone leaves fee at zero.
    function registerImportedToken(address token, address community, address deployer)
        public
        override
        onlyOwnerOrOperator
    {
        _validateNutboxCommunity(token, community);
        _registerImportedToken(token, community, deployer);
    }

    function updateImportedMarket(address token, address community, address deployer)
        public
        override
        onlyOwnerOrOperator
    {
        _validateNutboxCommunity(token, community);
        _updateImportedMarket(token, community, deployer);
    }

    function _validateNutboxCommunity(address token, address community) private view {
        if (token.code.length == 0 || community.code.length == 0) revert InvalidMarket();
        if (
            ICommunity(community).getCommunityToken() != token
                || ICommunity(community).rewardCalculator().code.length == 0
        ) {
            revert InvalidMarket();
        }
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

    function _tokenFeeAmounts(address token, uint256 tokenAmount, address community)
        internal
        view
        override
        returns (uint256 amountAfterFee, uint256 nutboxFee)
    {
        if (community == address(0)) return (tokenAmount, 0);
        nutboxFee = tokenAmount * tokenNutboxFeeBps[token] / BPS_DENOMINATOR;
        amountAfterFee = tokenAmount - nutboxFee;
    }
}
