// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pump, IPumpBasketHook} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {MockERC20StakingFactory} from "./Version13ERC20StakingMocks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

contract LegacyV13Asset is ERC20 {
    constructor() ERC20("Legacy test component", "LTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LegacyV13Pair {
    address public immutable token0;
    address public immutable token1;
    mapping(address => uint256) public balanceOf;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to) external returns (uint256 liquidity) {
        require(IERC20(token0).balanceOf(address(this)) != 0 && IERC20(token1).balanceOf(address(this)) != 0);
        liquidity = 1 ether;
        balanceOf[to] += liquidity;
    }
}

contract LegacyV13Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address token0, address token1) external returns (address pair) {
        pair = address(new LegacyV13Pair(token0, token1));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
    }
}

contract LegacyV13Router {
    address public immutable wrappedNative;

    struct StoredPool {
        bool enabled;
        address token0;
        address token1;
        INutboxRouter.SourceType sourceType;
        bytes sourceData;
    }

    mapping(bytes32 => StoredPool) private _pools;
    mapping(bytes32 => bytes32[]) private _routes;
    mapping(bytes32 => bool) private _existingRoutes;

    constructor(address wrappedNative_) {
        wrappedNative = wrappedNative_;
    }

    function setExistingRoute(address tokenIn, address tokenOut) external {
        _existingRoutes[_routeId(tokenIn, tokenOut)] = true;
    }

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        bytes32 id = _routeId(tokenIn, tokenOut);
        return _existingRoutes[id] || _routes[id].length != 0;
    }

    function validateRoute(address, address) external pure {}

    function quote(address, address, uint256 amount) external pure returns (uint256) {
        return amount * 100;
    }

    function pricePoolId(address token0, address token1) external view returns (bytes32) {
        return _poolId(token0, token1);
    }

    function hasPricePool(bytes32 poolId) external view returns (bool) {
        return _pools[poolId].enabled;
    }

    function pricePool(bytes32 poolId)
        external
        view
        returns (bool, uint32, address, address, INutboxRouter.SourceType, bytes memory)
    {
        StoredPool storage pool = _pools[poolId];
        return (pool.enabled, 0, pool.token0, pool.token1, pool.sourceType, pool.sourceData);
    }

    function addPricePool(INutboxRouter.SourceType sourceType, bytes calldata sourceData)
        external
        returns (bytes32 poolId)
    {
        address token0;
        address token1;
        if (sourceType == INutboxRouter.SourceType.V2_PAIR) {
            (, address pair) = abi.decode(sourceData, (address, address));
            token0 = LegacyV13Pair(pair).token0();
            token1 = LegacyV13Pair(pair).token1();
        } else {
            INutboxRouter.PancakeV4CLSource memory source = abi.decode(sourceData, (INutboxRouter.PancakeV4CLSource));
            token0 = source.currency0;
            token1 = source.currency1;
        }
        poolId = _poolId(token0, token1);
        require(!_pools[poolId].enabled);
        _pools[poolId] = StoredPool(true, token0, token1, sourceType, sourceData);
    }

    function addRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external {
        bytes32 id = _routeId(tokenIn, tokenOut);
        require(_routes[id].length == 0);
        for (uint256 i; i < poolIds.length; ++i) {
            _routes[id].push(poolIds[i]);
        }
    }

    function swapExactInput(
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 result) {
        require(input == address(0) && msg.value == amount && deadline >= block.timestamp);
        result = amount * 100;
        require(result >= minimum);
        LegacyV13Asset(output).mint(recipient, result);
    }

    function _normalized(address token) private view returns (address) {
        return token == address(0) ? wrappedNative : token;
    }

    function _poolId(address token0, address token1) private view returns (bytes32) {
        token0 = _normalized(token0);
        token1 = _normalized(token1);
        return token0 < token1 ? keccak256(abi.encode(token0, token1)) : keccak256(abi.encode(token1, token0));
    }

    function _routeId(address token0, address token1) private view returns (bytes32) {
        return _poolId(token0, token1);
    }
}

contract LegacyV13BasketHook {
    uint32 public constant tokenVersion = 4;
    address public immutable settlementToken;
    address public immutable v2Factory;
    address public immutable nutboxRouter;

    constructor(address settlementToken_, address v2Factory_, address nutboxRouter_) {
        settlementToken = settlementToken_;
        v2Factory = v2Factory_;
        nutboxRouter = nutboxRouter_;
    }

    function createBasketFor(address, bytes32, IPumpBasketHook.CreateParams calldata) external returns (address) {
        return address(new LegacyV13Asset());
    }
}

/// @dev Adapts pre-V13 unit fixtures to the mandatory one-component V13 creation flow.
abstract contract Version13LegacyTestSetup is Test {
    LegacyV13Asset internal legacyV13Asset;
    LegacyV13Factory internal legacyV13Factory;
    LegacyV13Router internal legacyV13Router;
    LegacyV13BasketHook internal legacyV13Basket;
    MockERC20StakingFactory internal legacyV13StakingFactory;

    function _configureLegacyV13(Pump target, Committee committee, address communityFactory, address calculator)
        internal
    {
        _configureLegacyV13Index(target);
        legacyV13StakingFactory = new MockERC20StakingFactory();
        committee.adminAddContract(address(legacyV13StakingFactory));
        target.adminSetNutbox(communityFactory, calculator, address(legacyV13StakingFactory), address(committee));
    }

    function _configureLegacyV13Index(Pump target) internal {
        legacyV13Asset = new LegacyV13Asset();
        legacyV13Factory = new LegacyV13Factory();
        legacyV13Router = new LegacyV13Router(address(new LegacyV13Asset()));
        legacyV13Router.setExistingRoute(legacyV13Router.wrappedNative(), address(legacyV13Asset));
        legacyV13Basket =
            new LegacyV13BasketHook(address(new LegacyV13Asset()), address(legacyV13Factory), address(legacyV13Router));
        target.adminSetIndexInfrastructure(
            address(legacyV13Router),
            address(legacyV13Basket),
            address(legacyV13Factory),
            legacyV13Basket.settlementToken()
        );
        target.adminSetConstituentApproval(address(legacyV13Asset), true);
        target.adminSetListingKeeper(address(this));
    }

    function _legacyV13Config() internal view returns (IPump.IndexConfig memory config) {
        config.name = "Legacy test index";
        config.symbol = "LTI";
        config.constituentAssets = new address[](1);
        config.constituentAssets[0] = address(legacyV13Asset);
        config.targetWeights = new uint16[](1);
        config.targetWeights[0] = 10_000;
        config.basketFeeBps = 100;
        config.creatorShareBps = 3000;
        config.retainCommunityOwnership = true;
    }

    function _createLegacyV13Token(Pump target, string memory tick, bytes32 salt, uint256 value)
        internal
        returns (address)
    {
        return target.createToken{value: value}(tick, salt, _legacyV13Config());
    }

    function _finalizeLegacyV13Token(Pump target, Token token) internal {
        if (!token.listingPending() || token.listed()) return;
        vm.mockCall(
            target.getPoolManager(),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(
                toBalanceDelta(-int128(int256(15 ether)), -int128(int256(150_000_000 ether))), BalanceDelta.wrap(0)
            )
        );
        uint256[] memory minimums = new uint256[](token.componentCount());
        for (uint256 i; i < minimums.length; ++i) {
            minimums[i] = 1;
        }
        target.finalizeTokenListing(address(token), minimums, block.timestamp);
        vm.clearMockedCalls();
    }
}
