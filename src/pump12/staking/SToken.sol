// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @title SToken
/// @notice Per-token rebasing staking receipt using a gon accounting model.
contract SToken {
    error AlreadyInitialized();
    error InvalidInitialization();
    error OnlyStaking();
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    uint8 public constant decimals = 18;
    uint256 private constant INDEX_BASE = 1e18;
    uint256 private constant INITIAL_GONS_PER_FRAGMENT = 1e36;

    bool public initialized;
    address public staking;
    string public name;
    string public symbol;
    uint256 private _totalSupply;
    uint256 public totalGons;
    uint256 public gonsPerFragment;
    mapping(address account => uint256 gons) private _gonBalances;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Rebased(uint64 indexed epoch, uint256 profit, uint256 totalSupply, uint256 index);

    constructor() {
        initialized = true;
    }

    modifier onlyStaking() {
        if (msg.sender != staking) revert OnlyStaking();
        _;
    }

    function initialize(address staking_, string calldata name_, string calldata symbol_) external {
        if (initialized) revert AlreadyInitialized();
        if (staking_.code.length == 0 || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidInitialization();
        }
        initialized = true;
        staking = staking_;
        name = name_;
        symbol = symbol_;
        gonsPerFragment = INITIAL_GONS_PER_FRAGMENT;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _gonBalances[account] / gonsPerFragment;
    }

    function index() external view returns (uint256) {
        return INDEX_BASE * INITIAL_GONS_PER_FRAGMENT / gonsPerFragment;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyStaking {
        if (to == address(0)) revert InvalidAddress();
        uint256 gons = amount * gonsPerFragment;
        totalGons += gons;
        _gonBalances[to] += gons;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyStaking {
        uint256 balance = balanceOf(from);
        if (amount > balance) revert InsufficientBalance();
        uint256 gons = amount == balance ? _gonBalances[from] : amount * gonsPerFragment;
        _gonBalances[from] -= gons;
        totalGons -= gons;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function rebase(uint256 profit, uint64 epoch) external onlyStaking returns (uint256 newSupply) {
        if (profit == 0 || _totalSupply == 0) {
            emit Rebased(epoch, 0, _totalSupply, INDEX_BASE * INITIAL_GONS_PER_FRAGMENT / gonsPerFragment);
            return _totalSupply;
        }
        newSupply = _totalSupply + profit;
        _totalSupply = newSupply;
        gonsPerFragment = totalGons / newSupply;
        emit Rebased(epoch, profit, newSupply, INDEX_BASE * INITIAL_GONS_PER_FRAGMENT / gonsPerFragment);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf(from);
        if (amount > balance) revert InsufficientBalance();
        uint256 gons = amount == balance ? _gonBalances[from] : amount * gonsPerFragment;
        _gonBalances[from] -= gons;
        _gonBalances[to] += gons;
        emit Transfer(from, to, amount);
    }
}
