// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../src/nutbox/Committee.sol";
import "../../src/nutbox/Community.sol";
import "../../src/nutbox/CommunityFactory.sol";
import "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFT.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTAMM.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTFactory.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTPriceOracle.sol";
import "../../src/nutbox/dapps/index-broker-nft/IndexBrokerNFTRenderer.sol";

contract IndexBrokerCommunityToken is ERC20 {
    bool public listed;
    address public clPoolManager;
    bytes32 public v4PoolId;
    address public listingHook;
    bytes32 public listingPoolParameters;
    uint24 public constant LISTING_LP_FEE = 3_000;

    constructor() ERC20("Community", "COM") {
        _mint(msg.sender, 10_000_000 ether);
    }

    function configureListing(address poolManager, address hook, bytes32 parameters, bool listed_) external {
        clPoolManager = poolManager;
        listingHook = hook;
        listingPoolParameters = parameters;
        v4PoolId = keccak256(abi.encode(address(0), address(this), hook, poolManager, LISTING_LP_FEE, parameters));
        listed = listed_;
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "native transfer failed");
    }

    receive() external payable {}
}

contract IndexBrokerPumpMock {
    mapping(address => bool) public createdTokens;

    function setCreatedToken(address token, bool created) external {
        createdTokens[token] = created;
    }
}

contract IndexBrokerPancakeV4CLManagerMock {
    mapping(bytes32 => uint160) private _sqrtPriceX96;
    mapping(bytes32 => uint128) private _liquidity;

    function setPool(bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity) external {
        _sqrtPriceX96[poolId] = sqrtPriceX96;
        _liquidity[poolId] = liquidity;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return (_sqrtPriceX96[poolId], 0, 0, 3_000);
    }

    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity) {
        return _liquidity[poolId];
    }
}

contract IndexBrokerIndexTokenMock is ERC20 {
    address public wbnb;
    mapping(address => uint256) private _holderFees;

    constructor(string memory symbol_) ERC20("Index Token", symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setWbnb(address wrappedNative_) external {
        wbnb = wrappedNative_;
    }

    function fundHolderFees(address holder, uint256 amount) external {
        assert(IERC20(wbnb).transferFrom(msg.sender, address(this), amount));
        _holderFees[holder] += amount;
    }

    function claimableHolderFees(address holder) external view returns (uint256) {
        return _holderFees[holder];
    }

    function claimHolderFeesFor(address holder) external returns (uint256 amount) {
        amount = _holderFees[holder];
        delete _holderFees[holder];
        if (amount != 0) assert(IERC20(wbnb).transfer(holder, amount));
    }
}

contract IndexBrokerBasketRegistryMock {
    mapping(address => bool) public isBasket;

    function setIndexToken(address token, bool valid) external {
        isBasket[token] = valid;
    }
}

contract IndexBrokerIndexV3FactoryMock {
    mapping(bytes32 => address) private pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA, fee))];
    }
}

contract IndexBrokerIndexV3RouterMock {
    address public immutable factory;
    address public immutable WETH9;

    constructor(address factory_, address wrappedNative_) {
        factory = factory_;
        WETH9 = wrappedNative_;
    }

    function exactInputSingle(IIndexBrokerPancakeV3Router.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(params.tokenIn == WETH9 && params.amountIn == msg.value, "unexpected input");
        amountOut = msg.value * 2;
        require(amountOut >= params.amountOutMinimum, "V3 slippage");
        assert(IERC20(params.tokenOut).transfer(params.recipient, amountOut));
    }
}

contract IndexBrokerBasketSwapRouterMock {
    address public immutable settlementToken;

    constructor(address settlementToken_) {
        settlementToken = settlementToken_;
    }

    function buyExactSettlement(
        address basket,
        uint256 settlementTokenIn,
        uint256 minBasketOut,
        bytes calldata,
        address recipient
    ) external returns (uint256 basketOut) {
        assert(IERC20(settlementToken).transferFrom(msg.sender, address(this), settlementTokenIn));
        basketOut = settlementTokenIn * 3;
        require(basketOut >= minBasketOut, "slippage");
        IndexBrokerIndexTokenMock(basket).mint(recipient, basketOut);
    }
}

