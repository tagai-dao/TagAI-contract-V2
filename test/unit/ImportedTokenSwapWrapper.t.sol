// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager as ImportedTestUniswapV4PoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback as ImportedTestUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey as ImportedTestUniswapV4PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency as ImportedTestUniswapV4Currency} from "v4-core/src/types/Currency.sol";
import {
    BalanceDelta as ImportedTestUniswapV4BalanceDelta,
    toBalanceDelta as toImportedTestUniswapV4BalanceDelta
} from "v4-core/src/types/BalanceDelta.sol";

import "../../src/helper/ImportedTokenSwapWrapper.sol";

contract ImportedTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract ImportedTestWrappedNative is ImportedTestToken {
    constructor() ImportedTestToken("Wrapped Native", "WNATIVE") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "native transfer failed");
    }

    receive() external payable {}
}

contract ImportedFeeOnTransferToken is ImportedTestToken {
    constructor() ImportedTestToken("Fee Token", "FEE") {}

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        super._transfer(from, to, amount - fee);
        super._transfer(from, address(0xdead), fee);
    }
}

contract ImportedRejectNative {
    receive() external payable {
        revert("reject native");
    }
}

contract ImportedIPShareMock {
    mapping(address => bool) public ipshareCreated;
    mapping(address => uint256) public capturedValue;
    bool public captureReverts;

    function setCreated(address subject, bool created) external {
        ipshareCreated[subject] = created;
    }

    function setCaptureReverts(bool shouldRevert) external {
        captureReverts = shouldRevert;
    }

    function valueCapture(address subject) external payable {
        require(!captureReverts, "capture failed");
        require(ipshareCreated[subject], "IPShare not created");
        capturedValue[subject] += msg.value;
    }
}

contract ImportedCalculatorMock {
    address public immutable token;
    mapping(address => uint256) public injected;
    bool public injectionReverts;

    constructor(address token_) {
        token = token_;
    }

    function setInjectionReverts(bool shouldRevert) external {
        injectionReverts = shouldRevert;
    }

    function inject(address community, uint256 amount) external {
        require(!injectionReverts, "injection failed");
        require(IERC20(token).transferFrom(msg.sender, community, amount), "transfer failed");
        injected[community] += amount;
    }
}

contract ImportedCommunityMock {
    address public immutable rewardCalculator;

    constructor(address calculator_) {
        rewardCalculator = calculator_;
    }
}

contract ImportedV2FactoryMock {
    mapping(address => mapping(address => address)) public getPair;

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract ImportedV2PairMock {
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

contract ImportedV2RouterMock {
    function getAmountsOut(uint256 amountIn, address[] calldata) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "transfer failed");
        uint256 amountOut = amountIn * 2;
        require(amountOut >= amountOutMin, "slippage");
        ImportedTestToken(path[1]).mint(recipient, amountOut);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256
    ) external {
        uint256 inputBalanceBefore = IERC20(path[0]).balanceOf(address(this));
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "transfer failed");
        uint256 actualAmountIn = IERC20(path[0]).balanceOf(address(this)) - inputBalanceBefore;
        uint256 amountOut = actualAmountIn * 2;
        require(amountOut >= amountOutMin, "slippage");
        ImportedTestToken(path[1]).mint(recipient, amountOut);
    }
}

