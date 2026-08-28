// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager as RouterTestUniswapV4PoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback as RouterTestUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey as RouterTestUniswapV4PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency as RouterTestUniswapV4Currency} from "v4-core/src/types/Currency.sol";
import {
    BalanceDelta as RouterTestUniswapV4BalanceDelta,
    toBalanceDelta as toRouterTestUniswapV4BalanceDelta
} from "v4-core/src/types/BalanceDelta.sol";
import {
    ICLPoolManager as RouterTestPancakeV4CLPoolManager
} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ILockCallback as RouterTestLockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey as RouterTestPancakeV4PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency as RouterTestPancakeV4Currency} from "infinity-core/src/types/Currency.sol";
import {
    BalanceDelta as RouterTestPancakeV4BalanceDelta,
    toBalanceDelta as toRouterTestPancakeV4BalanceDelta
} from "infinity-core/src/types/BalanceDelta.sol";

import "../../src/router/NutboxRouter.sol";

contract RouterTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract RouterV2FactoryMock {
    mapping(address => mapping(address => address)) public getPair;

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract RouterV2PairMock {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address factory_, address token0_, address token1_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
}

contract RouterV2RouterMock {
    address public immutable factory;
    address public immutable WETH;

    constructor(address factory_, address wrappedNative_) {
        factory = factory_;
        WETH = wrappedNative_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        assert(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        uint256 amountOut = amountIn * 2;
        require(amountOut >= amountOutMin, "insufficient output");
        RouterTestToken(payable(path[1])).mint(to, amountOut);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

contract RouterV3FactoryMock {
    mapping(bytes32 => address) private pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract RouterV3PoolMock {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public liquidity;
    uint160 private sqrtPriceX96;

    constructor(address factory_, address token0_, address token1_, uint24 fee_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setState(uint160 sqrtPriceX96_, uint128 liquidity_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        liquidity = liquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

contract RouterPancakeV3RouterMock {
    address public immutable factory;
    address public immutable WETH9;
    bytes public lastPath;

    constructor(address factory_, address wrappedNative_) {
        factory = factory_;
        WETH9 = wrappedNative_;
    }

    function exactInputSingle(INutboxPancakeV3Router.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        assert(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn));
        lastPath = abi.encodePacked(params.tokenIn, params.fee, params.tokenOut);
        amountOut = params.amountIn * 2;
        require(amountOut >= params.amountOutMinimum, "insufficient output");
        RouterTestToken(payable(params.tokenOut)).mint(params.recipient, amountOut);
    }
}

contract RouterUniswapV4ManagerMock {
    mapping(bytes32 => bytes32) private values;

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        values[stateSlot] = bytes32(uint256(sqrtPriceX96));
        values[bytes32(uint256(stateSlot) + 3)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return values[slot];
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return RouterTestUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(
        RouterTestUniswapV4PoolKey calldata,
        RouterTestUniswapV4PoolManager.SwapParams calldata params,
        bytes calldata
    ) external pure returns (RouterTestUniswapV4BalanceDelta delta) {
        uint256 amountIn = uint256(-params.amountSpecified);
        int128 signedIn = int128(int256(amountIn));
        int128 signedOut = int128(int256(amountIn * 2));
        return params.zeroForOne
            ? toRouterTestUniswapV4BalanceDelta(-signedIn, signedOut)
            : toRouterTestUniswapV4BalanceDelta(signedOut, -signedIn);
    }

    function sync(RouterTestUniswapV4Currency) external {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }

    function take(RouterTestUniswapV4Currency currency, address to, uint256 amount) external {
        _sendCurrency(RouterTestUniswapV4Currency.unwrap(currency), to, amount);
    }

    function _sendCurrency(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "native transfer failed");
        } else {
            RouterTestToken(payable(token)).mint(to, amount);
        }
    }

    receive() external payable {}
}

contract RouterPancakeV4VaultMock {
    address private locker;

    function lock(bytes calldata data) external returns (bytes memory) {
        locker = msg.sender;
        bytes memory result = RouterTestLockCallback(msg.sender).lockAcquired(data);
        locker = address(0);
        return result;
    }

    function getLocker() external view returns (address) {
        return locker;
    }

    function setLocker(address locker_) external {
        locker = locker_;
    }

    function sync(RouterTestPancakeV4Currency) external {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }

    function take(RouterTestPancakeV4Currency currency, address to, uint256 amount) external {
        address token = RouterTestPancakeV4Currency.unwrap(currency);
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "native transfer failed");
        } else {
            RouterTestToken(payable(token)).mint(to, amount);
        }
    }

    receive() external payable {}
}

contract RouterPancakeV4CLManagerMock {
    address public immutable vault;
    mapping(bytes32 => uint160) private prices;
    mapping(bytes32 => uint128) private liquidities;

    constructor(address vault_) {
        vault = vault_;
    }

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        prices[poolId] = sqrtPriceX96;
        liquidities[poolId] = liquidity;
    }

    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        return (prices[poolId], 0, 0, 0);
    }

    function getLiquidity(bytes32 poolId) external view returns (uint128) {
        return liquidities[poolId];
    }

    function swap(
        RouterTestPancakeV4PoolKey calldata,
        RouterTestPancakeV4CLPoolManager.SwapParams calldata params,
        bytes calldata
    ) external pure returns (RouterTestPancakeV4BalanceDelta delta) {
        uint256 amountIn = uint256(-params.amountSpecified);
        int128 signedIn = int128(int256(amountIn));
        int128 signedOut = int128(int256(amountIn * 2));
        return params.zeroForOne
            ? toRouterTestPancakeV4BalanceDelta(-signedIn, signedOut)
            : toRouterTestPancakeV4BalanceDelta(signedOut, -signedIn);
    }
}

contract NutboxRouterTest is Test {
    uint160 private constant Q96 = uint160(1 << 96);
    uint256 private constant AMOUNT = 1_000 ether;

    RouterTestToken private baseToken;
    RouterTestToken private bridgeToken;
    RouterTestToken private wrappedNative;
    RouterV2FactoryMock private v2Factory;
    RouterV2RouterMock private v2Router;
    RouterV3FactoryMock private v3Factory;
    RouterPancakeV3RouterMock private v3Router;
    RouterUniswapV4ManagerMock private uniswapV4Manager;
    RouterPancakeV4CLManagerMock private pancakeV4Manager;
    NutboxRouter private router;

    function setUp() public {
        baseToken = new RouterTestToken("Base", "BASE");
        bridgeToken = new RouterTestToken("Bridge", "BRIDGE");
        wrappedNative = new RouterTestToken("Wrapped Native", "WNATIVE");
        v2Factory = new RouterV2FactoryMock();
        v2Router = new RouterV2RouterMock(address(v2Factory), address(wrappedNative));
        v3Factory = new RouterV3FactoryMock();
        v3Router = new RouterPancakeV3RouterMock(address(v3Factory), address(wrappedNative));
        uniswapV4Manager = new RouterUniswapV4ManagerMock();
        pancakeV4Manager = new RouterPancakeV4CLManagerMock(address(new RouterPancakeV4VaultMock()));

        router = _deployRouter(new INutboxRouter.InitialPricePool[](0), new INutboxRouter.InitialRoute[](0));
    }

    function test_ConstructorBootstrapsTrustedPoolAndRoute() public {
        RouterV2PairMock pair = _createV2Pair(address(baseToken), address(wrappedNative), 1_000 ether, 10 ether);
        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        bytes32 poolId = keccak256(abi.encode(token0, token1));

        INutboxRouter.InitialPricePool[] memory pools = new INutboxRouter.InitialPricePool[](1);
        pools[0] = INutboxRouter.InitialPricePool({
            token0: token0,
            token1: token1,
            sourceType: INutboxRouter.SourceType.V2_PAIR,
            sourceData: abi.encode(address(v2Factory), address(pair))
        });
        INutboxRouter.InitialRoute[] memory routes = new INutboxRouter.InitialRoute[](1);
        routes[0] = INutboxRouter.InitialRoute({
            tokenIn: address(baseToken), tokenOut: address(wrappedNative), poolIds: _singlePool(poolId)
        });

        NutboxRouter bootstrapped = _deployRouter(pools, routes);

        assertEq(bootstrapped.owner(), address(this));
        assertTrue(bootstrapped.hasPricePool(poolId));
        assertTrue(bootstrapped.hasRoute(address(baseToken), address(wrappedNative)));
        assertEq(bootstrapped.routePoolAt(address(baseToken), address(wrappedNative), 0), poolId);
        assertEq(bootstrapped.routePoolAt(address(wrappedNative), address(baseToken), 0), poolId);
        assertEq(bootstrapped.quoteNative(address(baseToken), 100 ether), 1 ether);
        (, uint32 references,,,,) = bootstrapped.pricePool(poolId);
        assertEq(references, 1);
    }

    function test_ConstructorBootstrapDeliberatelySkipsPoolAndRouteValidation() public {
        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        bytes32 poolId = keccak256(abi.encode(token0, token1));
        INutboxRouter.InitialPricePool[] memory pools = new INutboxRouter.InitialPricePool[](1);
        pools[0] = INutboxRouter.InitialPricePool({
            token0: token0,
            token1: token1,
            sourceType: INutboxRouter.SourceType.V2_PAIR,
            sourceData: abi.encode(makeAddr("unapprovedFactory"), makeAddr("missingPair"))
        });
        INutboxRouter.InitialRoute[] memory routes = new INutboxRouter.InitialRoute[](1);
        routes[0] = INutboxRouter.InitialRoute({
            tokenIn: address(baseToken), tokenOut: address(wrappedNative), poolIds: _singlePool(poolId)
        });

        NutboxRouter bootstrapped = _deployRouter(pools, routes);

        assertTrue(bootstrapped.hasPricePool(poolId));
        assertTrue(bootstrapped.hasRoute(address(baseToken), address(wrappedNative)));
        vm.expectRevert(NutboxSpotPrice.InvalidSource.selector);
        bootstrapped.validateRoute(address(baseToken), address(wrappedNative));
    }

    function test_OwnerRegistersV2PoolAndRouteQuotesBothDirections() public {
        (, bytes32 poolId) = _registerV2Pool(address(baseToken), address(wrappedNative), 1_000_000 ether, 100 ether);

        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(poolId));

        assertTrue(router.hasPricePool(poolId));
        assertEq(router.pricePoolId(address(baseToken), address(wrappedNative)), poolId);
        assertEq(router.pricePoolId(address(wrappedNative), address(baseToken)), poolId);
        assertEq(router.pricePoolId(address(baseToken), address(0)), poolId);
        assertTrue(router.hasRoute(address(baseToken), address(wrappedNative)));
        assertTrue(router.hasRoute(address(wrappedNative), address(baseToken)));
        assertEq(router.routePoolCount(address(baseToken), address(wrappedNative)), 1);
        assertEq(router.routePoolAt(address(baseToken), address(wrappedNative), 0), poolId);
        assertEq(router.quote(address(baseToken), address(wrappedNative), AMOUNT), 0.1 ether);
        assertEq(router.quote(address(wrappedNative), address(baseToken), 0.1 ether), AMOUNT);
        assertEq(router.quoteNative(address(baseToken), AMOUNT), 0.1 ether);
        assertEq(router.quote(address(0), address(wrappedNative), AMOUNT), AMOUNT);
        router.validateRoute(address(baseToken), address(wrappedNative));
        router.validateRoute(address(0), address(wrappedNative));

        address notAToken = makeAddr("notAToken");
        vm.expectRevert(NutboxRouter.InvalidRoute.selector);
        router.quote(notAToken, notAToken, AMOUNT);
    }

    function test_MultiHopRouteChainsRawOutputsAndReversesPoolOrder() public {
        (, bytes32 firstPoolId) = _registerV2Pool(address(baseToken), address(bridgeToken), 1_000 ether, 2_000 ether);
        (, bytes32 secondPoolId) =
            _registerV2Pool(address(bridgeToken), address(wrappedNative), 10_000 ether, 100 ether);
        bytes32[] memory poolIds = new bytes32[](2);
        poolIds[0] = firstPoolId;
        poolIds[1] = secondPoolId;

        router.addRoute(address(baseToken), address(wrappedNative), poolIds);

        assertEq(router.quote(address(baseToken), address(wrappedNative), 100 ether), 2 ether);
        assertEq(router.quote(address(wrappedNative), address(baseToken), 2 ether), 100 ether);
        assertEq(router.routePoolCount(address(baseToken), address(wrappedNative)), 2);
        assertEq(router.routePoolAt(address(baseToken), address(wrappedNative), 0), firstPoolId);
        assertEq(router.routePoolAt(address(wrappedNative), address(baseToken), 0), secondPoolId);
    }

    function test_SwapUsesCurrentV3RouteAndReplacementWithoutCallerPath() public {
        bytes32 firstPoolId = _registerV3Pool(address(baseToken), address(bridgeToken), 500);
        bytes32 secondPoolId = _registerV3Pool(address(bridgeToken), address(wrappedNative), 100);
        bytes32[] memory firstRoute = new bytes32[](2);
        firstRoute[0] = firstPoolId;
        firstRoute[1] = secondPoolId;
        router.addRoute(address(baseToken), address(wrappedNative), firstRoute);

        address trader = makeAddr("trader");
        address recipient = makeAddr("recipient");
        baseToken.mint(trader, 10 ether);
        vm.startPrank(trader);
        baseToken.approve(address(router), 10 ether);
        uint256 amountOut = router.swapExactInput(
            address(baseToken), address(wrappedNative), 4 ether, 8 ether, recipient, block.timestamp
        );
        vm.stopPrank();

        assertEq(amountOut, 16 ether);
        assertEq(wrappedNative.balanceOf(recipient), 16 ether);
        assertEq(baseToken.balanceOf(address(router)), 0, "router retained input");
        assertEq(baseToken.allowance(address(router), address(v3Router)), 0, "router approval retained");
        assertEq(v3Router.lastPath(), abi.encodePacked(address(bridgeToken), uint24(100), address(wrappedNative)));

        bytes32 replacementPoolId = _registerV3Pool(address(baseToken), address(wrappedNative), 2_500);
        router.replaceRoute(address(baseToken), address(wrappedNative), _singlePool(replacementPoolId));

        vm.prank(trader);
        amountOut = router.swapExactInput(
            address(baseToken), address(wrappedNative), 1 ether, 2 ether, recipient, block.timestamp
        );
        assertEq(amountOut, 2 ether);
        assertEq(v3Router.lastPath(), abi.encodePacked(address(baseToken), uint24(2_500), address(wrappedNative)));
    }

    function test_SwapSupportsNativeInputAndOutput() public {
        bytes32 poolId = _registerV3Pool(address(baseToken), address(wrappedNative), 500);
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(poolId));

        address trader = makeAddr("nativeTrader");
        address recipient = makeAddr("nativeRecipient");
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        uint256 tokenOut = router.swapExactInput{value: 1 ether}(
            address(0), address(baseToken), 1 ether, 2 ether, recipient, block.timestamp
        );
        assertEq(tokenOut, 2 ether);
        assertEq(baseToken.balanceOf(recipient), 2 ether);

        baseToken.mint(trader, 1 ether);
        vm.prank(trader);
        baseToken.approve(address(router), 1 ether);
        vm.deal(address(wrappedNative), 2 ether);
        uint256 nativeBefore = recipient.balance;
        vm.prank(trader);
        uint256 nativeOut =
            router.swapExactInput(address(baseToken), address(0), 1 ether, 2 ether, recipient, block.timestamp);
        assertEq(nativeOut, 2 ether);
        assertEq(recipient.balance - nativeBefore, 2 ether);
        assertEq(address(router).balance, 0, "router retained native coin");
        assertEq(wrappedNative.balanceOf(address(router)), 0, "router retained wrapped native");
    }

    function test_SwapDirectlyWrapsAndUnwrapsNativeCoin() public {
        address trader = makeAddr("directNativeTrader");
        address recipient = makeAddr("directNativeRecipient");
        vm.deal(trader, 2 ether);

        vm.prank(trader);
        uint256 wrappedOut = router.swapExactInput{value: 1 ether}(
            address(0), address(wrappedNative), 1 ether, 1 ether, recipient, block.timestamp
        );
        assertEq(wrappedOut, 1 ether);
        assertEq(wrappedNative.balanceOf(recipient), 1 ether);

        vm.prank(recipient);
        wrappedNative.approve(address(router), 1 ether);
        vm.deal(address(wrappedNative), 1 ether);
        uint256 nativeBefore = recipient.balance;
        vm.prank(recipient);
        uint256 nativeOut =
            router.swapExactInput(address(wrappedNative), address(0), 1 ether, 1 ether, recipient, block.timestamp);
        assertEq(nativeOut, 1 ether);
        assertEq(recipient.balance - nativeBefore, 1 ether);
        assertEq(address(router).balance, 0);
        assertEq(wrappedNative.balanceOf(address(router)), 0);
    }

    function test_SwapSupportsV2AndRejectsExpiredCallOrIncorrectNativeValue() public {
        (, bytes32 poolId) = _registerV2Pool(address(baseToken), address(wrappedNative), 1_000 ether, 10 ether);
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(poolId));

        address trader = makeAddr("trader");
        baseToken.mint(trader, 3 ether);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        baseToken.approve(address(router), 3 ether);

        vm.prank(trader);
        uint256 amountOut = router.swapExactInput(
            address(baseToken), address(wrappedNative), 1 ether, 2 ether, trader, block.timestamp
        );
        assertEq(amountOut, 2 ether);
        assertEq(wrappedNative.balanceOf(trader), 2 ether);
        assertEq(baseToken.allowance(address(router), address(v2Router)), 0, "router approval retained");

        vm.prank(trader);
        vm.expectRevert(NutboxRouter.DeadlineExpired.selector);
        router.swapExactInput(address(baseToken), address(wrappedNative), 1 ether, 0, trader, block.timestamp - 1);

        vm.prank(trader);
        vm.expectRevert(NutboxRouter.InvalidNativeValue.selector);
        router.swapExactInput{value: 1}(address(baseToken), address(wrappedNative), 1 ether, 0, trader, block.timestamp);
    }

    function test_V3AndV4SourcesRemainSupported() public {
        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        RouterV3PoolMock v3Pool = new RouterV3PoolMock(address(v3Factory), token0, token1, 500);
        v3Factory.setPool(address(baseToken), address(wrappedNative), 500, address(v3Pool));
        v3Pool.setState(Q96, 1 ether);
        bytes32 v3PoolId =
            router.addPricePool(INutboxRouter.SourceType.V3_POOL, abi.encode(address(v3Factory), address(v3Pool)));
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(v3PoolId));
        assertEq(router.quote(address(baseToken), address(wrappedNative), AMOUNT), AMOUNT);

        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: address(uniswapV4Manager),
            currency0: address(0),
            currency1: address(baseToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });
        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        uniswapV4Manager.setPool(poolId, Q96, 1 ether);
        bytes32 v4PoolId = router.replacePricePool(INutboxRouter.SourceType.UNISWAP_V4, abi.encode(source));
        assertEq(v4PoolId, v3PoolId, "pair ID changed across V3/V4 replacement");
        assertEq(router.routePoolAt(address(baseToken), address(wrappedNative), 0), v3PoolId);
        assertEq(router.quote(address(baseToken), address(wrappedNative), AMOUNT), AMOUNT);
        assertEq(router.quote(address(0), address(baseToken), AMOUNT), AMOUNT);

        address trader = makeAddr("uniswapV4Trader");
        address recipient = makeAddr("uniswapV4Recipient");
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        uint256 amountOut = router.swapExactInput{value: 1 ether}(
            address(0), address(baseToken), 1 ether, 2 ether, recipient, block.timestamp
        );
        assertEq(amountOut, 2 ether);
        assertEq(baseToken.balanceOf(recipient), 2 ether);
        assertEq(address(router).balance, 0);
    }

    function test_PancakeV4NativeRoute() public {
        INutboxRouter.PancakeV4CLSource memory source = INutboxRouter.PancakeV4CLSource({
            currency0: address(0),
            currency1: address(baseToken),
            hooks: address(0),
            poolManager: address(pancakeV4Manager),
            fee: 500,
            parameters: bytes32(uint256(10))
        });
        bytes32 sourcePoolId = keccak256(
            abi.encode(
                source.currency0, source.currency1, source.hooks, source.poolManager, source.fee, source.parameters
            )
        );
        pancakeV4Manager.setPool(sourcePoolId, Q96, 1 ether);
        bytes32 registryPoolId = router.addPricePool(INutboxRouter.SourceType.PANCAKE_V4_CL, abi.encode(source));
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(registryPoolId));
        assertEq(router.quoteNative(address(baseToken), AMOUNT), AMOUNT);
        assertEq(router.quote(address(0), address(baseToken), AMOUNT), AMOUNT);

        address trader = makeAddr("pancakeV4Trader");
        address recipient = makeAddr("pancakeV4Recipient");
        baseToken.mint(trader, 2 ether);
        vm.deal(trader, 2 ether);
        vm.deal(pancakeV4Manager.vault(), 10 ether);
        vm.prank(trader);
        baseToken.approve(address(router), 2 ether);

        uint256 nativeBefore = recipient.balance;
        vm.prank(trader);
        uint256 nativeOut =
            router.swapExactInput(address(baseToken), address(0), 1 ether, 2 ether, recipient, block.timestamp);
        assertEq(nativeOut, 2 ether);
        assertEq(recipient.balance - nativeBefore, 2 ether);

        vm.prank(trader);
        uint256 tokenOut = router.swapExactInput{value: 1 ether}(
            address(0), address(baseToken), 1 ether, 2 ether, recipient, block.timestamp
        );
        assertEq(tokenOut, 2 ether);
        assertEq(baseToken.balanceOf(recipient), 2 ether);

        RouterPancakeV4VaultMock payableVault = RouterPancakeV4VaultMock(payable(pancakeV4Manager.vault()));
        payableVault.setLocker(makeAddr("existingInfinityLocker"));
        vm.prank(trader);
        uint256 nestedNativeOut =
            router.swapExactInput(address(baseToken), address(0), 1 ether, 2 ether, recipient, block.timestamp);
        assertEq(nestedNativeOut, 2 ether, "active Vault lock path failed");
        payableVault.setLocker(address(0));
        assertEq(address(router).balance, 0);
        assertEq(wrappedNative.balanceOf(address(router)), 0);
    }

    function test_SwapExecutesMixedV2UniswapV4PancakeV4AndV3Route() public {
        RouterTestToken token1 = new RouterTestToken("Token 1", "T1");
        RouterTestToken token2 = new RouterTestToken("Token 2", "T2");
        (, bytes32 v2PoolId) = _registerV2Pool(address(baseToken), address(token1), 1_000 ether, 1_000 ether);

        (address uniCurrency0, address uniCurrency1) = _sort(address(token1), address(token2));
        INutboxRouter.UniswapV4Source memory uniSource = INutboxRouter.UniswapV4Source({
            poolManager: address(uniswapV4Manager),
            currency0: uniCurrency0,
            currency1: uniCurrency1,
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        bytes32 uniSourcePoolId = keccak256(
            abi.encode(uniSource.currency0, uniSource.currency1, uniSource.fee, uniSource.tickSpacing, uniSource.hooks)
        );
        uniswapV4Manager.setPool(uniSourcePoolId, Q96, 1 ether);
        bytes32 uniPoolId = router.addPricePool(INutboxRouter.SourceType.UNISWAP_V4, abi.encode(uniSource));

        (address cakeCurrency0, address cakeCurrency1) = _sort(address(token2), address(bridgeToken));
        INutboxRouter.PancakeV4CLSource memory cakeSource = INutboxRouter.PancakeV4CLSource({
            currency0: cakeCurrency0,
            currency1: cakeCurrency1,
            hooks: address(0),
            poolManager: address(pancakeV4Manager),
            fee: 100,
            parameters: bytes32(uint256(1))
        });
        bytes32 cakeSourcePoolId = keccak256(
            abi.encode(
                cakeSource.currency0,
                cakeSource.currency1,
                cakeSource.hooks,
                cakeSource.poolManager,
                cakeSource.fee,
                cakeSource.parameters
            )
        );
        pancakeV4Manager.setPool(cakeSourcePoolId, Q96, 1 ether);
        bytes32 cakePoolId = router.addPricePool(INutboxRouter.SourceType.PANCAKE_V4_CL, abi.encode(cakeSource));
        bytes32 v3PoolId = _registerV3Pool(address(bridgeToken), address(wrappedNative), 500);

        bytes32[] memory poolIds = new bytes32[](4);
        poolIds[0] = v2PoolId;
        poolIds[1] = uniPoolId;
        poolIds[2] = cakePoolId;
        poolIds[3] = v3PoolId;
        router.addRoute(address(baseToken), address(wrappedNative), poolIds);

        address trader = makeAddr("mixedRouteTrader");
        address recipient = makeAddr("mixedRouteRecipient");
        baseToken.mint(trader, 1 ether);
        vm.prank(trader);
        baseToken.approve(address(router), 1 ether);
        vm.prank(trader);
        uint256 amountOut = router.swapExactInput(
            address(baseToken), address(wrappedNative), 1 ether, 16 ether, recipient, block.timestamp
        );

        assertEq(amountOut, 16 ether);
        assertEq(wrappedNative.balanceOf(recipient), 16 ether);
        assertEq(baseToken.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(token2.balanceOf(address(router)), 0);
        assertEq(bridgeToken.balanceOf(address(router)), 0);
    }

    function test_RejectsUnsolicitedV4Callbacks() public {
        vm.expectRevert(NutboxRouter.InvalidCallback.selector);
        router.unlockCallback("");
        vm.expectRevert(NutboxRouter.InvalidCallback.selector);
        router.lockAcquired("");
    }

    function test_ReplacePricePoolImmediatelyUpdatesEveryReferencingRoute() public {
        (, bytes32 poolId) = _registerV2Pool(address(baseToken), address(wrappedNative), 1_000 ether, 10 ether);
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(poolId));
        (, bytes32 bridgePoolId) = _registerV2Pool(address(wrappedNative), address(bridgeToken), 100 ether, 300 ether);
        bytes32[] memory multiHopRoute = new bytes32[](2);
        multiHopRoute[0] = poolId;
        multiHopRoute[1] = bridgePoolId;
        router.addRoute(address(baseToken), address(bridgeToken), multiHopRoute);
        assertEq(router.quoteNative(address(baseToken), 100 ether), 1 ether);
        assertEq(router.quote(address(baseToken), address(bridgeToken), 100 ether), 3 ether);

        RouterV2PairMock replacementPair =
            _createV2Pair(address(baseToken), address(wrappedNative), 1_000 ether, 20 ether);
        bytes memory replacementSource = abi.encode(address(v2Factory), address(replacementPair));
        vm.expectRevert(NutboxRouter.PricePoolAlreadyExists.selector);
        router.addPricePool(INutboxRouter.SourceType.V2_PAIR, replacementSource);

        bytes32 replacementPoolId = router.replacePricePool(INutboxRouter.SourceType.V2_PAIR, replacementSource);
        assertEq(replacementPoolId, poolId, "replacement changed stable pair ID");
        assertEq(router.quoteNative(address(baseToken), 100 ether), 2 ether);
        assertEq(router.quote(address(baseToken), address(bridgeToken), 100 ether), 6 ether);
        assertEq(router.routePoolAt(address(baseToken), address(wrappedNative), 0), poolId);
        assertEq(router.routePoolAt(address(baseToken), address(bridgeToken), 0), poolId);

        (bool enabled, uint32 references,,, INutboxRouter.SourceType sourceType, bytes memory sourceData) =
            router.pricePool(poolId);
        assertTrue(enabled);
        assertEq(references, 2);
        assertEq(uint8(sourceType), uint8(INutboxRouter.SourceType.V2_PAIR));
        assertEq(sourceData, replacementSource);

        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        RouterV3PoolMock emptyV3Pool = new RouterV3PoolMock(address(v3Factory), token0, token1, 500);
        emptyV3Pool.setState(Q96, 0);
        v3Factory.setPool(address(baseToken), address(wrappedNative), 500, address(emptyV3Pool));
        vm.expectRevert(NutboxSpotPrice.PoolNotInitialized.selector);
        router.replacePricePool(INutboxRouter.SourceType.V3_POOL, abi.encode(address(v3Factory), address(emptyV3Pool)));
        assertEq(router.quoteNative(address(baseToken), 100 ether), 2 ether, "failed replacement changed pool");

        vm.expectRevert(NutboxRouter.PricePoolInUse.selector);
        router.removePricePool(poolId);

        router.removeRoute(address(baseToken), address(wrappedNative));
        assertFalse(router.hasRoute(address(baseToken), address(wrappedNative)));
        vm.expectRevert(NutboxRouter.RouteNotFound.selector);
        router.quoteNative(address(baseToken), 100 ether);
        vm.expectRevert(NutboxRouter.RouteNotFound.selector);
        router.routePoolAt(address(baseToken), address(wrappedNative), 0);
        vm.expectRevert(NutboxRouter.PricePoolInUse.selector);
        router.removePricePool(poolId);
        router.removeRoute(address(baseToken), address(bridgeToken));
        router.removePricePool(poolId);
        assertFalse(router.hasPricePool(poolId));
    }

    function test_OnlyOwnerCanManagePoolsAndRoutes() public {
        RouterV2PairMock pair = _createV2Pair(address(baseToken), address(wrappedNative), 1_000 ether, 10 ether);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        router.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(v2Factory), address(pair)));

        bytes32 poolId =
            router.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(v2Factory), address(pair)));
        RouterV2PairMock replacementPair =
            _createV2Pair(address(baseToken), address(wrappedNative), 1_000 ether, 20 ether);
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        router.replacePricePool(
            INutboxRouter.SourceType.V2_PAIR, abi.encode(address(v2Factory), address(replacementPair))
        );
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        router.addRoute(address(baseToken), address(wrappedNative), _singlePool(poolId));
    }

    function test_SupportsFiveHopsAndRejectsLongerOrDiscontinuousRoutes() public {
        RouterTestToken token1 = new RouterTestToken("Token 1", "T1");
        RouterTestToken token2 = new RouterTestToken("Token 2", "T2");
        RouterTestToken token3 = new RouterTestToken("Token 3", "T3");
        RouterTestToken token4 = new RouterTestToken("Token 4", "T4");
        address[6] memory tokens = [
            address(baseToken),
            address(token1),
            address(token2),
            address(token3),
            address(token4),
            address(wrappedNative)
        ];
        bytes32[] memory fivePools = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            (, fivePools[i]) = _registerV2Pool(tokens[i], tokens[i + 1], 1_000 ether, 1_000 ether);
        }
        router.addRoute(address(baseToken), address(wrappedNative), fivePools);
        assertEq(router.quoteNative(address(baseToken), AMOUNT), AMOUNT);
        router.removeRoute(address(baseToken), address(wrappedNative));

        bytes32[] memory tooLong = new bytes32[](6);
        vm.expectRevert(NutboxRouter.InvalidRoute.selector);
        router.addRoute(address(baseToken), address(wrappedNative), tooLong);

        (, bytes32 wrongPoolId) = _registerV2Pool(address(baseToken), address(wrappedNative), 1_000 ether, 10 ether);
        vm.expectRevert(NutboxRouter.InvalidRoute.selector);
        router.addRoute(address(baseToken), address(bridgeToken), _singlePool(wrongPoolId));
    }

    function test_RejectsUnapprovedOrUninitializedPool() public {
        RouterV2FactoryMock otherFactory = new RouterV2FactoryMock();
        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        RouterV2PairMock unapproved = new RouterV2PairMock(address(otherFactory), token0, token1);
        otherFactory.setPair(address(baseToken), address(wrappedNative), address(unapproved));
        unapproved.setReserves(1 ether, 1 ether);
        vm.expectRevert(NutboxSpotPrice.InvalidSource.selector);
        router.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(otherFactory), address(unapproved)));

        RouterV2PairMock empty = _createV2Pair(address(baseToken), address(wrappedNative), 0, 0);
        vm.expectRevert(NutboxSpotPrice.PoolNotInitialized.selector);
        router.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(v2Factory), address(empty)));
    }

    function _singlePool(bytes32 poolId) private pure returns (bytes32[] memory poolIds) {
        poolIds = new bytes32[](1);
        poolIds[0] = poolId;
    }

    function _deployRouter(
        INutboxRouter.InitialPricePool[] memory initialPools,
        INutboxRouter.InitialRoute[] memory initialRoutes
    ) private returns (NutboxRouter deployed) {
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = address(v2Factory);
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = address(v2Router);
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = address(v3Factory);
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = address(uniswapV4Manager);
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = address(pancakeV4Manager);
        deployed = new NutboxRouter(
            address(wrappedNative),
            address(v3Router),
            v2Routers,
            v2Factories,
            v3Factories,
            uniswapV4Managers,
            pancakeV4Managers,
            abi.encode(initialPools, initialRoutes)
        );
    }

    function _registerV2Pool(address tokenA, address tokenB, uint112 reserveA, uint112 reserveB)
        private
        returns (RouterV2PairMock pair, bytes32 poolId)
    {
        pair = _createV2Pair(tokenA, tokenB, reserveA, reserveB);
        poolId = router.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(v2Factory), address(pair)));
    }

    function _registerV3Pool(address tokenA, address tokenB, uint24 fee) private returns (bytes32 poolId) {
        (address token0, address token1) = _sort(tokenA, tokenB);
        RouterV3PoolMock pool = new RouterV3PoolMock(address(v3Factory), token0, token1, fee);
        pool.setState(Q96, 1 ether);
        v3Factory.setPool(tokenA, tokenB, fee, address(pool));
        poolId = router.addPricePool(INutboxRouter.SourceType.V3_POOL, abi.encode(address(v3Factory), address(pool)));
    }

    function _createV2Pair(address tokenA, address tokenB, uint112 reserveA, uint112 reserveB)
        private
        returns (RouterV2PairMock pair)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        pair = new RouterV2PairMock(address(v2Factory), token0, token1);
        v2Factory.setPair(tokenA, tokenB, address(pair));
        if (token0 == tokenA) pair.setReserves(reserveA, reserveB);
        else pair.setReserves(reserveB, reserveA);
    }

    function _sort(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ─── RH 适配（方案 B）：V3 router=0 禁用 V3 路径 ────────────────────────────

    /// @dev V3 router 置 0 时构造成功，pancakeV3Factory 保持 0，V3 source revert。
    function test_RH_V3RouterZero_DisablesV3Path() public {
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = address(v2Factory);
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = address(v2Router);
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = address(v3Factory);
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = address(uniswapV4Manager);
        NutboxRouter rhRouter = new NutboxRouter(
            address(wrappedNative),
            address(0), // 方案 B：V3 router 禁用
            v2Routers,
            v2Factories,
            v3Factories,
            uniswapV4Managers,
            new address[](0), // 无 Pancake V4 CL
            abi.encode(new INutboxRouter.InitialPricePool[](0), new INutboxRouter.InitialRoute[](0))
        );
        assertEq(rhRouter.pancakeV3Router(), address(0), "v3 router zero");
        assertEq(rhRouter.pancakeV3Factory(), address(0), "v3 factory zero");

        // 注册一个 V3 pool 仍可登记，但 swapExactInput 走 V3 source 时 revert UnsupportedSwapSource。
        (address token0, address token1) = _sort(address(baseToken), address(wrappedNative));
        RouterV3PoolMock pool = new RouterV3PoolMock(address(v3Factory), token0, token1, 3000);
        pool.setState(Q96, 1 ether);
        v3Factory.setPool(address(baseToken), address(wrappedNative), 3000, address(pool));
        bytes32 poolId = rhRouter.addPricePool(
            INutboxRouter.SourceType.V3_POOL, abi.encode(address(v3Factory), address(pool))
        );
        // 注册路由（owner 是测试合约）
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = poolId;
        rhRouter.addRoute(address(baseToken), address(wrappedNative), poolIds);
        baseToken.mint(address(this), 100 ether);
        baseToken.approve(address(rhRouter), 100 ether);
        vm.expectRevert(NutboxRouter.UnsupportedSwapSource.selector);
        rhRouter.swapExactInput(address(baseToken), address(wrappedNative), 100 ether, 0, makeAddr("recipient"), block.timestamp + 1);
    }
}
