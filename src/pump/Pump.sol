// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IPump.sol";
import "../interfaces/IIPShare.sol";
import "../interfaces/IBondingCurve.sol";
import "../interfaces/ICommunityFactory.sol";
import "../interfaces/ICommunity.sol";
import "../interfaces/ICommittee.sol";
import "../interfaces/IToken.sol";

import "solady/src/utils/FixedPointMathLib.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Token.sol";

import {INutboxRouter} from "../router/INutboxRouter.sol";

interface IPumpBasketHook {
    enum Venue {
        V4,
        V3,
        WBNB,
        V2
    }

    struct LegRoute {
        Venue venue;
        address poolQuoteToken;
        PoolKey v4Pool;
        uint24 v3Fee;
        uint16 defaultMaxExecutionLossBps;
    }

    struct CreateParams {
        string name;
        string symbol;
        address creator;
        uint16 basketFeeBps;
        uint16 creatorShareBps;
        address[] constituentAssets;
        LegRoute[] constituentRoutes;
        uint16[] targetWeights;
    }

    function tokenVersion() external view returns (uint32);
    function settlementToken() external view returns (address);
    function v2Factory() external view returns (address);
    function nutboxRouter() external view returns (address);
    function createBasketFor(address creator, bytes32 userSalt, CreateParams calldata params)
        external
        returns (address basket);
}

interface INutboxCommunityAdmin {
    function adminSetDev(address dev) external;
    function transferOwnership(address newOwner) external;
    function renounceOwnership() external;
}

