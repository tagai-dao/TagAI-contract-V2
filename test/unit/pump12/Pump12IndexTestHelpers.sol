// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract Pump12TestBasketRegistry {
    mapping(address => bool) public isBasket;

    function setBasket(address basket, bool approved) external {
        isBasket[basket] = approved;
    }
}

contract Pump12TestWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {}
}

contract Pump12TestBasket is ERC20 {
    address public immutable weth;
    mapping(address => uint256) public claimableHolderFees;

    constructor(address weth_) ERC20("Test Index", "TIDX") {
        weth = weth_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function injectHolderFees(address holder, uint256 amount) external {
        IERC20(weth).transferFrom(msg.sender, address(this), amount);
        claimableHolderFees[holder] += amount;
    }

    function claimHolderFeesFor(address holder) external returns (uint256 amount) {
        amount = claimableHolderFees[holder];
        claimableHolderFees[holder] = 0;
        IERC20(weth).transfer(holder, amount);
    }
}

contract Pump12TestBasketHookConfig {
    IPoolManager public immutable poolManager;
    address public immutable basketRegistry;
    address public immutable routeRegistry;
    address public immutable usdg;
    address public immutable weth;

    constructor(
        IPoolManager poolManager_,
        address basketRegistry_,
        address routeRegistry_,
        address usdg_,
        address weth_
    ) {
        poolManager = poolManager_;
        basketRegistry = basketRegistry_;
        routeRegistry = routeRegistry_;
        usdg = usdg_;
        weth = weth_;
    }
}

contract Pump12TestBasketRouter {
    IPoolManager public immutable poolManager;
    address public immutable usdg;
    address public immutable basketHook;

    constructor(IPoolManager poolManager_, address usdg_, address basketHook_) {
        poolManager = poolManager_;
        usdg = usdg_;
        basketHook = basketHook_;
    }

    function buyExactUsdg(address, uint256, uint256, bytes calldata, address) external pure returns (uint256) {
        revert("unused test router");
    }

    function sellExactBasket(address, uint256, uint256, bytes calldata, address) external pure returns (uint256) {
        revert("unused test router");
    }
}

contract Pump12TestRouteRegistry {
    IPoolManager public immutable poolManager;
    PoolKey private _hub;

    constructor(IPoolManager poolManager_, address usdg_) {
        poolManager = poolManager_;
        _hub = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdg_),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function hubRoute() external view returns (PoolKey memory) {
        return _hub;
    }
}