contract IndexBrokerV2FactoryMock {
    mapping(address => mapping(address => address)) public getPair;

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract IndexBrokerV2PairMock {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private _reserve0;
    uint112 private _reserve1;

    constructor(address factory_, address tokenA, address tokenB) {
        factory = factory_;
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function setReserves(uint112 reserve0, uint112 reserve1) external {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }
}

contract IndexBrokerNFTTest is Test {
    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    IndexBrokerNFTFactory internal poolFactory;
    Community internal community;
    IndexBrokerNFT internal pool;
    IndexBrokerNFTAMM internal amm;
    IndexBrokerCommunityToken internal communityToken;
    IndexBrokerPumpMock internal pump;
    IndexBrokerPancakeV4CLManagerMock internal pancakeV4Manager;
    ERC20 internal wrappedNative;
    IndexBrokerV2FactoryMock internal v2Factory;
    IndexBrokerV2PairMock internal v2Pair;
    IndexBrokerNFTPriceOracle internal priceOracle;
    IndexBrokerBasketRegistryMock internal basketRegistry;
    IndexBrokerIndexV3FactoryMock internal indexV3Factory;
    IndexBrokerIndexV3RouterMock internal indexV3Router;
    IndexBrokerBasketSwapRouterMock internal basketSwapRouter;
    IndexBrokerCommunityToken internal indexSettlementToken;
    IndexBrokerIndexTokenMock internal defaultIndexToken;
    uint256 internal activePoolCount;

    address internal fundsReceiver = makeAddr("fundsReceiver");
    address internal platformTreasury = makeAddr("platformTreasury");
    address internal whitelistUser1 = makeAddr("whitelistUser1");
    address internal whitelistUser2 = makeAddr("whitelistUser2");
    address internal paidUser = makeAddr("paidUser");

    uint256 internal constant COMMUNITY_TOKEN_PRICE = 1_000 ether;
    uint256 internal constant INDEX_MINING_ACTIVATION_TOKEN_AMOUNT = 100 ether;
    uint256 internal constant NATIVE_PRICE = 1 ether;
    uint256 internal constant MAX_SUPPLY = 6;
    uint16 internal constant PLATFORM_FEE_BPS = 30;
    uint16 internal constant REFERRAL_BPS = 1_000;
    uint16 internal constant AMM_NORMAL_FEE_BPS = 1_000;
    uint16 internal constant AMM_SPECIFIC_FEE_BPS = 1_500;
    uint16 internal constant AMM_PLATFORM_FEE_BPS = 50;
    uint24 internal constant INDEX_V3_FEE = 100;
    uint256 internal constant BASE_WEIGHT = 10_000;
    uint256 internal constant NFT_NATIVE_VALUE = 0.1 ether;

    function setUp() public {
        vm.warp(3_600);

        committee = new Committee(payable(platformTreasury));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        communityToken = new IndexBrokerCommunityToken();
        pump = new IndexBrokerPumpMock();
        pancakeV4Manager = new IndexBrokerPancakeV4CLManagerMock();
        wrappedNative = new IndexBrokerCommunityToken();
        v2Factory = new IndexBrokerV2FactoryMock();
        v2Pair = new IndexBrokerV2PairMock(address(v2Factory), address(communityToken), address(wrappedNative));
        v2Factory.setPair(address(communityToken), address(wrappedNative), address(v2Pair));
        _setV2Price(1_000_000 ether, 100 ether);

        address[] memory v2Factories = new address[](1);
        v2Factories[0] = address(v2Factory);
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = address(pancakeV4Manager);
        priceOracle = new IndexBrokerNFTPriceOracle(
            address(wrappedNative), v2Factories, new address[](0), new address[](0), pancakeV4Managers
        );
        basketRegistry = new IndexBrokerBasketRegistryMock();
        indexSettlementToken = new IndexBrokerCommunityToken();
        indexV3Factory = new IndexBrokerIndexV3FactoryMock();
        indexV3Router = new IndexBrokerIndexV3RouterMock(address(indexV3Factory), address(wrappedNative));
        indexV3Factory.setPool(address(wrappedNative), address(indexSettlementToken), INDEX_V3_FEE, address(v2Pair));
        basketSwapRouter = new IndexBrokerBasketSwapRouterMock(address(indexSettlementToken));
        defaultIndexToken = new IndexBrokerIndexTokenMock("DEFAULT-INDEX");
        defaultIndexToken.setWbnb(address(wrappedNative));
        basketRegistry.setIndexToken(address(defaultIndexToken), true);
        assertTrue(indexSettlementToken.transfer(address(indexV3Router), 1_000_000 ether));
        poolFactory = new IndexBrokerNFTFactory(
            address(communityFactory),
            address(pump),
            address(new IndexBrokerNFTRenderer()),
            address(new IndexBrokerNFTAMM()),
            address(priceOracle),
            address(basketRegistry),
            address(basketSwapRouter),
            address(indexV3Router),
            INDEX_V3_FEE,
            address(defaultIndexToken)
        );

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(poolFactory));

        community = Community(
            payable(communityFactory.createCommunity(
                    false, address(communityToken), address(0), bytes(""), address(calculator), bytes("")
                ))
        );

        address[] memory accounts = new address[](2);
        accounts[0] = whitelistUser1;
        accounts[1] = whitelistUser2;
        uint256[] memory allowances = new uint256[](2);
        allowances[0] = 2;
        allowances[1] = 1;

        pool = _addPool(NATIVE_PRICE, MAX_SUPPLY, REFERRAL_BPS, true, accounts, allowances);
        amm = IndexBrokerNFTAMM(payable(pool.ammVault()));

        _fundAndApprove(whitelistUser1, pool);
        _fundAndApprove(whitelistUser2, pool);
        _fundAndApprove(paidUser, pool);
    }

    function test_InitializationUsesCommunityTokenAndHasNoBatchConfiguration() public view {
        assertEq(pool.communityToken(), address(communityToken));
        assertEq(pool.communityTokenPrice(), COMMUNITY_TOKEN_PRICE);
        assertEq(pool.indexMiningActivationTokenAmount(), INDEX_MINING_ACTIVATION_TOKEN_AMOUNT);
        assertTrue(pool.rerollEnabled());
        assertEq(pool.recommitPrice(), COMMUNITY_TOKEN_PRICE);
        assertEq(pool.indexToken(), address(defaultIndexToken));
        assertEq(pool.minimumIndexMiningWeight(), 1 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);
        assertEq(pool.nativePrice(), NATIVE_PRICE);
        assertEq(pool.maxSupply(), MAX_SUPPLY);
        assertEq(pool.referralBps(), REFERRAL_BPS);
        assertEq(pool.totalWhitelistAllocation(), 3);
        assertEq(pool.whitelistAllowance(whitelistUser1), 2);
        assertEq(pool.whitelistAllowance(whitelistUser2), 1);
        assertEq(pool.remainingPaidMints(), 3);
        assertTrue(pool.lockWhitelistSlots());
        assertEq(pool.fundsReceiver(), fundsReceiver);
        assertEq(pool.getUserStakedAmount(whitelistUser1), 0);
        assertEq(amm.collection(), address(pool));
        assertEq(amm.communityToken(), address(communityToken));
        assertEq(amm.tokensPerNFT(), COMMUNITY_TOKEN_PRICE);
        assertEq(amm.normalFeeBps(), AMM_NORMAL_FEE_BPS);
        assertEq(amm.specificFeeBps(), AMM_SPECIFIC_FEE_BPS);
        assertEq(amm.priceOracle(), address(priceOracle));
        assertEq(amm.basketRegistry(), address(basketRegistry));
        assertEq(address(amm.basketSwapRouter()), address(basketSwapRouter));
        assertEq(address(amm.indexV3Router()), address(indexV3Router));
        assertEq(amm.indexWrappedNative(), address(wrappedNative));
        assertEq(amm.indexSettlementToken(), address(indexSettlementToken));
        assertEq(amm.indexV3Fee(), INDEX_V3_FEE);
        assertEq(amm.indexToken(), address(defaultIndexToken));
        assertEq(amm.platformFeeReceiver(), platformTreasury);
        assertTrue(amm.active());
        assertEq(uint8(amm.priceSourceType()), uint8(IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR));
        assertEq(amm.quoteNativeValue(), NFT_NATIVE_VALUE);
        uint256 platformFee = NFT_NATIVE_VALUE * AMM_PLATFORM_FEE_BPS / 10_000;
        assertEq(amm.PLATFORM_FEE_BPS(), AMM_PLATFORM_FEE_BPS);
        assertEq(amm.quotePlatformNativeFee(), platformFee);
        assertEq(amm.quoteNormalTradingNativeFee(), NFT_NATIVE_VALUE * AMM_NORMAL_FEE_BPS / 10_000);
        assertEq(amm.quoteSpecificTradingNativeFee(), NFT_NATIVE_VALUE * AMM_SPECIFIC_FEE_BPS / 10_000);
        assertEq(amm.quoteNormalNativeFee(), NFT_NATIVE_VALUE * AMM_NORMAL_FEE_BPS / 10_000 + platformFee);
        assertEq(amm.quoteSpecificNativeFee(), NFT_NATIVE_VALUE * AMM_SPECIFIC_FEE_BPS / 10_000 + platformFee);
    }

    function test_ExternalTokenRequiresPriceSourceAtCreation() public {
        (Community externalCommunity,) = _createCommunity(false);

        vm.expectRevert(IndexBrokerNFTAMM.ExternalPriceSourceRequired.selector);
        this.addPoolToCommunityForRevertTest(externalCommunity, bytes(""));
    }

    function test_ExternalTokenCreatesImmediatelyActiveAMM() public view {
        assertFalse(pump.createdTokens(address(communityToken)));
        assertTrue(amm.active());
        assertEq(uint8(amm.priceSourceType()), uint8(IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR));
        assertEq(amm.priceSourceData(), abi.encode(address(v2Factory), address(v2Pair)));
    }

    function test_OfficialTokenRejectsConfiguredSourceAtCreation() public {
        (Community officialCommunity,) = _createCommunity(true);

        vm.expectRevert(IndexBrokerNFTAMM.OfficialPriceSourceMustBeAutomatic.selector);
        this.addPoolToCommunityForRevertTest(officialCommunity, abi.encode(address(v2Factory), address(v2Pair)));
    }

    function test_OfficialTokenStartsInactiveButMintCanSeedReserve() public {
        (Community officialCommunity, IndexBrokerCommunityToken officialToken) = _createCommunity(true);
        IndexBrokerNFT officialPool = _addPoolToCommunity(officialCommunity, bytes(""));
        IndexBrokerNFTAMM officialAMM = IndexBrokerNFTAMM(payable(officialPool.ammVault()));

        assertFalse(officialAMM.active());
        assertEq(officialAMM.priceSourceData().length, 0);

        assertTrue(officialToken.transfer(paidUser, COMMUNITY_TOKEN_PRICE));
        vm.prank(paidUser);
        officialToken.approve(address(officialPool), COMMUNITY_TOKEN_PRICE);
        vm.prank(paidUser);
        officialPool.mint(0);

        assertEq(officialToken.balanceOf(address(officialAMM)), COMMUNITY_TOKEN_PRICE);
        assertEq(officialPool.ownerOf(1), paidUser);

        vm.expectRevert(IndexBrokerNFTAMM.AMMInactive.selector);
        officialAMM.quoteNormalNativeFee();

        vm.expectRevert(IndexBrokerNFTAMM.AMMInactive.selector);
        vm.prank(paidUser);
        officialAMM.sellNFT(1);
    }

    function test_ArbitraryCallerCannotActivateUnlistedOfficialToken() public {
        (Community officialCommunity,) = _createCommunity(true);
        IndexBrokerNFT officialPool = _addPoolToCommunity(officialCommunity, bytes(""));
        IndexBrokerNFTAMM officialAMM = IndexBrokerNFTAMM(payable(officialPool.ammVault()));

        vm.expectRevert(IndexBrokerNFTAMM.OfficialTokenNotListed.selector);
        vm.prank(paidUser);
        officialAMM.activate();

        assertFalse(officialAMM.active());
        assertEq(officialAMM.priceSourceData().length, 0);
    }

    function test_UnlistedOfficialTokenActivatesAfterListingOnlyOnce() public {
        (Community officialCommunity, IndexBrokerCommunityToken officialToken) = _createCommunity(true);
        IndexBrokerNFT officialPool = _addPoolToCommunity(officialCommunity, bytes(""));
        IndexBrokerNFTAMM officialAMM = IndexBrokerNFTAMM(payable(officialPool.ammVault()));
        address listingHook = makeAddr("listingHook");
        bytes32 parameters = bytes32(uint256(0x1234));

        officialToken.configureListing(address(pancakeV4Manager), listingHook, parameters, true);
        pancakeV4Manager.setPool(officialToken.v4PoolId(), uint160(1 << 96), 1_000_000);

        vm.prank(paidUser);
        officialAMM.activate();

        assertTrue(officialAMM.active());
        assertEq(uint8(officialAMM.priceSourceType()), uint8(IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL));
        IIndexBrokerNFTPriceOracle.PancakeV4CLSource memory source =
            abi.decode(officialAMM.priceSourceData(), (IIndexBrokerNFTPriceOracle.PancakeV4CLSource));
        assertEq(source.currency0, address(0));
        assertEq(source.currency1, address(officialToken));
        assertEq(source.hooks, listingHook);
        assertEq(source.poolManager, address(pancakeV4Manager));
        assertEq(source.fee, officialToken.LISTING_LP_FEE());
        assertEq(source.parameters, parameters);
        assertEq(officialAMM.quoteNativeValue(), COMMUNITY_TOKEN_PRICE);

        vm.expectRevert(IndexBrokerNFTAMM.AMMAlreadyActive.selector);
        vm.prank(whitelistUser1);
        officialAMM.activate();
    }

    function test_ExternalTokenCannotUseOfficialActivation() public {
        vm.expectRevert(IndexBrokerNFTAMM.NotOfficialToken.selector);
        vm.prank(paidUser);
        amm.activate();
    }

    function test_AlreadyListedOfficialTokenCreatesImmediatelyActiveAMM() public {
        (Community officialCommunity, IndexBrokerCommunityToken officialToken) = _createCommunity(true);
        address listingHook = makeAddr("alreadyListedHook");
        bytes32 parameters = bytes32(uint256(0x5678));

        officialToken.configureListing(address(pancakeV4Manager), listingHook, parameters, true);
        pancakeV4Manager.setPool(officialToken.v4PoolId(), uint160(1 << 96), 1_000_000);

        vm.recordLogs();
        IndexBrokerNFT officialPool = _addPoolToCommunity(officialCommunity, bytes(""));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IndexBrokerNFTAMM officialAMM = IndexBrokerNFTAMM(payable(officialPool.ammVault()));

        assertTrue(officialAMM.active());
        assertEq(uint8(officialAMM.priceSourceType()), uint8(IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL));
        IIndexBrokerNFTPriceOracle.PancakeV4CLSource memory source =
            abi.decode(officialAMM.priceSourceData(), (IIndexBrokerNFTPriceOracle.PancakeV4CLSource));
        assertEq(source.currency0, address(0));
        assertEq(source.currency1, address(officialToken));
        assertEq(source.hooks, listingHook);
        assertEq(source.poolManager, address(pancakeV4Manager));
        assertEq(source.fee, officialToken.LISTING_LP_FEE());
        assertEq(source.parameters, parameters);
        assertEq(officialAMM.quoteNativeValue(), COMMUNITY_TOKEN_PRICE);

        bytes32 createdEventSignature =
            keccak256("IndexBrokerNFTAMMCreated(address,address,address,uint8,bool,uint16,uint16,address)");
        bool foundCreatedEvent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(poolFactory) || logs[i].topics[0] != createdEventSignature) continue;

            (
                address emittedOracle,
                uint8 emittedSourceType,
                bool emittedActive,
                uint16 emittedNormalFeeBps,
                uint16 emittedSpecificFeeBps,
                address emittedIndexToken
            ) = abi.decode(logs[i].data, (address, uint8, bool, uint16, uint16, address));
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(officialPool));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(officialAMM));
            assertEq(emittedOracle, address(priceOracle));
            assertEq(emittedSourceType, uint8(IIndexBrokerNFTPriceOracle.SourceType.PANCAKE_V4_CL));
            assertTrue(emittedActive);
            assertEq(emittedNormalFeeBps, AMM_NORMAL_FEE_BPS);
            assertEq(emittedSpecificFeeBps, AMM_SPECIFIC_FEE_BPS);
            assertEq(emittedIndexToken, address(defaultIndexToken));
            foundCreatedEvent = true;
            break;
        }
        assertTrue(foundCreatedEvent);

        vm.expectRevert(IndexBrokerNFTAMM.AMMAlreadyActive.selector);
        officialAMM.activate();
    }

    function test_AlreadyListedOfficialTokenRequiresInitializedV4PoolAtCreation() public {
        (Community officialCommunity, IndexBrokerCommunityToken officialToken) = _createCommunity(true);
        officialToken.configureListing(
            address(pancakeV4Manager), makeAddr("uninitializedPoolHook"), bytes32(uint256(0x9abc)), true
        );

        vm.expectRevert(IndexBrokerNFTPriceOracle.PoolNotInitialized.selector);
        this.addPoolToCommunityForRevertTest(officialCommunity, bytes(""));
    }

    function test_MintStartsIndexMiningActiveWithoutBurningTokens() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        assertTrue(pool.indexMiningActiveOf(1));
        assertTrue(pool.miningActiveOf(1));
        assertEq(pool.activeMiningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.getUserStakedAmount(whitelistUser1), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()), 0);

        vm.expectRevert(IndexBrokerNFT.IndexMiningAlreadyActive.selector);
        vm.prank(whitelistUser1);
        pool.activateIndexMining(1);

        vm.expectRevert(IndexBrokerNFT.NotTokenOwner.selector);
        vm.prank(whitelistUser2);
        pool.activateIndexMining(1);
    }

    function test_MintStartsUnrevealedAndOnlyOwnerCanRevealAfterTargetBlock() public {
        uint256 mintBlock = block.number;
        _mintWhitelist(whitelistUser1, 0, 0);

        IndexBrokerNFT.NFTInfo memory beforeReveal = pool.getNFTInfo(1);
        assertEq(beforeReveal.seed, 0);
        assertEq(beforeReveal.revealBlock, mintBlock + 3);
        assertEq(beforeReveal.revealRound, 1);
        assertTrue(beforeReveal.revealPending);
        assertTrue(_contains(pool.tokenSVG(1), "UNREVEALED"));

        vm.expectRevert(IndexBrokerNFT.RevealNotReady.selector);
        vm.prank(whitelistUser1);
        pool.reveal(1);

        vm.roll(beforeReveal.revealBlock + 1);
        vm.expectRevert(IndexBrokerNFT.NotTokenOwner.selector);
        vm.prank(makeAddr("nonOwnerRevealer"));
        pool.reveal(1);

        vm.prank(whitelistUser1);
        uint256 seed = pool.reveal(1);

        IndexBrokerNFT.NFTInfo memory afterReveal = pool.getNFTInfo(1);
        assertEq(afterReveal.seed, seed);
        assertGt(seed, 0);
        assertFalse(afterReveal.revealPending);
        assertFalse(_contains(pool.tokenSVG(1), "UNREVEALED"));
    }

    function test_PaidRecommitBurnsCustomPriceKeepsOldImageAndCanRevealNewSeed() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        uint256 customPrice = 321 ether;
        IndexBrokerNFT customPool =
            _addPoolWithRevealConfig(NATIVE_PRICE, 2, 0, false, accounts, allowances, true, customPrice);
        _fundAndApprove(whitelistUser1, customPool);

        vm.prank(whitelistUser1);
        customPool.mint(0);
        IndexBrokerNFT.NFTInfo memory firstCommit = customPool.getNFTInfo(1);
        vm.roll(firstCommit.revealBlock + 1);
        vm.prank(whitelistUser1);
        uint256 firstSeed = customPool.reveal(1);

        uint256 burnBefore = communityToken.balanceOf(customPool.INDEX_MINING_BURN_ADDRESS());
        vm.prank(whitelistUser1);
        customPool.commitReveal(1);

        IndexBrokerNFT.NFTInfo memory reroll = customPool.getNFTInfo(1);
        assertEq(customPool.recommitPrice(), customPrice);
        assertEq(communityToken.balanceOf(customPool.INDEX_MINING_BURN_ADDRESS()) - burnBefore, customPrice);
        assertEq(reroll.seed, firstSeed);
        assertEq(reroll.revealRound, 2);
        assertTrue(reroll.revealPending);
        assertFalse(_contains(customPool.tokenSVG(1), "UNREVEALED"));

        vm.roll(reroll.revealBlock + 1);
        vm.prank(whitelistUser1);
        uint256 secondSeed = customPool.reveal(1);
        assertNotEq(secondSeed, firstSeed);
        assertEq(customPool.getNFTInfo(1).seed, secondSeed);
    }

    function test_ExpiredCommitMustBePaidAgainAndKeepsCurrentSeed() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        IndexBrokerNFT.NFTInfo memory firstCommit = pool.getNFTInfo(1);
        vm.roll(firstCommit.revealBlock + 1);
        vm.prank(whitelistUser1);
        uint256 oldSeed = pool.reveal(1);

        vm.prank(whitelistUser1);
        pool.commitReveal(1);
        IndexBrokerNFT.NFTInfo memory paidCommit = pool.getNFTInfo(1);

        vm.expectRevert(IndexBrokerNFT.RevealStillPending.selector);
        vm.prank(whitelistUser1);
        pool.commitReveal(1);

        vm.roll(paidCommit.revealBlock + pool.REVEAL_WINDOW_BLOCKS() + 1);
        vm.expectRevert(IndexBrokerNFT.RevealExpired.selector);
        vm.prank(whitelistUser1);
        pool.reveal(1);

        uint256 burnBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());
        vm.prank(whitelistUser1);
        pool.commitReveal(1);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()) - burnBefore, pool.recommitPrice());
        assertEq(pool.getNFTInfo(1).seed, oldSeed);
        assertEq(pool.getNFTInfo(1).revealRound, 3);
    }

    function test_RerollDisabledStillAllowsExpiredInitialCommitButNotPostRevealReroll() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFT fixedPool =
            _addPoolWithRevealConfig(NATIVE_PRICE, 2, 0, false, accounts, allowances, false, 77 ether);
        _fundAndApprove(whitelistUser1, fixedPool);

        vm.prank(whitelistUser1);
        fixedPool.mint(0);
        IndexBrokerNFT.NFTInfo memory initial = fixedPool.getNFTInfo(1);
        assertEq(fixedPool.recommitPrice(), 0);
        vm.roll(initial.revealBlock + fixedPool.REVEAL_WINDOW_BLOCKS() + 1);

        uint256 burnBefore = communityToken.balanceOf(fixedPool.INDEX_MINING_BURN_ADDRESS());
        vm.prank(whitelistUser1);
        fixedPool.commitReveal(1);
        assertEq(communityToken.balanceOf(fixedPool.INDEX_MINING_BURN_ADDRESS()), burnBefore);
        IndexBrokerNFT.NFTInfo memory retry = fixedPool.getNFTInfo(1);

        vm.roll(retry.revealBlock + fixedPool.REVEAL_WINDOW_BLOCKS() + 1);
        vm.prank(whitelistUser1);
        fixedPool.commitReveal(1);
        assertEq(communityToken.balanceOf(fixedPool.INDEX_MINING_BURN_ADDRESS()), burnBefore);
        retry = fixedPool.getNFTInfo(1);
        vm.roll(retry.revealBlock + 1);
        vm.prank(whitelistUser1);
        fixedPool.reveal(1);

        vm.expectRevert(IndexBrokerNFT.RerollDisabled.selector);
        vm.prank(whitelistUser1);
        fixedPool.commitReveal(1);
    }

    function test_RendererProvidesTokenAndCollectionMetadataAfterIndexUpgrade() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 5 ether);

        assertGt(bytes(pool.tokenURI(1)).length, 0);
        assertGt(bytes(pool.tokenSVG(1)).length, 0);
        assertGt(bytes(pool.contractURI()).length, 0);
        assertEq(pool.getNFTInfo(1).indexMiningWeight, 5 ether);
    }

    function test_EveryTransferClearsOnlyIndexMiningActivation() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, whitelistUser2, 1);

        assertEq(pool.ownerOf(1), whitelistUser2);
        assertFalse(pool.indexMiningActiveOf(1));
        assertTrue(pool.miningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser1), 0);
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);

        uint256 burnBalanceBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());
        vm.prank(whitelistUser2);
        pool.activateIndexMining(1);
        assertEq(
            communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()) - burnBalanceBefore,
            INDEX_MINING_ACTIVATION_TOKEN_AMOUNT
        );
        assertTrue(pool.indexMiningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);

        vm.prank(whitelistUser2);
        pool.transferFrom(whitelistUser2, whitelistUser2, 1);
        assertFalse(pool.indexMiningActiveOf(1));
        assertTrue(pool.miningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_IndexMiningUpgradeRequiresActiveNFTAndBurnsCommunityTokens() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        uint256 burnBalanceBefore = communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS());

        vm.expectRevert(IndexBrokerNFT.InvalidIndexMiningWeight.selector);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 1 ether - 1);

        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 100 ether);

        assertEq(pool.indexMiningWeightOf(1), 100 ether);
        assertEq(pool.activeIndexMiningWeightOf(1), 100 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 100 ether);
        assertEq(communityToken.balanceOf(pool.INDEX_MINING_BURN_ADDRESS()) - burnBalanceBefore, 100 ether);
        assertEq(pool.getUserStakedAmount(whitelistUser1), BASE_WEIGHT);

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, whitelistUser2, 1);
        assertEq(pool.indexMiningWeightOf(1), 80 ether);
        assertEq(pool.activeIndexMiningWeightOf(1), 0);
        assertEq(pool.totalActiveIndexMiningWeight(), 0);

        vm.expectRevert(IndexBrokerNFT.IndexMiningNotActive.selector);
        vm.prank(whitelistUser2);
        pool.upgradeIndexMining(1, 10 ether);

        vm.prank(whitelistUser2);
        pool.activateIndexMining(1);
        vm.prank(whitelistUser2);
        pool.upgradeIndexMining(1, 20 ether);
        assertEq(pool.indexMiningWeightOf(1), 100 ether);
        assertEq(pool.totalActiveIndexMiningWeight(), 100 ether);
    }

    function test_EachTransferRetainsEightyPercentAndDropsBelowOneTokenToZero() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 3 ether);

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, whitelistUser2, 1);
        assertEq(pool.indexMiningWeightOf(1), 2.4 ether);

        vm.prank(whitelistUser2);
        pool.transferFrom(whitelistUser2, paidUser, 1);
        assertEq(pool.indexMiningWeightOf(1), 1.92 ether);

        vm.prank(paidUser);
        pool.transferFrom(paidUser, whitelistUser1, 1);
        assertEq(pool.indexMiningWeightOf(1), 1.536 ether);

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, whitelistUser2, 1);
        assertEq(pool.indexMiningWeightOf(1), 1.2288 ether);

        vm.prank(whitelistUser2);
        pool.transferFrom(whitelistUser2, paidUser, 1);
        assertEq(pool.indexMiningWeightOf(1), 0);
        assertFalse(pool.indexMiningActiveOf(1));
    }

    function test_PublicInjectionDistributesByActiveNFTWeightAndRewardsFollowNFT() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser2, 0, 0);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 100 ether);
        vm.prank(whitelistUser2);
        pool.upgradeIndexMining(2, 300 ether);

        address injector = makeAddr("indexRewardInjector");
        defaultIndexToken.mint(injector, 400 ether);
        vm.prank(injector);
        defaultIndexToken.approve(address(pool), 400 ether);
        vm.prank(injector);
        pool.injectIndexRewards(400 ether);

        assertEq(pool.pendingIndexRewardsOf(1), 100 ether);
        assertEq(pool.pendingIndexRewardsOf(2), 300 ether);
        assertEq(pool.queuedIndexRewards(), 0);

        vm.prank(whitelistUser1);
        assertEq(pool.claimIndexRewards(1), 100 ether);
        assertEq(defaultIndexToken.balanceOf(whitelistUser1), 100 ether);

        vm.prank(whitelistUser2);
        pool.transferFrom(whitelistUser2, paidUser, 2);
        assertEq(pool.indexMiningWeightOf(2), 240 ether);
        assertFalse(pool.indexMiningActiveOf(2));
        assertEq(pool.pendingIndexRewardsOf(2), 300 ether);

        vm.prank(paidUser);
        assertEq(pool.claimIndexRewards(2), 300 ether);
        assertEq(defaultIndexToken.balanceOf(paidUser), 300 ether);
        assertEq(pool.totalIndexRewardsClaimed(), 400 ether);
    }

    function test_IndexRewardsQueueUntilAnActiveNFTGetsWeight() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        defaultIndexToken.mint(address(this), 90 ether);
        defaultIndexToken.approve(address(pool), 90 ether);
        pool.injectIndexRewards(90 ether);

        assertEq(pool.queuedIndexRewards(), 90 ether);
        assertEq(pool.pendingIndexRewardsOf(1), 0);

        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 10 ether);
        assertEq(pool.queuedIndexRewards(), 0);
        assertEq(pool.pendingIndexRewardsOf(1), 90 ether);
    }

    function test_WhitelistMintTakesPriorityRefundsNativeAndIgnoresReferral() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        uint256 nativeBefore = whitelistUser2.balance;
        uint256 platformBefore = platformTreasury.balance;
        uint256 receiverBefore = fundsReceiver.balance;

        vm.prank(whitelistUser2);
        uint256 tokenId = pool.mint{value: NATIVE_PRICE}(1);

        assertEq(tokenId, 2);
        assertEq(whitelistUser2.balance, nativeBefore);
        assertEq(platformTreasury.balance, platformBefore);
        assertEq(fundsReceiver.balance, receiverBefore);
        assertEq(pool.getNFTInfo(1).referralCount, 0);
        assertEq(pool.getNFTInfo(2).referrerTokenId, 0);
        assertEq(pool.whitelistMintedBy(whitelistUser2), 1);
        assertEq(pool.paidMinted(), 0);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 2);
    }

    function test_PaidMintDepositsCommunityTokenAndSplitsOnlyNativePayment() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        uint256 payerTokenBefore = communityToken.balanceOf(paidUser);
        uint256 poolTokenBefore = communityToken.balanceOf(address(amm));
        uint256 referrerNativeBefore = whitelistUser1.balance;
        uint256 platformBefore = platformTreasury.balance;
        uint256 receiverBefore = fundsReceiver.balance;

        vm.prank(paidUser);
        uint256 childId = pool.mint{value: NATIVE_PRICE}(1);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        uint256 referralCommission = (NATIVE_PRICE - platformFee) * REFERRAL_BPS / 10_000;
        assertEq(payerTokenBefore - communityToken.balanceOf(paidUser), COMMUNITY_TOKEN_PRICE);
        assertEq(communityToken.balanceOf(address(amm)) - poolTokenBefore, COMMUNITY_TOKEN_PRICE);
        assertEq(whitelistUser1.balance - referrerNativeBefore, referralCommission);
        assertEq(platformTreasury.balance - platformBefore, platformFee);
        assertEq(fundsReceiver.balance - receiverBefore, NATIVE_PRICE - platformFee - referralCommission);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
        assertEq(pool.getNFTInfo(childId).referrerTokenId, 1);
        assertEq(pool.paidMinted(), 1);
    }

    function test_PaidReferralsUpgradeWhitelistMintedNFT() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintPaid(paidUser, 1);
        _mintPaid(paidUser, 1);

        IndexBrokerNFT.NFTInfo memory referrer = pool.getNFTInfo(1);
        assertEq(referrer.referralCount, 2);
        assertEq(referrer.level, 2);
        assertEq(referrer.miningWeight, 12_000);
        assertTrue(referrer.miningActive);
        assertTrue(referrer.indexMiningActive);
        assertEq(pool.getUserStakedAmount(whitelistUser1), 12_000);
        assertEq(pool.getUserStakedAmount(paidUser), BASE_WEIGHT * 2);
        assertEq(pool.getTotalStakedAmount(), 32_000);
    }

    function test_WhitelistAccountUsesPaidPathAfterAllowanceIsExhausted() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);

        vm.prank(whitelistUser1);
        uint256 paidTokenId = pool.mint{value: NATIVE_PRICE}(1);

        assertEq(pool.whitelistMintedBy(whitelistUser1), 2);
        assertEq(pool.paidMinted(), 1);
        assertEq(pool.getNFTInfo(1).referralCount, 1);
        assertEq(pool.getNFTInfo(paidTokenId).referrerTokenId, 1);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 3);
    }

    function test_LockedWhitelistSlotsCannotBeConsumedByPaidMints() public {
        for (uint256 i; i < 3; ++i) {
            _mintPaid(paidUser, 0);
        }

        vm.expectRevert(IndexBrokerNFT.PaidSupplyReached.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE}(0);

        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser2, 0, 0);

        assertEq(pool.totalSupply(), MAX_SUPPLY);
        assertEq(pool.paidMinted(), 3);
        assertEq(pool.whitelistMinted(), 3);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * MAX_SUPPLY);
    }

    function test_UnlockedWhitelistSlotsCanBeConsumedByPaidMints() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFT unlockedPool = _addPool(NATIVE_PRICE, 3, REFERRAL_BPS, false, accounts, allowances);
        _fundAndApprove(whitelistUser1, unlockedPool);
        _fundAndApprove(paidUser, unlockedPool);

        for (uint256 i; i < 3; ++i) {
            vm.prank(paidUser);
            unlockedPool.mint{value: NATIVE_PRICE}(0);
        }

        vm.expectRevert(IndexBrokerNFT.MaxSupplyReached.selector);
        vm.prank(whitelistUser1);
        unlockedPool.mint(0);
        assertEq(unlockedPool.paidMinted(), 3);
        assertEq(unlockedPool.whitelistMinted(), 0);
    }

    function test_PureWhitelistRequiresAllocationEqualToSupply() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 2;

        vm.expectRevert(IndexBrokerNFT.InvalidWhitelistConfig.selector);
        this.addPoolForRevertTest(0, 3, 0, false, accounts, allowances);
    }

    function test_PureWhitelistMintsEqualBaseWeightWithoutReferralUpgrade() public {
        address[] memory accounts = new address[](2);
        accounts[0] = whitelistUser1;
        accounts[1] = whitelistUser2;
        uint256[] memory allowances = new uint256[](2);
        allowances[0] = 2;
        allowances[1] = 1;
        IndexBrokerNFT whitelistPool = _addPool(0, 3, 0, false, accounts, allowances);
        _fundAndApprove(whitelistUser1, whitelistPool);
        _fundAndApprove(whitelistUser2, whitelistPool);

        vm.prank(whitelistUser1);
        whitelistPool.mint(0);
        vm.prank(whitelistUser2);
        whitelistPool.mint(1);
        assertTrue(whitelistPool.lockWhitelistSlots());
        assertEq(whitelistPool.getNFTInfo(1).referralCount, 0);
        assertEq(whitelistPool.getNFTInfo(2).referrerTokenId, 0);
        assertEq(whitelistPool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(whitelistPool.miningWeightOf(2), BASE_WEIGHT);
        assertEq(whitelistPool.getUserStakedAmount(whitelistUser1), BASE_WEIGHT);
        assertEq(whitelistPool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);

        vm.expectRevert(IndexBrokerNFT.WhitelistOnly.selector);
        vm.prank(paidUser);
        whitelistPool.mint(0);
    }

    function test_FundsReceiverCanChangeAndOnlyReceivesNativeProceeds() public {
        address newReceiver = makeAddr("newReceiver");
        pool.setFundsReceiver(newReceiver);
        uint256 communityBalanceBefore = communityToken.balanceOf(address(amm));

        _mintPaid(paidUser, 0);

        uint256 platformFee = NATIVE_PRICE * PLATFORM_FEE_BPS / 10_000;
        assertEq(newReceiver.balance, NATIVE_PRICE - platformFee);
        assertEq(fundsReceiver.balance, 0);
        assertEq(communityToken.balanceOf(address(amm)) - communityBalanceBefore, COMMUNITY_TOKEN_PRICE);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(paidUser);
        pool.setFundsReceiver(paidUser);
    }

    function test_PaidMintRequiresExactNativePayment() public {
        vm.expectRevert(IndexBrokerNFT.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE - 1}(0);

        vm.expectRevert(IndexBrokerNFT.InvalidPayment.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE + 1}(0);

        assertEq(pool.totalSupply(), 0);
        assertEq(communityToken.balanceOf(address(amm)), 0);
    }

    function test_CommunityTokensRemainInAMMReserveAcrossWhitelistAndPaidMints() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintPaid(paidUser, 1);

        assertEq(communityToken.balanceOf(address(pool)), 0);
        assertEq(communityToken.balanceOf(address(amm)), COMMUNITY_TOKEN_PRICE * 2);
        assertEq(communityToken.balanceOf(fundsReceiver), 0);
        assertEq(communityToken.balanceOf(platformTreasury), 0);
        assertEq(communityToken.balanceOf(whitelistUser1), 100_000 ether - COMMUNITY_TOKEN_PRICE);
    }

    function test_DirectNFTTransferToAMMIsRejected() public {
        _mintWhitelist(whitelistUser1, 0, 0);

        vm.expectRevert(IndexBrokerNFT.InvalidAMMTransfer.selector);
        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, address(amm), 1);

        assertEq(pool.ownerOf(1), whitelistUser1);
        assertTrue(pool.miningActiveOf(1));
        assertTrue(pool.indexMiningActiveOf(1));
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMCustodyClearsIndexActivationAndRestoresCommunityMiningOnExit() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        bytes memory acceptanceCall = abi.encodeCall(IndexBrokerNFTAMM.isAcceptingNFT, (whitelistUser1, 1));
        vm.mockCall(address(amm), acceptanceCall, abi.encode(true));

        vm.prank(whitelistUser1);
        pool.transferFrom(whitelistUser1, address(amm), 1);

        assertEq(pool.ownerOf(1), address(amm));
        assertEq(pool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.activeMiningWeightOf(1), 0);
        assertEq(pool.getNFTInfo(1).miningWeight, BASE_WEIGHT);
        assertFalse(pool.getNFTInfo(1).miningActive);
        assertFalse(pool.miningActiveOf(1));
        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser1), 0);
        assertEq(pool.getTotalStakedAmount(), 0);

        vm.expectRevert(IndexBrokerNFT.ReferrerInAMM.selector);
        vm.prank(paidUser);
        pool.mint{value: NATIVE_PRICE}(1);

        vm.prank(address(amm));
        pool.safeTransferFrom(address(amm), whitelistUser2, 1);

        assertEq(pool.ownerOf(1), whitelistUser2);
        assertEq(pool.miningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.activeMiningWeightOf(1), BASE_WEIGHT);
        assertTrue(pool.getNFTInfo(1).miningActive);
        assertTrue(pool.miningActiveOf(1));
        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);

        vm.prank(whitelistUser2);
        pool.activateIndexMining(1);
        assertTrue(pool.indexMiningActiveOf(1));
        assertEq(pool.activeMiningWeightOf(1), BASE_WEIGHT);
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMSellAndBuyUseSpotNativeFeeAndRefundExcess() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(1, 100 ether);
        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);

        uint256 tradingFee = NFT_NATIVE_VALUE * AMM_NORMAL_FEE_BPS / 10_000;
        uint256 platformFee = NFT_NATIVE_VALUE * AMM_PLATFORM_FEE_BPS / 10_000;
        uint256 totalFee = tradingFee + platformFee;
        uint256 sellerNativeBefore = whitelistUser1.balance;
        uint256 sellerTokenBefore = communityToken.balanceOf(whitelistUser1);
        uint256 platformBefore = platformTreasury.balance;
        vm.prank(whitelistUser1);
        amm.sellNFT{value: totalFee + 0.02 ether}(1);

        assertEq(whitelistUser1.balance, sellerNativeBefore - totalFee);
        assertEq(communityToken.balanceOf(whitelistUser1), sellerTokenBefore + COMMUNITY_TOKEN_PRICE);
        assertEq(address(amm).balance, tradingFee);
        assertEq(platformTreasury.balance - platformBefore, platformFee);
        assertEq(amm.inventoryCount(), 1);
        assertEq(amm.oldestTokenId(), 1);
        assertEq(pool.activeMiningWeightOf(1), 0);
        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 80 ether);

        uint256 buyerNativeBefore = paidUser.balance;
        uint256 buyerTokenBefore = communityToken.balanceOf(paidUser);
        vm.prank(paidUser);
        uint256 boughtTokenId = amm.buyNextNFT{value: totalFee + 0.03 ether}();

        assertEq(boughtTokenId, 1);
        assertEq(paidUser.balance, buyerNativeBefore - totalFee);
        assertEq(buyerTokenBefore - communityToken.balanceOf(paidUser), COMMUNITY_TOKEN_PRICE);
        assertEq(address(amm).balance, tradingFee * 2);
        assertEq(platformTreasury.balance - platformBefore, platformFee * 2);
        assertEq(amm.inventoryCount(), 0);
        assertEq(pool.ownerOf(1), paidUser);
        assertEq(pool.activeMiningWeightOf(1), BASE_WEIGHT);
        assertFalse(pool.indexMiningActiveOf(1));
        assertEq(pool.indexMiningWeightOf(1), 64 ether);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMRevertsWhenMsgValueIsBelowCurrentSpotFee() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);

        uint256 normalFee = amm.quoteNormalNativeFee();
        vm.expectRevert(IndexBrokerNFTAMM.InsufficientNativeFee.selector);
        vm.prank(whitelistUser1);
        amm.sellNFT{value: normalFee - 1}(1);

        assertEq(pool.ownerOf(1), whitelistUser1);
        assertEq(amm.inventoryCount(), 0);
    }

    function test_AMMBuySpecificNFTUsesSpecificFeeAndKeepsFIFOInventory() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.startPrank(whitelistUser1);
        pool.setApprovalForAll(address(amm), true);
        amm.sellNFT{value: amm.quoteNormalNativeFee()}(1);
        amm.sellNFT{value: amm.quoteNormalNativeFee()}(2);
        vm.stopPrank();

        uint256 specificFee = amm.quoteSpecificNativeFee();
        uint256 buyerNativeBefore = paidUser.balance;
        vm.prank(paidUser);
        amm.buySpecificNFT{value: specificFee + 0.01 ether}(2);

        assertEq(paidUser.balance, buyerNativeBefore - specificFee);
        assertEq(pool.ownerOf(2), paidUser);
        assertEq(pool.ownerOf(1), address(amm));
        assertEq(amm.inventoryCount(), 1);
        assertEq(amm.oldestTokenId(), 1);
        assertEq(amm.nextInventoryToken(1), 0);
        assertFalse(amm.inInventory(2));
        assertEq(pool.activeMiningWeightOf(2), BASE_WEIGHT);
        assertEq(pool.activeMiningWeightOf(1), 0);
    }

    function test_AMMFeeTracksCurrentV2SpotPrice() public {
        assertEq(amm.quoteNormalTradingNativeFee(), 0.01 ether);
        assertEq(amm.quotePlatformNativeFee(), 0.0005 ether);
        assertEq(amm.quoteNormalNativeFee(), 0.0105 ether);
        _setV2Price(1_000_000 ether, 200 ether);
        assertEq(amm.quoteNativeValue(), 0.2 ether);
        assertEq(amm.quoteNormalTradingNativeFee(), 0.02 ether);
        assertEq(amm.quotePlatformNativeFee(), 0.001 ether);
        assertEq(amm.quoteNormalNativeFee(), 0.021 ether);
        assertEq(amm.quoteSpecificNativeFee(), 0.031 ether);
    }

    function test_AMMPlatformFeeUsesCurrentCommitteeRecipient() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);

        address newPlatformTreasury = makeAddr("newPlatformTreasury");
        committee.adminSetFeeRecipient(payable(newPlatformTreasury));
        uint256 oldTreasuryBefore = platformTreasury.balance;
        uint256 platformFee = amm.quotePlatformNativeFee();
        uint256 totalFee = amm.quoteNormalNativeFee();

        vm.prank(whitelistUser1);
        amm.sellNFT{value: totalFee}(1);

        assertEq(amm.platformFeeReceiver(), newPlatformTreasury);
        assertEq(newPlatformTreasury.balance, platformFee);
        assertEq(platformTreasury.balance, oldTreasuryBefore);
    }

    function test_AMMPublicCallerInvestsNativeReserveAndReceivesOnePercent() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);
        uint256 totalFee = amm.quoteNormalNativeFee();
        vm.prank(whitelistUser1);
        amm.sellNFT{value: totalFee}(1);

        uint256 reserve = address(amm).balance;
        uint256 expectedReward = reserve * amm.INDEX_PURCHASE_CALLER_BPS() / 10_000;
        uint256 expectedInvestment = reserve - expectedReward;
        address executor = makeAddr("indexExecutor");
        uint256 executorBefore = executor.balance;

        vm.prank(executor);
        (uint256 callerReward, uint256 settlementOut, uint256 indexOut) =
            amm.buyIndexWithNativeReserve(expectedInvestment * 2, expectedInvestment * 6, bytes("hook data"));

        assertEq(callerReward, expectedReward);
        assertEq(settlementOut, expectedInvestment * 2);
        assertEq(indexOut, expectedInvestment * 6);
        assertEq(executor.balance - executorBefore, expectedReward);
        assertEq(defaultIndexToken.balanceOf(address(amm)), 0);
        assertEq(defaultIndexToken.balanceOf(address(pool)), indexOut);
        assertEq(pool.queuedIndexRewards(), indexOut);
        assertEq(address(amm).balance, 0);
        assertEq(address(indexV3Router).balance, expectedInvestment);
    }

    function test_AMMBuybackAutomaticallyInjectsRewardsIntoActiveWeightedNFTs() public {
        _mintWhitelist(whitelistUser1, 0, 0);
        _mintWhitelist(whitelistUser1, 0, 0);
        vm.prank(whitelistUser1);
        pool.upgradeIndexMining(2, 10 ether);

        vm.prank(whitelistUser1);
        pool.approve(address(amm), 1);
        uint256 sellFee = amm.quoteNormalNativeFee();
        vm.prank(whitelistUser1);
        amm.sellNFT{value: sellFee}(1);

        uint256 reserve = address(amm).balance;
        uint256 callerReward = reserve * amm.INDEX_PURCHASE_CALLER_BPS() / 10_000;
        uint256 investment = reserve - callerReward;
        vm.prank(makeAddr("buybackExecutor"));
        (,, uint256 indexOut) = amm.buyIndexWithNativeReserve(investment * 2, investment * 6, bytes(""));

        assertEq(indexOut, investment * 6);
        assertEq(defaultIndexToken.balanceOf(address(amm)), 0);
        assertEq(defaultIndexToken.balanceOf(address(pool)), indexOut);
        assertEq(pool.pendingIndexRewardsOf(2), indexOut);
        assertEq(pool.queuedIndexRewards(), 0);
    }

    function test_AnyoneHarvestsIndexHolderFeesIntoAMMAndNextBuybackUsesThem() public {
        uint256 holderFees = 1 ether;
        vm.deal(address(wrappedNative), holderFees);
        wrappedNative.approve(address(defaultIndexToken), holderFees);
        defaultIndexToken.fundHolderFees(address(pool), holderFees);

        address keeper = makeAddr("holderFeeKeeper");
        uint256 ammNativeBefore = address(amm).balance;
        vm.prank(keeper);
        uint256 harvested = pool.harvestIndexHolderFees();

        assertEq(harvested, holderFees);
        assertEq(address(amm).balance - ammNativeBefore, holderFees);
        assertEq(wrappedNative.balanceOf(address(pool)), 0);
        assertEq(wrappedNative.balanceOf(address(amm)), 0);
        assertEq(defaultIndexToken.claimableHolderFees(address(pool)), 0);

        uint256 expectedReward = holderFees * amm.INDEX_PURCHASE_CALLER_BPS() / 10_000;
        uint256 investment = holderFees - expectedReward;
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        (uint256 callerReward,, uint256 indexOut) =
            amm.buyIndexWithNativeReserve(investment * 2, investment * 6, bytes(""));

        assertEq(callerReward, expectedReward);
        assertEq(keeper.balance - keeperBefore, expectedReward);
        assertEq(indexOut, investment * 6);
        assertEq(address(amm).balance, 0);
        assertEq(defaultIndexToken.balanceOf(address(pool)), indexOut);
        assertEq(pool.queuedIndexRewards(), indexOut);
    }

    function test_IndexHolderFeeHarvestRejectsEmptyAndAMMRejectsNonCollection() public {
        vm.expectRevert(IndexBrokerNFT.NoIndexHolderFees.selector);
        pool.harvestIndexHolderFees();

        vm.expectRevert(IndexBrokerNFTAMM.InvalidIndexHolderFees.selector);
        amm.convertIndexHolderFees(1);
    }

    function test_AMMIndexPurchaseSlippageRevertsCallerRewardAndReserveMovement() public {
        uint256 reserve = 1 ether;
        vm.deal(address(amm), reserve);
        address executor = makeAddr("slippageExecutor");
        uint256 executorBefore = executor.balance;
        uint256 investment = reserve - (reserve * amm.INDEX_PURCHASE_CALLER_BPS() / 10_000);

        vm.expectRevert(bytes("V3 slippage"));
        vm.prank(executor);
        amm.buyIndexWithNativeReserve(investment * 2 + 1, 0, bytes(""));

        assertEq(executor.balance, executorBefore);
        assertEq(address(amm).balance, reserve);
        assertEq(defaultIndexToken.balanceOf(address(amm)), 0);
    }

    function test_AMMIndexTokenIsFixedWhileFactoryDefaultCanChange() public {
        IndexBrokerIndexTokenMock newDefault = new IndexBrokerIndexTokenMock("NEW-DEFAULT");
        newDefault.setWbnb(address(wrappedNative));
        basketRegistry.setIndexToken(address(newDefault), true);
        poolFactory.setDefaultIndexToken(address(newDefault));

        assertEq(amm.indexToken(), address(defaultIndexToken));
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerNFT newDefaultPool = _addPool(NATIVE_PRICE, 3, 0, false, accounts, allowances);
        assertEq(IndexBrokerNFTAMM(payable(newDefaultPool.ammVault())).indexToken(), address(newDefault));

        IndexBrokerNFT customPool =
            _addPoolWithIndex(NATIVE_PRICE, 3, 0, false, accounts, allowances, address(defaultIndexToken));
        assertEq(IndexBrokerNFTAMM(payable(customPool.ammVault())).indexToken(), address(defaultIndexToken));
    }

    function test_FactoryRejectsUnregisteredCustomIndexToken() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerIndexTokenMock fakeIndex = new IndexBrokerIndexTokenMock("FAKE");
        vm.expectRevert(bytes("Invalid index token"));
        this.addPoolWithIndexForRevertTest(NATIVE_PRICE, 3, 0, false, accounts, allowances, address(fakeIndex));
    }

    function test_FactoryRejectsIndexBasketWithDifferentWrappedNative() public {
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        IndexBrokerIndexTokenMock incompatibleIndex = new IndexBrokerIndexTokenMock("INCOMPATIBLE");
        incompatibleIndex.setWbnb(makeAddr("differentWrappedNative"));
        basketRegistry.setIndexToken(address(incompatibleIndex), true);

        vm.expectRevert(IndexBrokerNFTAMM.InvalidConfig.selector);
        this.addPoolWithIndexForRevertTest(NATIVE_PRICE, 3, 0, false, accounts, allowances, address(incompatibleIndex));
    }

    function test_RejectsOnlyExactReservedCollectionName() public {
        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameUsed.selector);
        this.addPoolNamedForRevertTest("stonkbroker");

        string[4] memory allowedNames = ["StonkBroker", "STONK BROKERS", "Official-Stonk_Broker NFT", "stonk brokerage"];
        for (uint256 i; i < allowedNames.length; ++i) {
            IndexBrokerNFT namedPool = this.addPoolNamedForRevertTest(allowedNames[i]);
            assertEq(namedPool.name(), allowedNames[i]);
        }
    }

    function test_PlatformCanAddExactReservedCollectionNames() public {
        assertEq(poolFactory.reservedCollectionNameCount(), 1);
        assertEq(poolFactory.reservedCollectionNameAt(0), "stonkbroker");

        string[] memory names = new string[](2);
        names[0] = "Index Broker Official";
        names[1] = "Protected Brand";
        poolFactory.addReservedCollectionNames(names);

        assertEq(poolFactory.reservedCollectionNameCount(), 3);
        assertEq(poolFactory.reservedCollectionNameAt(1), "Index Broker Official");
        assertTrue(poolFactory.reservedCollectionNameHash(keccak256(bytes("Protected Brand"))));

        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameUsed.selector);
        this.addPoolNamedForRevertTest("Protected Brand");

        IndexBrokerNFT allowedPool = this.addPoolNamedForRevertTest("protected brand");
        assertEq(allowedPool.name(), "protected brand");
    }

    function test_PlatformCanRemoveReservedCollectionName() public {
        string[] memory names = new string[](2);
        names[0] = "Reserved Alpha";
        names[1] = "Reserved Beta";
        poolFactory.addReservedCollectionNames(names);

        poolFactory.removeReservedCollectionName("Reserved Alpha");

        assertEq(poolFactory.reservedCollectionNameCount(), 2);
        assertEq(poolFactory.reservedCollectionNameAt(0), "stonkbroker");
        assertEq(poolFactory.reservedCollectionNameAt(1), "Reserved Beta");
        assertFalse(poolFactory.reservedCollectionNameHash(keccak256(bytes("Reserved Alpha"))));
        assertTrue(poolFactory.reservedCollectionNameHash(keccak256(bytes("Reserved Beta"))));

        IndexBrokerNFT namedPool = this.addPoolNamedForRevertTest("Reserved Alpha");
        assertEq(namedPool.name(), "Reserved Alpha");

        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameUsed.selector);
        this.addPoolNamedForRevertTest("Reserved Beta");

        // Beta was moved when Alpha was removed. Removing it proves the moved entry's private index was updated.
        poolFactory.removeReservedCollectionName("Reserved Beta");
        assertEq(poolFactory.reservedCollectionNameCount(), 1);
        assertFalse(poolFactory.reservedCollectionNameHash(keccak256(bytes("Reserved Beta"))));

        // Cover removal of the last remaining array entry.
        poolFactory.removeReservedCollectionName("stonkbroker");
        assertEq(poolFactory.reservedCollectionNameCount(), 0);

        names = new string[](1);
        names[0] = "Reserved Alpha";
        poolFactory.addReservedCollectionNames(names);
        assertTrue(poolFactory.reservedCollectionNameHash(keccak256(bytes("Reserved Alpha"))));

        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameUsed.selector);
        this.addPoolNamedForRevertTest("Reserved Alpha");
    }

    function test_RemoveReservedCollectionNameRevertsWhenNotFound() public {
        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameNotFound.selector);
        poolFactory.removeReservedCollectionName("Not Reserved");
    }

    function test_ReservedCollectionNamesUseExactStringIdentity() public {
        string[] memory names = new string[](1);
        names[0] = "Protected Brand";
        poolFactory.addReservedCollectionNames(names);

        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameAlreadyAdded.selector);
        poolFactory.addReservedCollectionNames(names);

        names[0] = "protected brand";
        poolFactory.addReservedCollectionNames(names);
        assertTrue(poolFactory.reservedCollectionNameHash(keccak256(bytes("Protected Brand"))));
        assertTrue(poolFactory.reservedCollectionNameHash(keccak256(bytes("protected brand"))));

        vm.expectRevert(IndexBrokerNFTFactory.ReservedCollectionNameNotFound.selector);
        poolFactory.removeReservedCollectionName("PROTECTED BRAND");
    }

    function test_AddReservedCollectionNameRejectsInvalidLength() public {
        string[] memory names = new string[](1);
        vm.expectRevert(IndexBrokerNFTFactory.InvalidReservedCollectionName.selector);
        poolFactory.addReservedCollectionNames(names);

        bytes memory tooLong = new bytes(poolFactory.MAX_RESERVED_NAME_LENGTH() + 1);
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = 0x61;
        }
        names[0] = string(tooLong);
        vm.expectRevert(IndexBrokerNFTFactory.InvalidReservedCollectionName.selector);
        poolFactory.addReservedCollectionNames(names);
    }

    function test_OnlyPlatformOwnerCanAddReservedCollectionNames() public {
        string[] memory names = new string[](1);
        names[0] = "Protected Brand";
        vm.prank(paidUser);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        poolFactory.addReservedCollectionNames(names);
    }

    function test_OnlyPlatformOwnerCanRemoveReservedCollectionName() public {
        vm.prank(paidUser);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        poolFactory.removeReservedCollectionName("stonkbroker");
    }

    function test_AllowsUnrelatedCollectionName() public {
        IndexBrokerNFT namedPool = this.addPoolNamedForRevertTest("Index Broker Pixels");
        assertEq(namedPool.name(), "Index Broker Pixels");
    }

    function _createCommunity(bool official)
        internal
        returns (Community createdCommunity, IndexBrokerCommunityToken createdToken)
    {
        createdToken = new IndexBrokerCommunityToken();
        if (official) pump.setCreatedToken(address(createdToken), true);
        createdCommunity = Community(
            payable(communityFactory.createCommunity(
                    false, address(createdToken), address(0), bytes(""), address(calculator), bytes("")
                ))
        );
    }

    function _addPoolToCommunity(Community targetCommunity, bytes memory priceSourceData)
        internal
        returns (IndexBrokerNFT createdPool)
    {
        uint256[] memory thresholds = new uint256[](1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = BASE_WEIGHT;
        address[] memory accounts = new address[](1);
        accounts[0] = paidUser;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;

        IndexBrokerNFTFactory.AMMConfig memory ammConfig = IndexBrokerNFTFactory.AMMConfig({
            normalFeeBps: AMM_NORMAL_FEE_BPS,
            specificFeeBps: AMM_SPECIFIC_FEE_BPS,
            priceSourceType: IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR,
            priceSourceData: priceSourceData,
            indexToken: address(0)
        });
        IndexBrokerNFTFactory.PoolConfig memory config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "IDXNFT",
            fundsReceiver: fundsReceiver,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            indexMiningActivationTokenAmount: INDEX_MINING_ACTIVATION_TOKEN_AMOUNT,
            recommitPrice: 0,
            nativePrice: 0,
            maxSupply: 1,
            referralBps: 0,
            ammConfig: abi.encode(ammConfig),
            lockWhitelistSlots: true,
            rerollEnabled: false,
            whitelistAccounts: accounts,
            whitelistAllowances: allowances
        });
        uint16[] memory ratios = new uint16[](1);
        ratios[0] = 10_000;
        targetCommunity.adminAddPool("Activation Test NFT", ratios, address(poolFactory), abi.encode(config));
        createdPool = IndexBrokerNFT(payable(targetCommunity.activedPools(0)));
    }

    function addPoolToCommunityForRevertTest(Community targetCommunity, bytes calldata priceSourceData)
        external
        returns (IndexBrokerNFT)
    {
        require(msg.sender == address(this), "test only");
        return _addPoolToCommunity(targetCommunity, priceSourceData);
    }

    function _addPool(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) internal returns (IndexBrokerNFT createdPool) {
        return _addPoolWithIndex(nativePrice, supply, referralRate, lockSlots, accounts, allowances, address(0));
    }

    function _addPoolWithIndex(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances,
        address indexToken
    ) internal returns (IndexBrokerNFT createdPool) {
        return _addPoolConfigured(
            nativePrice, supply, referralRate, lockSlots, accounts, allowances, indexToken, true, 0, "Index Broker NFT"
        );
    }

    function _addPoolWithRevealConfig(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances,
        bool reroll,
        uint256 rerollPrice
    ) internal returns (IndexBrokerNFT createdPool) {
        return _addPoolConfigured(
            nativePrice,
            supply,
            referralRate,
            lockSlots,
            accounts,
            allowances,
            address(0),
            reroll,
            rerollPrice,
            "Index Broker NFT"
        );
    }

    function _addPoolConfigured(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances,
        address indexToken,
        bool reroll,
        uint256 rerollPrice,
        string memory collectionName
    ) internal returns (IndexBrokerNFT createdPool) {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0;
        thresholds[1] = 2;
        thresholds[2] = 4;
        uint256[] memory weights = new uint256[](3);
        weights[0] = BASE_WEIGHT;
        weights[1] = 12_000;
        weights[2] = 15_000;

        IndexBrokerNFTFactory.AMMConfig memory ammConfig = IndexBrokerNFTFactory.AMMConfig({
            normalFeeBps: AMM_NORMAL_FEE_BPS,
            specificFeeBps: AMM_SPECIFIC_FEE_BPS,
            priceSourceType: IIndexBrokerNFTPriceOracle.SourceType.V2_PAIR,
            priceSourceData: abi.encode(address(v2Factory), address(v2Pair)),
            indexToken: indexToken
        });

        IndexBrokerNFTFactory.PoolConfig memory config = IndexBrokerNFTFactory.PoolConfig({
            symbol: "IDXNFT",
            fundsReceiver: fundsReceiver,
            renderer: address(0),
            levelThresholds: thresholds,
            levelWeights: weights,
            communityTokenPrice: COMMUNITY_TOKEN_PRICE,
            indexMiningActivationTokenAmount: INDEX_MINING_ACTIVATION_TOKEN_AMOUNT,
            recommitPrice: rerollPrice,
            nativePrice: nativePrice,
            maxSupply: supply,
            referralBps: referralRate,
            ammConfig: abi.encode(ammConfig),
            lockWhitelistSlots: lockSlots,
            rerollEnabled: reroll,
            whitelistAccounts: accounts,
            whitelistAllowances: allowances
        });

        uint256 existingPools = activePoolCount;
        uint16[] memory ratios = new uint16[](existingPools + 1);
        uint16 ratio = uint16(10_000 / (existingPools + 1));
        uint256 assigned;
        for (uint256 i; i < existingPools; ++i) {
            ratios[i] = ratio;
            assigned += ratio;
        }
        ratios[existingPools] = uint16(10_000 - assigned);

        community.adminAddPool(collectionName, ratios, address(poolFactory), abi.encode(config));
        createdPool = IndexBrokerNFT(payable(community.activedPools(existingPools)));
        activePoolCount = existingPools + 1;
    }

    function addPoolForRevertTest(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances
    ) external returns (IndexBrokerNFT) {
        require(msg.sender == address(this), "test only");
        return _addPool(nativePrice, supply, referralRate, lockSlots, accounts, allowances);
    }

    function addPoolWithIndexForRevertTest(
        uint256 nativePrice,
        uint256 supply,
        uint16 referralRate,
        bool lockSlots,
        address[] memory accounts,
        uint256[] memory allowances,
        address indexToken
    ) external returns (IndexBrokerNFT) {
        require(msg.sender == address(this), "test only");
        return _addPoolWithIndex(nativePrice, supply, referralRate, lockSlots, accounts, allowances, indexToken);
    }

    function addPoolNamedForRevertTest(string calldata collectionName) external returns (IndexBrokerNFT) {
        require(msg.sender == address(this), "test only");
        address[] memory accounts = new address[](1);
        accounts[0] = whitelistUser1;
        uint256[] memory allowances = new uint256[](1);
        allowances[0] = 1;
        return _addPoolConfigured(NATIVE_PRICE, 3, 0, false, accounts, allowances, address(0), true, 0, collectionName);
    }

    function _fundAndApprove(address user, IndexBrokerNFT targetPool) internal {
        if (communityToken.balanceOf(user) < 100_000 ether) {
            assertTrue(communityToken.transfer(user, 100_000 ether));
        }
        vm.deal(user, 100 ether);
        vm.prank(user);
        communityToken.approve(address(targetPool), type(uint256).max);
        address targetAMM = targetPool.ammVault();
        vm.prank(user);
        communityToken.approve(targetAMM, type(uint256).max);
    }

    function _mintWhitelist(address user, uint256 referrerTokenId, uint256 value) internal returns (uint256) {
        vm.prank(user);
        return pool.mint{value: value}(referrerTokenId);
    }

    function _mintPaid(address user, uint256 referrerTokenId) internal returns (uint256) {
        vm.prank(user);
        return pool.mint{value: NATIVE_PRICE}(referrerTokenId);
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory haystack = bytes(value);
        bytes memory target = bytes(needle);
        if (target.length == 0 || target.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - target.length; ++i) {
            bool matches = true;
            for (uint256 j; j < target.length; ++j) {
                if (haystack[i + j] != target[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function _setV2Price(uint112 tokenReserve, uint112 nativeReserve) internal {
        if (v2Pair.token0() == address(communityToken)) v2Pair.setReserves(tokenReserve, nativeReserve);
        else v2Pair.setReserves(nativeReserve, tokenReserve);
    }
}
