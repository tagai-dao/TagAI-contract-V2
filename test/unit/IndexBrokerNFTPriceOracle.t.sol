// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTPriceOracle.sol";

contract OracleTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract OracleV2FactoryMock {
    mapping(address => mapping(address => address)) public getPair;

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract OracleV2PairMock {
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

contract OracleV3FactoryMock {
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

contract OracleV3PoolMock {
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

contract OracleUniswapV4ManagerMock {
    mapping(bytes32 => bytes32) private values;

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        values[stateSlot] = bytes32(uint256(sqrtPriceX96));
        values[bytes32(uint256(stateSlot) + 3)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return values[slot];
    }
}

contract OraclePancakeV4CLManagerMock {
    mapping(bytes32 => uint160) private prices;
    mapping(bytes32 => uint128) private liquidities;

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
}

contract IndexBrokerNFTPriceOracleTest is Test {
    uint160 private constant Q96 = uint160(1 << 96);
    uint256 private constant AMOUNT = 1_000 ether;

    OracleTestToken private communityToken;
    OracleTestToken private wrappedNative;
    OracleV2FactoryMock private v2Factory;
    OracleV3FactoryMock private v3Factory;
    OracleUniswapV4ManagerMock private uniswapV4Manager;
    OraclePancakeV4CLManagerMock private pancakeV4Manager;
    IndexBrokerNFTPriceOracle private oracle;

    function setUp() public {
        communityToken = new OracleTestToken("Community", "COM");
        wrappedNative = new OracleTestToken("Wrapped Native", "WNATIVE");
        v2Factory = new OracleV2FactoryMock();
        v3Factory = new OracleV3FactoryMock();
        uniswapV4Manager = new OracleUniswapV4ManagerMock();
        pancakeV4Manager = new OraclePancakeV4CLManagerMock();

        address[] memory v2Factories = new address[](1);
        v2Factories[0] = address(v2Factory);
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = address(v3Factory);
        address[] memory uniswapV4Managers = new address[](1);
        uniswapV4Managers[0] = address(uniswapV4Manager);
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = address(pancakeV4Manager);

        oracle = new IndexBrokerNFTPriceOracle(
            address(wrappedNative), v2Factories, v3Factories, uniswapV4Managers, pancakeV4Managers
        );
    }

    function test_V2QuotesAuthenticatedPairInEitherTokenOrder() public {
        (address token0, address token1) = _sort(address(communityToken), address(wrappedNative));
        OracleV2PairMock pair = new OracleV2PairMock(address(v2Factory), token0, token1);
        v2Factory.setPair(address(communityToken), address(wrappedNative), address(pair));
        if (token0 == address(communityToken)) {
            pair.setReserves(uint112(1_000_000 ether), uint112(100 ether));
        } else {
            pair.setReserves(uint112(100 ether), uint112(1_000_000 ether));
        }

        bytes memory sourceData = abi.encode(address(v2Factory), address(pair));
        oracle.validateSource(address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR, sourceData);
        assertEq(
            oracle.quoteNative(
                address(communityToken), AMOUNT, IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR, sourceData
            ),
            0.1 ether
        );
    }

    function test_V2RejectsPairNotRegisteredByAllowedFactory() public {
        (address token0, address token1) = _sort(address(communityToken), address(wrappedNative));
        OracleV2PairMock pair = new OracleV2PairMock(address(v2Factory), token0, token1);
        pair.setReserves(1 ether, 1 ether);

        vm.expectRevert(IndexBrokerNFTPriceOracle.InvalidSource.selector);
        oracle.validateSource(
            address(communityToken),
            IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR,
            abi.encode(address(v2Factory), address(pair))
        );
    }

    function test_V3QuotesAuthenticatedPoolAndTracksSpotPrice() public {
        (address token0, address token1) = _sort(address(communityToken), address(wrappedNative));
        OracleV3PoolMock pool = new OracleV3PoolMock(address(v3Factory), token0, token1, 3_000);
        v3Factory.setPool(address(communityToken), address(wrappedNative), 3_000, address(pool));
        pool.setState(Q96, 1 ether);
        bytes memory sourceData = abi.encode(address(v3Factory), address(pool));

        assertEq(
            oracle.quoteNative(
                address(communityToken), AMOUNT, IIndexBrokerNFTPriceOracle.SourceType.V3_POOL, sourceData
            ),
            AMOUNT
        );

        pool.setState(Q96 * 2, 1 ether);
        uint256 expected = token0 == address(communityToken) ? AMOUNT * 4 : AMOUNT / 4;
        assertEq(
            oracle.quoteNative(
                address(communityToken), AMOUNT, IIndexBrokerNFTPriceOracle.SourceType.V3_POOL, sourceData
            ),
            expected
        );
    }

    function test_V3RejectsPoolNotRegisteredByAllowedFactory() public {
        (address token0, address token1) = _sort(address(communityToken), address(wrappedNative));
        OracleV3PoolMock pool = new OracleV3PoolMock(address(v3Factory), token0, token1, 500);
        pool.setState(Q96, 1 ether);

        vm.expectRevert(IndexBrokerNFTPriceOracle.InvalidSource.selector);
        oracle.validateSource(
            address(communityToken),
            IIndexBrokerNFTPriceOracle.SourceType.V3_POOL,
            abi.encode(address(v3Factory), address(pool))
        );
    }

    function test_UniswapV4QuotesNativeCurrencyPoolFromFullPoolKey() public {
        IIndexBrokerNFTPriceOracle.UniswapV4Source memory source = IIndexBrokerNFTPriceOracle.UniswapV4Source({
            poolManager: address(uniswapV4Manager),
            currency0: address(0),
            currency1: address(communityToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });
        bytes32 poolId =
            keccak256(abi.encode(source.currency0, source.currency1, source.fee, source.tickSpacing, source.hooks));
        uniswapV4Manager.setPool(poolId, Q96, 1 ether);
        bytes memory sourceData = abi.encode(source);

        oracle.validateSource(address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.UNISWAP_V4, sourceData);
        assertEq(
            oracle.quoteNative(
                address(communityToken), AMOUNT, IIndexBrokerNFTPriceOracle.SourceType.UNISWAP_V4, sourceData
            ),
            AMOUNT
        );

        source.tickSpacing = 10;
        vm.expectRevert(IndexBrokerNFTPriceOracle.PoolNotInitialized.selector);
        oracle.validateSource(
            address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.UNISWAP_V4, abi.encode(source)
        );
    }

    function test_PancakeV4CLQuotesNativeCurrencyPoolFromFullPoolKey() public {
        IIndexBrokerNFTPriceOracle.PancakeV4CLSource memory source = IIndexBrokerNFTPriceOracle.PancakeV4CLSource({
            currency0: address(0),
            currency1: address(communityToken),
            hooks: address(0),
            poolManager: address(pancakeV4Manager),
            fee: 500,
            parameters: bytes32(uint256(10))
        });
        bytes32 poolId = keccak256(
            abi.encode(
                source.currency0, source.currency1, source.hooks, source.poolManager, source.fee, source.parameters
            )
        );
        pancakeV4Manager.setPool(poolId, Q96, 1 ether);
        bytes memory sourceData = abi.encode(source);

        oracle.validateSource(address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL, sourceData);
        assertEq(
            oracle.quoteNative(
                address(communityToken), AMOUNT, IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL, sourceData
            ),
            AMOUNT
        );

        source.fee = 3_000;
        vm.expectRevert(IndexBrokerNFTPriceOracle.PoolNotInitialized.selector);
        oracle.validateSource(
            address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL, abi.encode(source)
        );
    }

    function test_V4RejectsUnapprovedPoolManager() public {
        OracleUniswapV4ManagerMock otherManager = new OracleUniswapV4ManagerMock();
        IIndexBrokerNFTPriceOracle.UniswapV4Source memory source = IIndexBrokerNFTPriceOracle.UniswapV4Source({
            poolManager: address(otherManager),
            currency0: address(0),
            currency1: address(communityToken),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });

        vm.expectRevert(IndexBrokerNFTPriceOracle.InvalidSource.selector);
        oracle.validateSource(
            address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.UNISWAP_V4, abi.encode(source)
        );
    }

    function test_RejectsZeroLiquidityAndUnrelatedQuoteAsset() public {
        (address token0, address token1) = _sort(address(communityToken), address(wrappedNative));
        OracleV3PoolMock pool = new OracleV3PoolMock(address(v3Factory), token0, token1, 100);
        v3Factory.setPool(address(communityToken), address(wrappedNative), 100, address(pool));
        pool.setState(Q96, 0);

        vm.expectRevert(IndexBrokerNFTPriceOracle.PoolNotInitialized.selector);
        oracle.validateSource(
            address(communityToken),
            IIndexBrokerNFTPriceOracle.SourceType.V3_POOL,
            abi.encode(address(v3Factory), address(pool))
        );

        OracleTestToken unrelated = new OracleTestToken("Unrelated", "OTHER");
        IIndexBrokerNFTPriceOracle.UniswapV4Source memory source = IIndexBrokerNFTPriceOracle.UniswapV4Source({
            poolManager: address(uniswapV4Manager),
            currency0: address(0),
            currency1: address(unrelated),
            fee: 3_000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vm.expectRevert(IndexBrokerNFTPriceOracle.InvalidPair.selector);
        oracle.validateSource(
            address(communityToken), IIndexBrokerNFTPriceOracle.SourceType.UNISWAP_V4, abi.encode(source)
        );
    }

    function _sort(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