contract Pump is Ownable2Step, IPump, ReentrancyGuard, IBondingCurve {
    uint256 private constant BPS = 10_000;
    /// @notice Maximum number of constituent assets in a newly created Pump13 token.
    uint256 public constant MAX_COMPONENTS = 4;
    uint16 private constant MAX_LISTING_SWAP_SLIPPAGE_BPS = 1_000;

    address public override nutboxRouter;
    address public override basketHookV4;
    address public override pancakeV2Factory;
    address public override settlementToken;
    uint16 public override listingSwapSlippageBps = 300;
    address public override listingKeeper;
    address public override buybackRouter;
    mapping(address => bool) public listingFinalized;
    mapping(address => address) public override indexTokenOf;
    mapping(address => bool) public override approvedConstituent;

    address private ipshare;
    address public tokenImplementation;
    uint256 public createFee = 0.005 ether;
    uint256 private divisor = 10000;
    address private feeReceiver = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    /// @dev Inner-market (bonding curve) fee split only — post-list PCS V4 fees are hardcoded in TagAISwapHook.
    uint256[2] private feeRatio = [30, 30]; // 0: to tiptag; 1: to salesman

    // BSC Nutbox stack
    address public nutboxCommunityFactory = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address public hourlyTickCalculator; // HourlyTickCalculator (replaces linearTimeCalculator)
    address public erc20StakingFactory = 0xDc3f940ac6Da516d5C9cc59c8AFE0F85A576E2A4;
    address public nutboxCommittee = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;

    // PancakeSwap V4 (Infinity)
    address private poolManager = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b; // BSC CLPoolManager
    address private vault = 0x238a358808379702088667322f80aC48bAd5e6c4; // BSC Vault
    address private hookAddress; // TagAISwapHook address

    mapping(address => bool) public createdTokens;
    mapping(string => bool) public createdTicks;

    uint256 public totalTokens;

    /**
     * @param _ipshare IPShare contract address
     * @param _feeReceiver Fee receiver address, pass address(0) to use default
     * @param initialConstituents Assets approved atomically during deployment; independent of the per-token limit.
     */
    constructor(address _ipshare, address _feeReceiver, address[] memory initialConstituents) {
        for (uint256 i; i < initialConstituents.length; ++i) {
            address asset = initialConstituents[i];
            if (asset.code.length == 0 || approvedConstituent[asset]) revert InvalidIndexConfig();
            approvedConstituent[asset] = true;
            emit ConstituentApprovalSet(asset, true);
        }
        ipshare = _ipshare;
        tokenImplementation = address(new Token());
        if (_feeReceiver != address(0)) feeReceiver = _feeReceiver;
    }

    function adminSetPoolManager(address _poolManager) public onlyOwner {
        poolManager = _poolManager;
    }

    function adminSetVault(address _vault) public onlyOwner {
        vault = _vault;
    }

    function adminSetHookAddress(address _hookAddress) public onlyOwner {
        hookAddress = _hookAddress;
    }

    /// @notice Wire Nutbox stack (CommunityFactory, HourlyTickCalculator, ERC20StakingFactory, Committee).
    function adminSetNutbox(
        address communityFactory_,
        address calculator_,
        address erc20StakingFactory_,
        address committee_
    ) external onlyOwner {
        nutboxCommunityFactory = communityFactory_;
        hourlyTickCalculator = calculator_;
        erc20StakingFactory = erc20StakingFactory_;
        nutboxCommittee = committee_;
    }

    /// @notice Set the HourlyTickCalculator address independently.
    function adminSetCalculator(address _calculator) external onlyOwner {
        hourlyTickCalculator = _calculator;
    }

    receive() external payable {}

    // admin function
    function adminChangeIPShare(address _ipshare) public onlyOwner {
        emit IPShareChanged(ipshare, _ipshare);
        ipshare = _ipshare;
    }

    function adminChangeCreateFee(uint256 _createFee) public onlyOwner {
        if (_createFee > 1 ether) {
            revert TooMuchFee();
        }
        emit CreateFeeChanged(createFee, _createFee);
        createFee = _createFee;
    }

    function adminChangeFeeRatio(uint256[2] calldata ratios) public onlyOwner {
        if (ratios[0] > 1000 || ratios[1] > 1000) {
            revert TooMuchFee();
        }
        feeRatio = ratios;
        emit FeeRatiosChanged(ratios[0], ratios[1]);
    }

    function adminChangeFeeAddress(address _feeReceiver) public onlyOwner {
        emit FeeAddressChanged(feeReceiver, _feeReceiver);
        feeReceiver = _feeReceiver;
    }

    function getIPShare() public view override returns (address) {
        return ipshare;
    }

    function getFeeReceiver() public view override returns (address) {
        return feeReceiver;
    }

    function getFeeRatio() public view override returns (uint256[2] memory) {
        return feeRatio;
    }

    function getCalculator() public view override returns (address) {
        return hourlyTickCalculator;
    }

    function getPoolManager() public view override returns (address) {
        return poolManager;
    }

    function getVault() public view override returns (address) {
        return vault;
    }

    function getHookAddress() public view override returns (address) {
        return hookAddress;
    }

    function adminSetIndexInfrastructure(
        address nutboxRouter_,
        address basketHookV4_,
        address pancakeV2Factory_,
        address settlementToken_
    ) external onlyOwner {
        if (
            nutboxRouter_.code.length == 0 || basketHookV4_.code.length == 0 || pancakeV2Factory_.code.length == 0
                || settlementToken_.code.length == 0
        ) revert IndexInfrastructureNotConfigured();
        IPumpBasketHook basketHook = IPumpBasketHook(basketHookV4_);
        if (
            basketHook.tokenVersion() != 4 || basketHook.settlementToken() != settlementToken_
                || basketHook.v2Factory() != pancakeV2Factory_ || basketHook.nutboxRouter() != nutboxRouter_
        ) revert IndexInfrastructureNotConfigured();

        nutboxRouter = nutboxRouter_;
        basketHookV4 = basketHookV4_;
        pancakeV2Factory = pancakeV2Factory_;
        settlementToken = settlementToken_;
        emit IndexInfrastructureChanged(nutboxRouter_, basketHookV4_, pancakeV2Factory_, settlementToken_);
    }

    function adminSetListingSwapSlippageBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_LISTING_SWAP_SLIPPAGE_BPS) revert InvalidIndexConfig();
        uint16 previousBps = listingSwapSlippageBps;
        listingSwapSlippageBps = newBps;
        emit ListingSwapSlippageChanged(previousBps, newBps);
    }

    function adminSetListingKeeper(address newKeeper) external onlyOwner {
        address previousKeeper = listingKeeper;
        listingKeeper = newKeeper;
        emit ListingKeeperChanged(previousKeeper, newKeeper);
    }

    function adminSetBuybackRouter(address newRouter) external onlyOwner {
        if (newRouter != address(0) && newRouter.code.length == 0) revert InvalidBuybackRouter();
        address previousRouter = buybackRouter;
        buybackRouter = newRouter;
        emit BuybackRouterChanged(previousRouter, newRouter);
    }

    /// @notice Controls the stock/component assets users may select for newly created tokens.
    function adminSetConstituentApproval(address asset, bool approved) external override onlyOwner {
        if (asset == address(0) || (approved && asset.code.length == 0)) revert InvalidIndexConfig();
        approvedConstituent[asset] = approved;
        emit ConstituentApprovalSet(asset, approved);
    }

    function createToken(string calldata, bytes32) public payable override returns (address) {
        revert IndexConfigRequired();
    }

    function createToken(string calldata tick, bytes32 salt, IndexConfig calldata indexConfig)
        external
        payable
        override
        nonReentrant
        returns (address)
    {
        require(msg.sender == tx.origin, "Only EOA");
        _validateInfrastructure();
        _validateIndexConfig(indexConfig);

        if (
            nutboxCommunityFactory == address(0) || hourlyTickCalculator == address(0)
                || erc20StakingFactory == address(0) || nutboxCommittee == address(0)
        ) revert NutboxNotConfigured();
        if (createdTicks[tick]) revert TickHasBeenCreated();

        bytes32 cloneSalt = keccak256(abi.encode(msg.sender, salt));
        address predictedAddress = Clones.predictDeterministicAddress(tokenImplementation, cloneSalt, address(this));
        if (createdTokens[predictedAddress]) revert SaltNotAvailable();
        createdTicks[tick] = true;

        address creator = msg.sender;
        IIPShare ipshareContract = IIPShare(getIPShare());
        bool needCreateIPShare = !ipshareContract.ipshareCreated(creator);
        uint256 ipshareCreateFee = needCreateIPShare ? ipshareContract.createFee() : 0;
        uint256 componentCount = indexConfig.constituentAssets.length;
        uint256 nutboxFees = ICommittee(nutboxCommittee).getCreateCommunityFee()
            + ICommittee(nutboxCommittee).getCommunitySettingsFee() * componentCount;
        uint256 totalFixedFee = createFee + ipshareCreateFee + nutboxFees;
        if (msg.value < totalFixedFee) revert InsufficientCreateFee();

        if (needCreateIPShare) ipshareContract.createShare{value: ipshareCreateFee}(creator);
        if (createFee != 0) {
            (bool feeSent,) = getFeeReceiver().call{value: createFee}("");
            if (!feeSent) revert InsufficientCreateFee();
        }

        address instance = Clones.cloneDeterministic(tokenImplementation, cloneSalt);
        emit NewToken(tick, instance, creator);
        Token token = Token(payable(instance));
        token.initialize(address(this), creator, tick);
        token.initializeIndex(
            address(this),
            creator,
            pancakeV2Factory,
            nutboxRouter,
            basketHookV4,
            settlementToken,
            hookAddress,
            indexConfig
        );
        emit IndexConfigured(
            instance,
            indexConfig.name,
            indexConfig.symbol,
            indexConfig.constituentAssets,
            indexConfig.targetWeights,
            indexConfig.basketFeeBps,
            indexConfig.creatorShareBps,
            indexConfig.retainCommunityOwnership
        );

        if (msg.value > totalFixedFee) {
            (bool bought, bytes memory result) = instance.call{value: msg.value - totalFixedFee}(
                abi.encodeWithSignature("buyToken(uint256,address,uint16)", 0, creator, 0)
            );
            if (!bought) revert PreMineTokenFail();
            IERC20(instance).transfer(creator, abi.decode(result, (uint256)));
            uint256 refundable = address(this).balance > nutboxFees ? address(this).balance - nutboxFees : 0;
            if (refundable != 0) {
                (bool refunded,) = creator.call{value: refundable}("");
                if (!refunded) revert RefundFail();
            }
        }

        uint256 createCommunityFee = ICommittee(nutboxCommittee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(nutboxCommittee).getCommunitySettingsFee();
        address community = ICommunityFactory(nutboxCommunityFactory).createCommunity{value: createCommunityFee}(
            false, instance, address(0), bytes(""), hourlyTickCalculator, bytes("")
        );
        for (uint256 i; i < componentCount; ++i) {
            (,, address pair) = token.componentAt(i);
            uint16[] memory ratios = new uint16[](i + 1);
            if (i + 1 == componentCount) {
                for (uint256 j; j < componentCount; ++j) {
                    ratios[j] = indexConfig.targetWeights[j];
                }
            }
            ICommunity(community).adminAddPool{value: settingsFee}(
                "V2 LP Staking", ratios, erc20StakingFactory, abi.encodePacked(pair)
            );
            address pool = ICommunity(community).activedPools(i);
            emit NutboxStakingPoolLinked(instance, pool, pair, indexConfig.targetWeights[i]);
        }
        token.setNutboxCommunity(community);
        emit NutboxLinked(instance, community);

        INutboxCommunityAdmin nutboxCommunity = INutboxCommunityAdmin(community);
        nutboxCommunity.adminSetDev(creator);
        if (indexConfig.retainCommunityOwnership) {
            nutboxCommunity.transferOwnership(creator);
        } else {
            nutboxCommunity.renounceOwnership();
        }

        createdTokens[instance] = true;
        ++totalTokens;
        return instance;
    }

    function finalizeTokenListing() external override nonReentrant returns (address indexToken) {
        if (!createdTokens[msg.sender]) revert OnlyCreatedToken();
        if (listingFinalized[msg.sender]) revert ListingAlreadyFinalized();
        listingFinalized[msg.sender] = true;

        IToken token = IToken(msg.sender);
        (address routerAddress, address basketHookAddress, address tokenSettlement, address tokenPoolManager) =
            token.listingInfrastructure();
        address tokenV2Factory = token.pancakeV2Factory();
        _validateTokenInfrastructure(routerAddress, basketHookAddress, tokenV2Factory, tokenSettlement);
        INutboxRouter router = INutboxRouter(routerAddress);
        INutboxRouter.PancakeV4CLSource memory v4Source = INutboxRouter.PancakeV4CLSource({
            currency0: address(0),
            currency1: msg.sender,
            hooks: token.listingHook(),
            poolManager: tokenPoolManager,
            fee: token.LISTING_LP_FEE(),
            parameters: token.listingPoolParameters()
        });
        bytes memory v4SourceData = abi.encode(v4Source);
        bytes32 tokenNativePoolId =
            _ensurePricePool(router, msg.sender, address(0), INutboxRouter.SourceType.PANCAKE_V4_CL, v4SourceData);

        bytes32[] memory tokenNativeRoute = new bytes32[](1);
        tokenNativeRoute[0] = tokenNativePoolId;
        _ensureRoute(router, msg.sender, address(0), tokenNativeRoute);

        uint256 count = token.componentCount();
        address[] memory assets = new address[](count);
        uint16[] memory weights = new uint16[](count);
        IPumpBasketHook.LegRoute[] memory routes = new IPumpBasketHook.LegRoute[](count);
        PoolKey memory emptyPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0)),
            fee: 0,
            parameters: bytes32(0)
        });

        for (uint256 i; i < count; ++i) {
            // Basket resolves each T/asset pair through its V2 factory, independently of Router price pools.
            (address asset, uint16 weight,) = token.componentAt(i);
            assets[i] = asset;
            weights[i] = weight;
            routes[i] = IPumpBasketHook.LegRoute({
                venue: IPumpBasketHook.Venue.V2,
                poolQuoteToken: msg.sender,
                v4Pool: emptyPool,
                v3Fee: 0,
                defaultMaxExecutionLossBps: 0
            });
        }

        bytes32[] memory tokenSettlementRoute = new bytes32[](2);
        tokenSettlementRoute[0] = tokenNativePoolId;
        tokenSettlementRoute[1] = router.pricePoolId(address(0), tokenSettlement);
        _ensureRoute(router, msg.sender, tokenSettlement, tokenSettlementRoute);

        address creator = token.indexCreator();
        IPumpBasketHook.CreateParams memory params = IPumpBasketHook.CreateParams({
            name: token.indexName(),
            symbol: token.indexSymbol(),
            creator: creator,
            basketFeeBps: token.basketFeeBps(),
            creatorShareBps: token.creatorShareBps(),
            constituentAssets: assets,
            constituentRoutes: routes,
            targetWeights: weights
        });
        indexToken = IPumpBasketHook(basketHookAddress)
            .createBasketFor(creator, keccak256(abi.encodePacked("PUMP13_INDEX", msg.sender)), params);
        if (indexToken == address(0)) revert InvalidIndexConfig();
        indexTokenOf[msg.sender] = indexToken;
        emit IndexTokenCreated(msg.sender, indexToken, creator);
    }

    function _ensurePricePool(
        INutboxRouter router,
        address tokenA,
        address tokenB,
        INutboxRouter.SourceType sourceType,
        bytes memory sourceData
    ) private returns (bytes32 poolId) {
        poolId = router.pricePoolId(tokenA, tokenB);
        if (!router.hasPricePool(poolId)) return router.addPricePool(sourceType, sourceData);

        (bool enabled,,,, INutboxRouter.SourceType registeredType, bytes memory registeredData) =
            router.pricePool(poolId);
        if (!enabled || registeredType != sourceType || keccak256(registeredData) != keccak256(sourceData)) {
            revert InvalidIndexConfig();
        }
    }

    function _ensureRoute(INutboxRouter router, address tokenIn, address tokenOut, bytes32[] memory expectedPoolIds)
        private
    {
        if (!router.hasRoute(tokenIn, tokenOut)) {
            router.addRoute(tokenIn, tokenOut, expectedPoolIds);
            return;
        }
        if (router.routePoolCount(tokenIn, tokenOut) != expectedPoolIds.length) revert InvalidIndexConfig();
        for (uint256 i; i < expectedPoolIds.length; ++i) {
            if (router.routePoolAt(tokenIn, tokenOut, i) != expectedPoolIds[i]) revert InvalidIndexConfig();
        }
    }

    function finalizeTokenListing(address token, uint256[] calldata componentMinOuts, uint256 deadline)
        external
        override
        returns (address indexToken)
    {
        if (msg.sender != owner() && msg.sender != listingKeeper) revert OnlyListingKeeper();
        if (!createdTokens[token]) revert OnlyCreatedToken();
        indexToken = IToken(token).finalizeListing(componentMinOuts, deadline);
    }

    /// @notice Unlocks a failed atomic listing so holders can sell on the bonding curve again.
    /// @dev A later refill to the 650M cap queues a fresh listing attempt.
    function adminRecoverFailedListing(address token) external override onlyOwner {
        if (!createdTokens[token]) revert OnlyCreatedToken();
        IToken(token).recoverFailedListing();
        emit FailedListingRecovered(token);
    }

    function _validateInfrastructure() private view {
        if (
            nutboxRouter.code.length == 0 || basketHookV4.code.length == 0 || pancakeV2Factory.code.length == 0
                || settlementToken.code.length == 0
        ) revert IndexInfrastructureNotConfigured();
    }

    function _validateTokenInfrastructure(address router, address basketHook, address v2Factory, address settlement)
        private
        view
    {
        if (
            router.code.length == 0 || basketHook.code.length == 0 || v2Factory.code.length == 0
                || settlement.code.length == 0
        ) revert IndexInfrastructureNotConfigured();
        IPumpBasketHook hook = IPumpBasketHook(basketHook);
        if (
            hook.tokenVersion() != 4 || hook.settlementToken() != settlement || hook.v2Factory() != v2Factory
                || hook.nutboxRouter() != router
        ) revert IndexInfrastructureNotConfigured();
    }

    function _validateIndexConfig(IndexConfig calldata config) private view {
        uint256 count = config.constituentAssets.length;
        if (
            count == 0 || count > MAX_COMPONENTS || count != config.targetWeights.length
                || bytes(config.name).length == 0 || bytes(config.name).length > 64 || bytes(config.symbol).length == 0
                || bytes(config.symbol).length > 16 || config.basketFeeBps < 100 || config.basketFeeBps > 300
                || config.creatorShareBps > 3_000
        ) revert InvalidIndexConfig();

        address wrappedNative = INutboxRouter(nutboxRouter).wrappedNative();
        uint256 totalWeight;
        for (uint256 i; i < count; ++i) {
            address asset = config.constituentAssets[i];
            uint16 weight = config.targetWeights[i];
            if (
                !approvedConstituent[asset] || asset.code.length == 0 || asset == settlementToken
                    || asset == wrappedNative || weight == 0
            ) {
                revert InvalidIndexConfig();
            }
            for (uint256 j; j < i; ++j) {
                if (config.constituentAssets[j] == asset) revert InvalidIndexConfig();
            }
            totalWeight += weight;
            routerRouteMustExist(wrappedNative, asset);
        }
        if (totalWeight != BPS) revert InvalidIndexConfig();
    }

    function routerRouteMustExist(address wrappedNative, address asset) private view {
        INutboxRouter router = INutboxRouter(nutboxRouter);
        if (!router.hasRoute(wrappedNative, asset)) revert InvalidIndexConfig();
        router.validateRoute(wrappedNative, asset);
    }

    /********************************** bonding curve ********************************/

    /**
     * calculate the eth price when user buy amount tokens
     */
    function getPrice(uint256 supply, uint256 amount) public pure override returns (uint256) {
        require(supply <= 1000000000 ether && amount <= 1000000000 ether, "supply or amount too large");
        uint256 a = 6_500_000_000;
        uint256 b = 2.5175516438e26;
        uint256 x = FixedPointMathLib.mulWad(a, b);
        uint256 e1 = uint256(FixedPointMathLib.expWad(int256(((supply + amount) * 1e18) / b)));
        uint256 e2 = uint256(FixedPointMathLib.expWad(int256(((supply) * 1e18) / b)));
        return FixedPointMathLib.mulWad(e1 - e2, x);
    }

    function getSellPrice(uint256 supply, uint256 amount) public pure override returns (uint256) {
        return getPrice(supply - amount, amount);
    }

    function getBuyPriceAfterFee(uint256 supply, uint256 amount) public view override returns (uint256) {
        uint256 price = getPrice(supply, amount);
        return ((price * divisor) / (divisor - feeRatio[0] - feeRatio[1]));
    }

    function getSellPriceAfterFee(uint256 supply, uint256 amount) public view override returns (uint256) {
        uint256 price = getSellPrice(supply, amount);
        return (price * (divisor - feeRatio[0] - feeRatio[1])) / divisor;
    }

    function getBuyAmountByValue(uint256 bondingCurveSupply, uint256 ethAmount) public pure override returns (uint256) {
        require(bondingCurveSupply <= 1000000000 ether && ethAmount <= 1000000000 ether, "supply or amount too large");
        uint256 a = 6_500_000_000;
        uint256 b = 2.5175516438e26;
        uint256 ab = FixedPointMathLib.mulWad(a, b);
        uint256 sab = FixedPointMathLib.divWad(ethAmount, ab);
        uint256 e = uint256(FixedPointMathLib.expWad(int256((bondingCurveSupply * 1e18) / b)));
        uint256 ln = uint256(FixedPointMathLib.lnWad(int256(sab + e)));
        return FixedPointMathLib.mulWad(b, ln) - bondingCurveSupply;
    }
}