contract ImportedV3FactoryMock {
    mapping(bytes32 => address) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract ImportedV3PoolMock {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public liquidity;
    uint160 private _sqrtPriceX96;

    constructor(address factory_, address token0_, address token1_, uint24 fee_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setState(uint160 sqrtPriceX96_, uint128 liquidity_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        liquidity = liquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (_sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

contract ImportedV3RouterMock {
    bool public transferOutput;

    function setTransferOutput(bool transferOutput_) external {
        transferOutput = transferOutput_;
    }

    function exactInputSingle(IImportedUniswapV3Router.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transfer failed");
        amountOut = params.amountIn * 2;
        require(amountOut >= params.amountOutMinimum, "slippage");
        if (transferOutput) {
            require(IERC20(params.tokenOut).transfer(params.recipient, amountOut), "output transfer failed");
        } else {
            ImportedTestToken(params.tokenOut).mint(params.recipient, amountOut);
        }
    }
}

contract ImportedV3QuoterMock {
    function quoteExactInputSingle(IImportedUniswapV3Quoter.QuoteExactInputSingleParams calldata params)
        external
        pure
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (params.amountIn * 2, 0, 0, 0);
    }
}

contract ImportedUniswapV4ManagerMock {
    mapping(bytes32 => bytes32) private _values;

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        _values[stateSlot] = bytes32(uint256(sqrtPriceX96));
        _values[bytes32(uint256(stateSlot) + 3)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _values[slot];
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        result = ImportedTestUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(
        ImportedTestUniswapV4PoolKey calldata,
        ImportedTestUniswapV4PoolManager.SwapParams calldata params,
        bytes calldata
    ) external pure returns (ImportedTestUniswapV4BalanceDelta delta) {
        uint256 amountIn = uint256(-params.amountSpecified);
        int128 signedIn = int128(int256(amountIn));
        int128 signedOut = int128(int256(amountIn));
        return params.zeroForOne
            ? toImportedTestUniswapV4BalanceDelta(-signedIn, signedOut)
            : toImportedTestUniswapV4BalanceDelta(signedOut, -signedIn);
    }

    function sync(ImportedTestUniswapV4Currency) external {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }

    function take(ImportedTestUniswapV4Currency currency, address recipient, uint256 amount) external {
        address token = ImportedTestUniswapV4Currency.unwrap(currency);
        if (token == address(0)) {
            (bool success,) = payable(recipient).call{value: amount}("");
            require(success, "native transfer failed");
        } else {
            ImportedTestToken(token).mint(recipient, amount);
        }
    }

    receive() external payable {}
}

contract ImportedCoreRouterMock {
    address public immutable wrappedNative;
    address public pancakeV3Router;
    address public pancakeV3Factory;

    mapping(address => address) public v2RouterForFactory;
    mapping(address => bool) public allowedV2Factory;
    mapping(address => bool) public allowedV3Factory;
    mapping(address => bool) public allowedUniswapV4Manager;
    mapping(address => bool) public allowedPancakeV4CLManager;

    bool public bridgeEnabled = true;
    uint256 public bridgeSwapCount;

    error MissingRoute();
    error Slippage();

    constructor(address wrappedNative_, address pancakeV3Router_, address pancakeV3Factory_) {
        wrappedNative = wrappedNative_;
        pancakeV3Router = pancakeV3Router_;
        pancakeV3Factory = pancakeV3Factory_;
    }

    function setV2(address factory, address router, bool allowed) external {
        allowedV2Factory[factory] = allowed;
        v2RouterForFactory[factory] = router;
    }

    function setV3(address factory, bool allowed) external {
        allowedV3Factory[factory] = allowed;
    }

    function setUniswapV4(address manager, bool allowed) external {
        allowedUniswapV4Manager[manager] = allowed;
    }

    function setBridgeEnabled(bool enabled) external {
        bridgeEnabled = enabled;
    }

    function validateRoute(address tokenIn, address tokenOut) external view {
        if (!bridgeEnabled || !_isBridge(tokenIn, tokenOut)) revert MissingRoute();
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        if (!bridgeEnabled || !_isBridge(tokenIn, tokenOut)) revert MissingRoute();
        return amountIn;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "expired");
        if (!bridgeEnabled || !_isBridge(tokenIn, tokenOut)) revert MissingRoute();
        ++bridgeSwapCount;
        amountOut = amountIn;
        if (amountOut < amountOutMinimum) revert Slippage();

        if (tokenIn == address(0)) {
            require(msg.value == amountIn, "invalid value");
            ImportedTestToken(tokenOut).mint(recipient, amountOut);
        } else {
            require(msg.value == 0 && tokenOut == address(0), "invalid direction");
            require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transfer failed");
            (bool success,) = payable(recipient).call{value: amountOut}("");
            require(success, "native transfer failed");
        }
    }

    function _isBridge(address tokenIn, address tokenOut) private view returns (bool) {
        address normalizedIn = tokenIn == address(0) ? wrappedNative : tokenIn;
        address normalizedOut = tokenOut == address(0) ? wrappedNative : tokenOut;
        return normalizedIn != normalizedOut && (normalizedIn == wrappedNative || normalizedOut == wrappedNative);
    }

    receive() external payable {}
}

contract ImportedTokenSwapWrapperTest is Test {
    uint160 private constant Q96 = uint160(1 << 96);
    bytes32 private constant TRADE_TOPIC = keccak256("Trade(address,address,bool,uint256,uint256,uint256,uint256)");
    bytes32 private constant IMPORTED_TRADE_TOPIC = keccak256(
        "ImportedTokenTrade(address,address,address,bool,address,uint8,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,address)"
    );

    ImportedTestToken private token;
    ImportedTestToken private quote;
    ImportedTestWrappedNative private wrappedNative;
    ImportedV2FactoryMock private v2Factory;
    ImportedV2RouterMock private v2Router;
    ImportedV3FactoryMock private v3Factory;
    ImportedV3RouterMock private v3Router;
    ImportedV3QuoterMock private v3Quoter;
    ImportedCoreRouterMock private coreRouter;
    ImportedIPShareMock private ipshare;
    ImportedTokenSwapWrapper private wrapper;

    address private buyer;
    address private seller;
    address private feeAddress;
    address private sellsman;

    function setUp() public {
        token = new ImportedTestToken("Imported", "IMPORTED");
        quote = new ImportedTestToken("Quote", "QUOTE");
        wrappedNative = new ImportedTestWrappedNative();
        v2Factory = new ImportedV2FactoryMock();
        v2Router = new ImportedV2RouterMock();
        v3Factory = new ImportedV3FactoryMock();
        v3Router = new ImportedV3RouterMock();
        v3Quoter = new ImportedV3QuoterMock();
        coreRouter = new ImportedCoreRouterMock(address(wrappedNative), address(v3Router), address(v3Factory));
        ipshare = new ImportedIPShareMock();
        coreRouter.setV2(address(v2Factory), address(v2Router), true);
        coreRouter.setV3(address(v3Factory), true);

        feeAddress = makeAddr("feeAddress");
        sellsman = makeAddr("sellsman");
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        wrapper = new ImportedTokenSwapWrapper(address(coreRouter), feeAddress, address(ipshare));

        vm.deal(buyer, 100 ether);
        vm.deal(address(coreRouter), 1_000 ether);
        vm.deal(address(wrappedNative), 1_000 ether);
        token.mint(seller, 1_000 ether);
    }

    function test_buyV2WithCallerSuppliedNonNativeQuote() public {
        bytes memory sourceData = _v2Source(address(quote));
        uint256 grossInput = 1 ether;
        uint256 expectedTokenOut = 1.992 ether;

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: grossInput}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            expectedTokenOut,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(tokenOut, expectedTokenOut);
        assertEq(token.balanceOf(buyer), expectedTokenOut);
        assertEq(sellsman.balance, 0.002 ether);
        assertEq(feeAddress.balance, 0.002 ether);
        assertEq(coreRouter.bridgeSwapCount(), 1);
        assertEq(token.balanceOf(address(wrapper)), 0);
        assertEq(quote.balanceOf(address(wrapper)), 0);
    }

    function test_sellV2WithNonNativeQuoteChecksNetMinimumAndClearsAllowances() public {
        bytes memory sourceData = _v2Source(address(quote));
        uint256 amountIn = 10 ether;
        token.approve(address(wrapper), 0);
        vm.prank(seller);
        token.approve(address(wrapper), amountIn);
        uint256 sellerBalanceBefore = seller.balance;

        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            amountIn,
            19.92 ether,
            seller,
            block.timestamp + 1,
            sellsman
        );

        assertEq(nativeOut, 19.92 ether);
        assertEq(seller.balance - sellerBalanceBefore, 19.92 ether);
        assertEq(sellsman.balance, 0.04 ether);
        assertEq(feeAddress.balance, 0.04 ether);
        assertEq(quote.allowance(address(wrapper), address(coreRouter)), 0);
        assertEq(token.allowance(address(wrapper), address(v2Router)), 0);
        assertEq(token.balanceOf(address(wrapper)), 0);
        assertEq(quote.balanceOf(address(wrapper)), 0);
    }

    function test_quoteV2ReturnsFinalOutputsAfterFeesAndBridge() public {
        bytes memory sourceData = _v2Source(address(quote));

        uint256 buyOutput = wrapper.quoteBuy(address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 1 ether);
        uint256 sellOutput = wrapper.quoteSell(address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 10 ether);

        assertEq(buyOutput, 1.992 ether);
        assertEq(sellOutput, 19.92 ether);
    }

    function test_registeredMarketUsesCallerPoolAndDeployerWhenSellsmanIsZero() public {
        address deployer = makeAddr("importDeployer");
        (bytes memory sourceData, ImportedCommunityMock community,) = _registerV2Market(deployer);

        (bool registered, address storedCommunity, address storedDeployer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(storedCommunity, address(community));
        assertEq(storedDeployer, deployer);

        uint256 quoted = wrapper.quoteBuy(address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 1 ether);
        assertEq(quoted, 1.988016 ether);

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, quoted, buyer, block.timestamp + 1, address(0)
        );

        assertEq(tokenOut, quoted);
        assertEq(deployer.balance, 0.002 ether);
        assertEq(feeAddress.balance, 0.002 ether);
        assertEq(wrapper.pendingNutboxInjection(address(token)), 0.003984 ether);
    }

    function test_registeredTokenCanUseDifferentCallerPoolsAndAccruesToSameCommunity() public {
        (bytes memory v2Source, ImportedCommunityMock community,) = _registerV2Market(makeAddr("deployer"));
        (address token0, address token1) = _sort(address(token), address(quote));
        ImportedV3PoolMock pool = new ImportedV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1_000 ether);
        v3Factory.setPool(address(token), address(quote), 500, address(pool));
        bytes memory v3Source = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: address(v3Router), quoter: address(v3Quoter), pool: address(pool)
            })
        );

        vm.startPrank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, v2Source, 0, buyer, block.timestamp + 1, address(0)
        );
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V3_POOL, v3Source, 0, buyer, block.timestamp + 1, address(0)
        );
        vm.stopPrank();

        assertEq(wrapper.pendingNutboxInjection(address(token)), 0.007968 ether);
        (, address storedCommunity,) = wrapper.getImportedMarket(address(token));
        assertEq(storedCommunity, address(community));
    }

    function test_configuredRegistrarCanRegisterButCannotOverwriteMarket() public {
        address configuredRegistrar = makeAddr("registrar");
        address deployer = makeAddr("deployer");
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(token));
        ImportedCommunityMock community = new ImportedCommunityMock(address(calculator));
        wrapper.setRegistrar(configuredRegistrar);

        vm.prank(configuredRegistrar);
        wrapper.registerImportedToken(address(token), address(community), deployer);

        vm.prank(configuredRegistrar);
        vm.expectRevert(ImportedTokenSwapWrapper.MarketAlreadyRegistered.selector);
        wrapper.registerImportedToken(address(token), address(community), deployer);
    }

    function test_ownerCanUpdateImportedMarketCommunityAndDeployer() public {
        address initialDeployer = makeAddr("initialDeployer");
        (, ImportedCommunityMock initialCommunity,) = _registerV2Market(initialDeployer);
        ImportedCalculatorMock newCalculator = new ImportedCalculatorMock(address(token));
        ImportedCommunityMock newCommunity = new ImportedCommunityMock(address(newCalculator));
        address newDeployer = makeAddr("newDeployer");

        vm.warp(block.timestamp + 123);
        wrapper.updateImportedMarket(address(token), address(newCommunity), newDeployer);

        (bool registered, address storedCommunity, address storedDeployer) = wrapper.getImportedMarket(address(token));
        assertTrue(registered);
        assertEq(storedCommunity, address(newCommunity));
        assertEq(storedDeployer, newDeployer);
        assertEq(wrapper.lastNutboxInjectionAt(address(token)), block.timestamp);
        assertNotEq(storedCommunity, address(initialCommunity));
    }

    function test_updateImportedMarketIsOwnerOnlyAndValidatesBinding() public {
        address deployer = makeAddr("deployer");
        (, ImportedCommunityMock community,) = _registerV2Market(deployer);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper.updateImportedMarket(address(token), address(community), deployer);

        ImportedTestToken unregisteredToken = new ImportedTestToken("Unregistered", "NONE");
        vm.expectRevert(ImportedTokenSwapWrapper.MarketNotRegistered.selector);
        wrapper.updateImportedMarket(address(unregisteredToken), address(community), deployer);

        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        wrapper.updateImportedMarket(address(token), makeAddr("notACommunityContract"), deployer);

        vm.expectRevert(ImportedTokenSwapWrapper.InvalidMarket.selector);
        wrapper.updateImportedMarket(address(token), address(community), address(0));
    }

    function test_updateDeployerAllowsPendingButCommunityChangeRequiresFlush() public {
        address initialDeployer = makeAddr("initialDeployer");
        (bytes memory sourceData, ImportedCommunityMock initialCommunity,) = _registerV2Market(initialDeployer);
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, address(0)
        );

        uint256 pending = wrapper.pendingNutboxInjection(address(token));
        uint256 previousInjectionAt = wrapper.lastNutboxInjectionAt(address(token));
        address newDeployer = makeAddr("newDeployer");
        wrapper.updateImportedMarket(address(token), address(initialCommunity), newDeployer);

        (, address storedCommunity, address storedDeployer) = wrapper.getImportedMarket(address(token));
        assertEq(storedCommunity, address(initialCommunity));
        assertEq(storedDeployer, newDeployer);
        assertEq(wrapper.pendingNutboxInjection(address(token)), pending);
        assertEq(wrapper.lastNutboxInjectionAt(address(token)), previousInjectionAt);

        ImportedCalculatorMock newCalculator = new ImportedCalculatorMock(address(token));
        ImportedCommunityMock newCommunity = new ImportedCommunityMock(address(newCalculator));
        vm.expectRevert(
            abi.encodeWithSelector(
                ImportedTokenSwapWrapper.PendingNutboxInjectionExists.selector, address(token), pending
            )
        );
        wrapper.updateImportedMarket(address(token), address(newCommunity), newDeployer);

        vm.warp(block.timestamp + 10 minutes + 1);
        assertEq(wrapper.flushNutboxInjection(address(token)), pending);
        assertEq(wrapper.pendingNutboxInjection(address(token)), 0);

        wrapper.updateImportedMarket(address(token), address(newCommunity), newDeployer);
        (, storedCommunity,) = wrapper.getImportedMarket(address(token));
        assertEq(storedCommunity, address(newCommunity));
        assertEq(wrapper.lastNutboxInjectionAt(address(token)), block.timestamp);
    }

    function test_registeredDeployerWithIPShareUsesValueCaptureByDefault() public {
        address deployer = makeAddr("ipshareDeployer");
        (bytes memory sourceData,,) = _registerV2Market(deployer);
        ipshare.setCreated(deployer, true);

        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, type(uint256).max, address(0)
        );

        assertEq(ipshare.capturedValue(deployer), 0.002 ether);
        assertEq(deployer.balance, 0);
    }

    function test_registeredSellChargesTokenFeeAndFinalNetNativeMinimum() public {
        address deployer = makeAddr("sellDeployer");
        (bytes memory sourceData,,) = _registerV2Market(deployer);
        uint256 amountIn = 10 ether;
        vm.prank(seller);
        token.approve(address(wrapper), amountIn);

        uint256 quoted = wrapper.quoteSell(address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, amountIn);
        assertEq(quoted, 19.88016 ether);

        uint256 balanceBefore = seller.balance;
        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            amountIn,
            quoted,
            seller,
            block.timestamp + 1,
            address(0)
        );

        assertEq(nativeOut, quoted);
        assertEq(seller.balance - balanceBefore, quoted);
        assertEq(wrapper.pendingNutboxInjection(address(token)), 0.02 ether);
        assertEq(deployer.balance, 0.03992 ether);
        assertEq(feeAddress.balance, 0.03992 ether);
    }

    function test_registeredTokenFeesSettleOnceOnNextTradeAfterTenMinutes() public {
        (bytes memory sourceData,, ImportedCalculatorMock calculator) = _registerV2Market(makeAddr("deployer"));

        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, address(0)
        );
        uint256 firstFee = 0.003984 ether;
        assertEq(wrapper.pendingNutboxInjection(address(token)), firstFee);
        assertEq(calculator.injected(address(_registeredCommunity())), 0);

        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, type(uint256).max, address(0)
        );

        address community = _registeredCommunity();
        assertEq(calculator.injected(community), firstFee);
        assertEq(token.balanceOf(community), firstFee);
        assertEq(wrapper.pendingNutboxInjection(address(token)), firstFee);
    }

    function test_permissionlessFlushAndFailedInjectionRetainPendingFees() public {
        (bytes memory sourceData,, ImportedCalculatorMock calculator) = _registerV2Market(makeAddr("deployer"));
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, address(0)
        );

        vm.warp(block.timestamp + 10 minutes + 1);
        calculator.setInjectionReverts(true);
        assertEq(wrapper.flushNutboxInjection(address(token)), 0);
        assertEq(wrapper.pendingNutboxInjection(address(token)), 0.003984 ether);

        calculator.setInjectionReverts(false);
        vm.prank(makeAddr("permissionlessFlusher"));
        assertEq(wrapper.flushNutboxInjection(address(token)), 0.003984 ether);
        assertEq(wrapper.pendingNutboxInjection(address(token)), 0);
    }

    function test_createdSellsmanIPShareReceivesValueCapture() public {
        bytes memory sourceData = _v2Source(address(quote));
        ipshare.setCreated(sellsman, true);

        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(ipshare.capturedValue(sellsman), 0.002 ether);
        assertEq(address(ipshare).balance, 0.002 ether);
        assertEq(sellsman.balance, 0);
        assertEq(feeAddress.balance, 0.002 ether);
    }

    function test_ownerCanSwitchToLatestIPShare() public {
        bytes memory sourceData = _v2Source(address(quote));
        ImportedIPShareMock latestIPShare = new ImportedIPShareMock();
        latestIPShare.setCreated(sellsman, true);
        wrapper.setIPShare(address(latestIPShare));

        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(address(wrapper.ipshare()), address(latestIPShare));
        assertEq(latestIPShare.capturedValue(sellsman), 0.002 ether);
        assertEq(ipshare.capturedValue(sellsman), 0);
    }

    function test_valueCaptureFailureRevertsTradeAtomically() public {
        bytes memory sourceData = _v2Source(address(quote));
        ipshare.setCreated(sellsman, true);
        ipshare.setCaptureReverts(true);

        vm.prank(buyer);
        vm.expectRevert("capture failed");
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, sellsman
        );

        assertEq(token.balanceOf(buyer), 0);
        assertEq(address(ipshare).balance, 0);
        assertEq(feeAddress.balance, 0);
    }

    function test_directWrappedNativeMarketSkipsCoreRouter() public {
        bytes memory sourceData = _v2Source(address(wrappedNative));

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(tokenOut, 1.992 ether);
        assertEq(coreRouter.bridgeSwapCount(), 0);
    }

    function test_buyV3WithCallerSuppliedSource() public {
        (address token0, address token1) = _sort(address(token), address(quote));
        ImportedV3PoolMock pool = new ImportedV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1_000 ether);
        v3Factory.setPool(address(token), address(quote), 500, address(pool));

        bytes memory sourceData = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: address(v3Router), quoter: address(v3Quoter), pool: address(pool)
            })
        );

        assertEq(wrapper.quoteBuy(address(token), INutboxRouter.SourceType.V3_POOL, sourceData, 1 ether), 1.992 ether);
        assertEq(wrapper.quoteSell(address(token), INutboxRouter.SourceType.V3_POOL, sourceData, 10 ether), 19.92 ether);

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V3_POOL,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );
        assertEq(tokenOut, 1.992 ether);
        assertEq(token.balanceOf(buyer), 1.992 ether);
    }

    function test_sellV3ThroughNonNativeQuoteBridge() public {
        (address token0, address token1) = _sort(address(token), address(quote));
        ImportedV3PoolMock pool = new ImportedV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1_000 ether);
        v3Factory.setPool(address(token), address(quote), 500, address(pool));
        bytes memory sourceData = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: address(v3Router), quoter: address(v3Quoter), pool: address(pool)
            })
        );

        uint256 amountIn = 10 ether;
        vm.prank(seller);
        token.approve(address(wrapper), amountIn);
        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(token),
            INutboxRouter.SourceType.V3_POOL,
            sourceData,
            amountIn,
            19.92 ether,
            seller,
            block.timestamp + 1,
            sellsman
        );

        assertEq(nativeOut, 19.92 ether);
        assertEq(token.allowance(address(wrapper), address(v3Router)), 0);
        assertEq(quote.allowance(address(wrapper), address(coreRouter)), 0);
    }

    function test_buyUniswapV4WithCallerSuppliedNonNativeQuote() public {
        ImportedUniswapV4ManagerMock manager = new ImportedUniswapV4ManagerMock();
        coreRouter.setUniswapV4(address(manager), true);
        (address currency0, address currency1) = _sort(address(token), address(quote));
        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: address(manager),
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        manager.setPool(poolId, Q96, 1_000 ether);

        bytes memory sourceData = _v4Source(source);

        assertEq(
            wrapper.quoteBuy(address(token), INutboxRouter.SourceType.UNISWAP_V4, sourceData, 1 ether), 0.996 ether
        );
        assertEq(
            wrapper.quoteSell(address(token), INutboxRouter.SourceType.UNISWAP_V4, sourceData, 10 ether), 9.96 ether
        );

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.UNISWAP_V4,
            sourceData,
            0.996 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );
        assertEq(tokenOut, 0.996 ether);
        assertEq(token.balanceOf(buyer), 0.996 ether);
        assertEq(quote.balanceOf(address(wrapper)), 0);
    }

    function test_buyAndSellUniswapV4WithNativeQuoteSkipsCoreRouter() public {
        ImportedUniswapV4ManagerMock manager = new ImportedUniswapV4ManagerMock();
        coreRouter.setUniswapV4(address(manager), true);
        vm.deal(address(manager), 100 ether);

        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: address(manager),
            currency0: address(0),
            currency1: address(token),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        manager.setPool(poolId, Q96, 1_000 ether);
        bytes memory sourceData = _v4Source(source);

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.UNISWAP_V4,
            sourceData,
            0.996 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );
        assertEq(tokenOut, 0.996 ether);

        uint256 amountIn = 10 ether;
        vm.prank(seller);
        token.approve(address(wrapper), amountIn);
        uint256 sellerBalanceBefore = seller.balance;
        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(token),
            INutboxRouter.SourceType.UNISWAP_V4,
            sourceData,
            amountIn,
            9.96 ether,
            seller,
            block.timestamp + 1,
            sellsman
        );

        assertEq(nativeOut, 9.96 ether);
        assertEq(seller.balance - sellerBalanceBefore, 9.96 ether);
        assertEq(coreRouter.bridgeSwapCount(), 0);
        assertEq(address(wrapper).balance, 0);
    }

    function test_uniswapV4NonzeroHookNeedsNoRegistration() public {
        ImportedUniswapV4ManagerMock manager = new ImportedUniswapV4ManagerMock();
        coreRouter.setUniswapV4(address(manager), true);
        address hook = makeAddr("externalHook");
        (address currency0, address currency1) = _sort(address(token), address(quote));
        INutboxRouter.UniswapV4Source memory source = INutboxRouter.UniswapV4Source({
            poolManager: address(manager),
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: hook
        });
        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        manager.setPool(poolId, Q96, 1_000 ether);

        bytes memory sourceData = _v4Source(source);
        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.UNISWAP_V4,
            sourceData,
            0.996 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );
        assertEq(tokenOut, 0.996 ether);
    }

    function test_pancakeV4SourceIsNotSupportedOnRh() public {
        vm.expectRevert(ImportedTokenSwapWrapper.UnsupportedSwapSource.selector);
        wrapper.resolveQuoteToken(address(token), INutboxRouter.SourceType.PANCAKE_V4_CL, "");
    }

    function test_missingQuoteBridgeRevertsDuringTradeWithoutRegistration() public {
        bytes memory sourceData = _v2Source(address(quote));
        coreRouter.setBridgeEnabled(false);
        vm.prank(buyer);
        vm.expectRevert(ImportedCoreRouterMock.MissingRoute.selector);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, sellsman
        );
    }

    function test_resolveQuoteTokenUsesCallerSuppliedPool() public {
        bytes memory sourceData = _v2Source(address(quote));
        assertEq(
            wrapper.resolveQuoteToken(address(token), INutboxRouter.SourceType.V2_PAIR, sourceData), address(quote)
        );
    }

    function test_tradeControlsRejectPausedExpiredAndInvalidMinimums() public {
        bytes memory sourceData = _v2Source(address(quote));

        wrapper.pause();
        vm.prank(buyer);
        vm.expectRevert("Pausable: paused");
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, sellsman
        );
        wrapper.unpause();

        vm.warp(100);
        vm.prank(buyer);
        vm.expectRevert(ImportedTokenSwapWrapper.DeadlineExpired.selector);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, 99, sellsman
        );

        vm.prank(buyer);
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 1.993 ether, buyer, 101, sellsman
        );

        vm.prank(seller);
        token.approve(address(wrapper), 10 ether);
        vm.prank(seller);
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        wrapper.sellToken(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 10 ether, 19.921 ether, seller, 101, sellsman
        );
    }

    function test_invalidCallerSuppliedDexRevertsDuringExecution() public {
        (ImportedV2PairMock pair,,) = _createV2Pair(address(token), address(quote));
        bytes memory sourceData =
            abi.encode(ImportedTokenSwapWrapper.V2Source({router: address(0xdead), pair: address(pair)}));
        vm.prank(buyer);
        vm.expectRevert();
        wrapper.buyToken{value: 1 ether}(
            address(token), INutboxRouter.SourceType.V2_PAIR, sourceData, 0, buyer, block.timestamp + 1, sellsman
        );
    }

    function test_buyEmitsLegacyAndCanonicalAccountingEvents() public {
        bytes memory sourceData = _v2Source(address(quote));
        vm.recordLogs();
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundLegacy;
        bool foundCanonical;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(wrapper) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == TRADE_TOPIC) {
                foundLegacy = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), buyer);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), sellsman);
                (bool isBuy, uint256 tokenAmount, uint256 grossNative, uint256 tagaiFee, uint256 sellsmanFee) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
                assertTrue(isBuy);
                assertEq(tokenAmount, 1.992 ether);
                assertEq(grossNative, 1 ether);
                assertEq(tagaiFee, 0.002 ether);
                assertEq(sellsmanFee, 0.002 ether);
            } else if (logs[i].topics[0] == IMPORTED_TRADE_TOPIC) {
                foundCanonical = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), buyer);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(token));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), sellsman);
                (
                    bool isBuy,
                    address quoteToken,
                    uint8 sourceType,
                    bytes32 sourceHash,
                    uint256 tokenAmount,
                    uint256 grossNative,
                    uint256 netNative,
                    uint256 tagaiFee,
                    uint256 sellsmanFee,
                    uint256 nutboxTokenFee,
                    address recipient
                ) = abi.decode(
                    logs[i].data,
                    (bool, address, uint8, bytes32, uint256, uint256, uint256, uint256, uint256, uint256, address)
                );
                assertTrue(isBuy);
                assertEq(quoteToken, address(quote));
                assertEq(sourceType, uint8(INutboxRouter.SourceType.V2_PAIR));
                assertEq(sourceHash, keccak256(sourceData));
                assertEq(tokenAmount, 1.992 ether);
                assertEq(grossNative, 1 ether);
                assertEq(netNative, 0.996 ether);
                assertEq(tagaiFee, 0.002 ether);
                assertEq(sellsmanFee, 0.002 ether);
                assertEq(nutboxTokenFee, 0);
                assertEq(recipient, buyer);
            }
        }
        assertTrue(foundLegacy);
        assertTrue(foundCanonical);
    }

    function test_rejectedSellsmanFeeFallsBackAndEventsRecordActualRecipient() public {
        bytes memory sourceData = _v2Source(address(quote));
        ImportedRejectNative rejectingSellsman = new ImportedRejectNative();
        uint256 feeBalanceBefore = feeAddress.balance;

        vm.recordLogs();
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(
            address(token),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.992 ether,
            buyer,
            block.timestamp + 1,
            address(rejectingSellsman)
        );

        assertEq(feeAddress.balance - feeBalanceBefore, 0.004 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundLegacy;
        bool foundCanonical;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(wrapper) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == TRADE_TOPIC) {
                foundLegacy = true;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), feeAddress);
            } else if (logs[i].topics[0] == IMPORTED_TRADE_TOPIC) {
                foundCanonical = true;
                assertEq(address(uint160(uint256(logs[i].topics[3]))), feeAddress);
            }
        }
        assertTrue(foundLegacy);
        assertTrue(foundCanonical);
    }

    function test_v2BuyReturnsActualFeeOnTransferAmountDelivered() public {
        ImportedFeeOnTransferToken taxedToken = new ImportedFeeOnTransferToken();
        (ImportedV2PairMock pair,,) = _createV2Pair(address(taxedToken), address(quote));
        bytes memory sourceData =
            abi.encode(ImportedTokenSwapWrapper.V2Source({router: address(v2Router), pair: address(pair)}));

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(taxedToken),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            1.97208 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(tokenOut, 1.97208 ether);
        assertEq(taxedToken.balanceOf(buyer), tokenOut);
    }

    function test_v2SellUsesActualFeeOnTransferAmounts() public {
        ImportedFeeOnTransferToken taxedToken = new ImportedFeeOnTransferToken();
        (ImportedV2PairMock pair,,) = _createV2Pair(address(taxedToken), address(quote));
        bytes memory sourceData =
            abi.encode(ImportedTokenSwapWrapper.V2Source({router: address(v2Router), pair: address(pair)}));
        taxedToken.mint(seller, 10 ether);
        vm.prank(seller);
        taxedToken.approve(address(wrapper), 10 ether);

        uint256 sellerBalanceBefore = seller.balance;
        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(taxedToken),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            10 ether,
            19.523592 ether,
            seller,
            block.timestamp + 1,
            sellsman
        );

        assertEq(nativeOut, 19.523592 ether);
        assertEq(seller.balance - sellerBalanceBefore, nativeOut);
    }

    function test_registeredV2FeeOnTransferSellAccruesFeeFromActualReceivedAmount() public {
        ImportedFeeOnTransferToken taxedToken = new ImportedFeeOnTransferToken();
        (ImportedV2PairMock pair,,) = _createV2Pair(address(taxedToken), address(quote));
        bytes memory sourceData =
            abi.encode(ImportedTokenSwapWrapper.V2Source({router: address(v2Router), pair: address(pair)}));
        ImportedCalculatorMock calculator = new ImportedCalculatorMock(address(taxedToken));
        ImportedCommunityMock community = new ImportedCommunityMock(address(calculator));
        wrapper.registerImportedToken(address(taxedToken), address(community), makeAddr("taxTokenDeployer"));
        taxedToken.mint(seller, 10 ether);
        vm.prank(seller);
        taxedToken.approve(address(wrapper), 10 ether);

        vm.prank(seller);
        uint256 nativeOut = wrapper.sellToken(
            address(taxedToken),
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            10 ether,
            19.484544816 ether,
            seller,
            block.timestamp + 1,
            feeAddress
        );

        assertEq(nativeOut, 19.484544816 ether);
        assertEq(wrapper.pendingNutboxInjection(address(taxedToken)), 0.0198 ether);
        assertEq(taxedToken.balanceOf(address(wrapper)), 0.0198 ether);
    }

    function test_v3SellStillRejectsFeeOnTransferImportedToken() public {
        ImportedFeeOnTransferToken taxedToken = new ImportedFeeOnTransferToken();
        (address token0, address token1) = _sort(address(taxedToken), address(quote));
        ImportedV3PoolMock pool = new ImportedV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1_000 ether);
        v3Factory.setPool(address(taxedToken), address(quote), 500, address(pool));
        bytes memory sourceData = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: address(v3Router), quoter: address(v3Quoter), pool: address(pool)
            })
        );
        taxedToken.mint(seller, 10 ether);
        vm.prank(seller);
        taxedToken.approve(address(wrapper), 10 ether);

        vm.prank(seller);
        vm.expectRevert(ImportedTokenSwapWrapper.UnsupportedInputToken.selector);
        wrapper.sellToken(
            address(taxedToken),
            INutboxRouter.SourceType.V3_POOL,
            sourceData,
            10 ether,
            0,
            seller,
            block.timestamp + 1,
            sellsman
        );
    }

    function test_v3BuyUsesFinalFeeOnTransferAmountForSlippageProtection() public {
        ImportedFeeOnTransferToken taxedToken = new ImportedFeeOnTransferToken();
        (address token0, address token1) = _sort(address(taxedToken), address(quote));
        ImportedV3PoolMock pool = new ImportedV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1_000 ether);
        v3Factory.setPool(address(taxedToken), address(quote), 500, address(pool));
        v3Router.setTransferOutput(true);
        taxedToken.mint(address(v3Router), 100 ether);
        bytes memory sourceData = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: address(v3Router), quoter: address(v3Quoter), pool: address(pool)
            })
        );

        vm.prank(buyer);
        vm.expectRevert(ImportedTokenSwapWrapper.SlippageExceeded.selector);
        wrapper.buyToken{value: 1 ether}(
            address(taxedToken),
            INutboxRouter.SourceType.V3_POOL,
            sourceData,
            1.9523592 ether + 1,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        vm.prank(buyer);
        uint256 tokenOut = wrapper.buyToken{value: 1 ether}(
            address(taxedToken),
            INutboxRouter.SourceType.V3_POOL,
            sourceData,
            1.9523592 ether,
            buyer,
            block.timestamp + 1,
            sellsman
        );

        assertEq(tokenOut, 1.9523592 ether);
        assertEq(taxedToken.balanceOf(buyer), tokenOut);
    }

    function test_runtimeCodeSizeStaysBelowEip170Limit() public view {
        assertLt(address(wrapper).code.length, 24_576);
    }

    function test_feeAdministrationRemainsOwnerOnly() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper.setFeeRatios(50, 50, 50);

        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        wrapper.setIPShare(address(ipshare));
    }

    function test_unsolicitedV4CallbackReverts() public {
        vm.expectRevert(ImportedTokenSwapWrapper.InvalidCallback.selector);
        wrapper.unlockCallback("");
    }

    function _v2Source(address quoteToken) private returns (bytes memory sourceData) {
        (ImportedV2PairMock pair,,) = _createV2Pair(address(token), quoteToken);
        sourceData = abi.encode(ImportedTokenSwapWrapper.V2Source({router: address(v2Router), pair: address(pair)}));
    }

    function _registerV2Market(address deployer)
        private
        returns (bytes memory sourceData, ImportedCommunityMock community, ImportedCalculatorMock calculator)
    {
        sourceData = _v2Source(address(quote));
        calculator = new ImportedCalculatorMock(address(token));
        community = new ImportedCommunityMock(address(calculator));
        wrapper.registerImportedToken(address(token), address(community), deployer);
    }

    function _registeredCommunity() private view returns (address community) {
        (, community,) = wrapper.getImportedMarket(address(token));
    }

    function _v4Source(INutboxRouter.UniswapV4Source memory source) private pure returns (bytes memory sourceData) {
        sourceData = abi.encode(ImportedTokenSwapWrapper.UniswapV4Source({pool: source}));
    }

    function _createV2Pair(address tokenA, address tokenB)
        private
        returns (ImportedV2PairMock pair, address token0, address token1)
    {
        (token0, token1) = _sort(tokenA, tokenB);
        pair = new ImportedV2PairMock(address(v2Factory), token0, token1);
        pair.setReserves(1_000 ether, 1_000 ether);
        v2Factory.setPair(tokenA, tokenB, address(pair));
    }

    function _sort(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
