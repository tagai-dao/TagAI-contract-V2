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
    constructor() ERC20("Community", "COM") {
        _mint(msg.sender, 10_000_000 ether);
    }
}

contract IndexBrokerIndexTokenMock is ERC20 {
    constructor(string memory symbol_) ERC20("Index Token", symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
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
        wrappedNative = new IndexBrokerCommunityToken();
        v2Factory = new IndexBrokerV2FactoryMock();
        v2Pair = new IndexBrokerV2PairMock(address(v2Factory), address(communityToken), address(wrappedNative));
        v2Factory.setPair(address(communityToken), address(wrappedNative), address(v2Pair));
        _setV2Price(1_000_000 ether, 100 ether);

        address[] memory v2Factories = new address[](1);
        v2Factories[0] = address(v2Factory);
        priceOracle = new IndexBrokerNFTPriceOracle(
            address(wrappedNative), v2Factories, new address[](0), new address[](0), new address[](0)
        );
        basketRegistry = new IndexBrokerBasketRegistryMock();
        indexSettlementToken = new IndexBrokerCommunityToken();
        indexV3Factory = new IndexBrokerIndexV3FactoryMock();
        indexV3Router = new IndexBrokerIndexV3RouterMock(address(indexV3Factory), address(wrappedNative));
        indexV3Factory.setPool(address(wrappedNative), address(indexSettlementToken), INDEX_V3_FEE, address(v2Pair));
        basketSwapRouter = new IndexBrokerBasketSwapRouterMock(address(indexSettlementToken));
        defaultIndexToken = new IndexBrokerIndexTokenMock("DEFAULT-INDEX");
        basketRegistry.setIndexToken(address(defaultIndexToken), true);
        assertTrue(indexSettlementToken.transfer(address(indexV3Router), 1_000_000 ether));
        poolFactory = new IndexBrokerNFTFactory(
            address(communityFactory),
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
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMCustodyStopsMiningAndPreventsReferralUntilNFTLeaves() public {
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
        assertEq(pool.getUserStakedAmount(whitelistUser2), BASE_WEIGHT);
        assertEq(pool.getTotalStakedAmount(), BASE_WEIGHT);
    }

    function test_AMMSellAndBuyUseSpotNativeFeeAndRefundExcess() public {
        _mintWhitelist(whitelistUser1, 0, 0);
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

    function test_AMMPublicCallerInvestsNativeReserveAndReceivesPointThreePercent() public {
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
        assertEq(defaultIndexToken.balanceOf(address(amm)), indexOut);
        assertEq(address(amm).balance, 0);
        assertEq(address(indexV3Router).balance, expectedInvestment);
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
            nativePrice: nativePrice,
            maxSupply: supply,
            referralBps: referralRate,
            ammConfig: abi.encode(ammConfig),
            lockWhitelistSlots: lockSlots,
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

        community.adminAddPool("Index Broker NFT", ratios, address(poolFactory), abi.encode(config));
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

    function _setV2Price(uint112 tokenReserve, uint112 nativeReserve) internal {
        if (v2Pair.token0() == address(communityToken)) v2Pair.setReserves(tokenReserve, nativeReserve);
        else v2Pair.setReserves(nativeReserve, tokenReserve);
    }
}
