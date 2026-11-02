// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ImportHelperV2.sol";

interface IAgentImportMarket is IImportedTokenMarketRegistrar {
    function owner() external view returns (address);
    function setNutboxMarket(address token, address community, address deployer, uint16 feeBps) external;
    function setTokenNutboxFee(address token, uint16 feeBps) external;
    function updateImportedMarket(address token, address community, address deployer) external;
}

/// @notice Creates one community and atomically registers it in the ordinary and Agent wrappers.
/// @dev Activate as ordinary Wrapper registrar AND Agent Wrapper operator. The management wallet
///      configures the fixed Agent target through this helper; no arbitrary-call delegation.
contract ImportHelperV3 is ImportHelperV2 {
    IAgentImportMarket public immutable agentSwapWrapper;
    address public managementOperator;

    error UnauthorizedManagementOperator(address account);
    error InvalidWrapperConfiguration();
    error LegacyMarketNotRegistered(address token);
    error AgentMarketConflict(address token);

    event ManagementOperatorChanged(address indexed previousOperator, address indexed newOperator);
    event AgentMarketSynced(address indexed token, address indexed community, address indexed deployer);

    modifier onlyOwnerOrManagementOperator() {
        if (msg.sender != owner() && msg.sender != managementOperator) {
            revert UnauthorizedManagementOperator(msg.sender);
        }
        _;
    }

    constructor(
        address communityFactory_,
        address tradeCurationFactory_,
        address committee_,
        address hourlyTickCalculator_,
        address swapWrapper_,
        address agentSwapWrapper_,
        address managementOperator_
    ) ImportHelperV2(communityFactory_, tradeCurationFactory_, committee_, hourlyTickCalculator_, swapWrapper_) {
        if (
            agentSwapWrapper_ == swapWrapper_ || agentSwapWrapper_.code.length == 0 || managementOperator_ == address(0)
                || managementOperator_ == address(this)
        ) revert InvalidWrapperConfiguration();
        IAgentImportMarket target = IAgentImportMarket(agentSwapWrapper_);
        if (target.owner() != owner()) revert InvalidWrapperConfiguration();
        agentSwapWrapper = target;
        managementOperator = managementOperator_;
        emit ManagementOperatorChanged(address(0), managementOperator_);
    }

    function VERSION() public pure override returns (uint256) {
        return 3;
    }

    /// @notice Zero revokes wallet management. Ownership transfer retains the existing operator.
    function setManagementOperator(address newOperator) external onlyOwner {
        if (newOperator == address(this)) revert InvalidAddress();
        address previous = managementOperator;
        managementOperator = newOperator;
        emit ManagementOperatorChanged(previous, newOperator);
    }

    /// @notice Bind or correct an Agent community and set its future token-side fee (0 disables).
    function setNutboxMarket(address token, address community, address deployer, uint16 feeBps)
        external
        nonReentrant
        onlyOwnerOrManagementOperator
    {
        agentSwapWrapper.setNutboxMarket(token, community, deployer, feeBps);
    }

    function setTokenNutboxFee(address token, uint16 feeBps) external nonReentrant onlyOwnerOrManagementOperator {
        agentSwapWrapper.setTokenNutboxFee(token, feeBps);
    }

    /// @notice Agent-only registration; does not enable fees or mutate the ordinary Wrapper.
    function registerImportedToken(address token, address community, address deployer)
        external
        nonReentrant
        onlyOwnerOrManagementOperator
    {
        agentSwapWrapper.registerImportedToken(token, community, deployer);
    }

    function updateImportedMarket(address token, address community, address deployer)
        external
        nonReentrant
        onlyOwnerOrManagementOperator
    {
        agentSwapWrapper.updateImportedMarket(token, community, deployer);
    }

    /// @notice Reuse the ordinary Wrapper's historical community. Never silently replace an
    ///         existing Agent binding or reset its fees, pending rewards or injection timestamp.
    function syncAgentMarket(address token) external nonReentrant onlyOwnerOrManagementOperator {
        (bool registered, address community, address deployer) = swapWrapper.getImportedMarket(token);
        if (!registered) revert LegacyMarketNotRegistered(token);
        (bool agentRegistered, address agentCommunity, address agentDeployer) =
            agentSwapWrapper.getImportedMarket(token);
        if (agentRegistered) {
            if (community != agentCommunity || deployer != agentDeployer) revert AgentMarketConflict(token);
            return;
        }
        agentSwapWrapper.registerImportedToken(token, community, deployer);
        emit AgentMarketSynced(token, community, deployer);
    }

    function _checkImportableToken(address token) internal view override {
        super._checkImportableToken(token);
        (bool registered,,) = agentSwapWrapper.getImportedMarket(token);
        if (registered) revert TokenAlreadyImported();
    }

    function _registerMarket(address token, address community, address creator) internal override {
        super._registerMarket(token, community, creator);
        agentSwapWrapper.registerImportedToken(token, community, creator);
        emit AgentMarketSynced(token, community, creator);
    }
}
