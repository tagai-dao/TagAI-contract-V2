// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IToken12Treasury {
    function mint(address to, uint256 amount) external;
}

interface IBurnNetTreasury {
    function mintingAvailable() external view returns (bool);
    function snapshotAt() external view returns (uint40);
}

/// @title Treasury
/// @notice Per-token immutable mint gateway. Layer 3 authorizes only its fixed Distributor.
contract Treasury {
    error AlreadyInitialized();
    error InvalidInitialization();
    error OnlyDistributor();
    error OnlyBond();
    error OnlyPremium();
    error OnlyPTeam();
    error MintingFrozen();
    error SameBlockAsPoke();
    error InvalidAmount();

    bool public initialized;
    address public token;
    address public burnNet;
    address public distributor;
    address public bondDepository;
    address public premiumSeller;
    address public pTeam;
    uint256 public mintedByDistributor;
    uint256 public mintedByBond;
    uint256 public mintedByPremium;
    uint256 public mintedByPTeam;

    event TreasuryInitialized(address indexed token, address indexed burnNet, address indexed distributor);
    event TokenMinted(address indexed module, address indexed to, uint256 amount);

    constructor() {
        initialized = true;
    }

    function initialize(
        address token_,
        address burnNet_,
        address distributor_,
        address bond_,
        address premium_,
        address pTeam_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            token_.code.length == 0 || burnNet_.code.length == 0 || distributor_.code.length == 0
                || bond_.code.length == 0 || premium_.code.length == 0 || pTeam_.code.length == 0
        ) {
            revert InvalidInitialization();
        }
        initialized = true;
        token = token_;
        burnNet = burnNet_;
        distributor = distributor_;
        bondDepository = bond_;
        premiumSeller = premium_;
        pTeam = pTeam_;
        emit TreasuryInitialized(token_, burnNet_, distributor_);
    }

    function mintByDistributor(address to, uint256 amount) external {
        if (msg.sender != distributor) revert OnlyDistributor();
        mintedByDistributor += amount;
        _mint(to, amount);
    }

    function mintByBond(address to, uint256 amount) external {
        if (msg.sender != bondDepository) revert OnlyBond();
        mintedByBond += amount;
        _mint(to, amount);
    }

    function mintByPremium(address to, uint256 amount) external {
        if (msg.sender != premiumSeller) revert OnlyPremium();
        mintedByPremium += amount;
        _mint(to, amount);
    }

    function mintByPTeam(address to, uint256 amount) external {
        if (msg.sender != pTeam) revert OnlyPTeam();
        mintedByPTeam += amount;
        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) private {
        if (to == address(0) || amount == 0) revert InvalidAmount();
        IBurnNetTreasury burnNet_ = IBurnNetTreasury(burnNet);
        if (!burnNet_.mintingAvailable()) revert MintingFrozen();
        uint40 snapshotTime = burnNet_.snapshotAt();
        if (snapshotTime != 0 && block.timestamp <= snapshotTime) revert SameBlockAsPoke();

        IToken12Treasury(token).mint(to, amount);
        emit TokenMinted(msg.sender, to, amount);
    }
}
