// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {Token12} from "./Token12.sol";
import {NetNetHook} from "./NetNetHook.sol";
import {PermanentLiquidityVault} from "./PermanentLiquidityVault.sol";
import {BurnNet} from "./burnnet/BurnNet.sol";
import {Treasury} from "./treasury/Treasury.sol";
import {SToken} from "./staking/SToken.sol";
import {Staking} from "./staking/Staking.sol";
import {Distributor} from "./distributor/Distributor.sol";
import {BondDepository} from "./bond/BondDepository.sol";
import {PremiumSeller} from "./premium/PremiumSeller.sol";
import {PTeam} from "./pteam/PTeam.sol";
import {IndexBondDesk} from "./pteam/IndexBondDesk.sol";
import {IndexFundFactory} from "./fund/IndexFundFactory.sol";

/// @title Pump12
/// @notice Pump12 工厂；创建 Token12 并在后续阶段协调原子 Listing。
contract Pump12 is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    uint256 private constant CURVE_ALLOCATION = 750_000_000e18;
    uint256 private constant BASE_POL_ALLOCATION = 250_000_000e18;
    int24 private constant TICK_SPACING = 60;
    uint256 public constant RH_CHAIN_ID = 4663;
    uint8 public constant USDG_DECIMALS = 6;
    address public constant CANONICAL_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant CANONICAL_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    error UnsupportedChain(uint256 actualChainId);
    error InvalidUsdG(address actual);
    error UsdGHasNoCode(address target);
    error InvalidUsdGDecimals(uint8 actualDecimals);
    error InvalidPoolManager(address actual);
    error PoolManagerHasNoCode(address target);
    error OnlyTagAI();
    error HookAlreadySet();
    error InvalidHook();
    error TokenNotCreated();
    error TokenAlreadyListed();
    error CurveNotComplete();
    error InvalidTotalFeeBps();
    error InvalidCreatorShareBps();
    error InvalidAddress();
    error EmptyTokenMetadata();
    error SymbolAlreadyCreated();
    error SaltAlreadyUsed();
    error EmissionImplementationsAlreadySet();
    error EmissionImplementationsNotSet();
    error InvalidImplementation();
    error PTeamImplementationsAlreadySet();
    error PTeamImplementationsNotSet();
    error InvalidIndexToken();

    event TokenCreated(address indexed token, address indexed creator, string symbol, bytes32 indexed salt);
    event HookConfigured(address indexed hook);
    event EmissionImplementationsConfigured(
        address treasury, address sToken, address staking, address distributor, address bond, address premium
    );
    event PTeamImplementationsConfigured(address pTeam, address indexBondDesk, address indexFundFactory);
    event TokenListed(
        address indexed token,
        PoolId indexed poolId,
        address indexed liquidityVault,
        address burnNet,
        uint160 sqrtPriceX96
    );

    struct EmissionModules {
        address treasury;
        address sToken;
        address staking;
        address distributor;
        address bondDepository;
        address premiumSeller;
        address pTeam;
        address indexBondDesk;
        address indexFund;
    }

    struct CreateParams {
        string name;
        string symbol;
        bytes32 salt;
        uint16 totalFeeBps;
        uint16 creatorShareBps;
        address creatorFeeRecipient;
        address indexToken;
        address pTeamHolder;
    }

    address public immutable usdg;
    address public immutable poolManager;
    address public immutable tagAI;
    address public immutable tokenImplementation;
    address public immutable liquidityVaultImplementation;
    address public immutable burnNetImplementation;
    address public hook;
    address public treasuryImplementation;
    address public sTokenImplementation;
    address public stakingImplementation;
    address public distributorImplementation;
    address public bondImplementation;
    address public premiumImplementation;
    address public pTeamImplementation;
    address public indexBondDeskImplementation;
    address public indexFundFactory;

    mapping(address token => bool created) public createdTokens;
    mapping(bytes32 symbolHash => bool created) public createdSymbols;
    mapping(address token => address burnNet) public tokenBurnNet;
    mapping(address token => EmissionModules modules) public tokenEmissionModules;

    constructor(address usdg_, address poolManager_) {
        if (block.chainid != RH_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (usdg_ != CANONICAL_USDG) revert InvalidUsdG(usdg_);
        if (usdg_.code.length == 0) revert UsdGHasNoCode(usdg_);

        uint8 actualDecimals;
        try IERC20Metadata(usdg_).decimals() returns (uint8 decimals_) {
            actualDecimals = decimals_;
        } catch {
            revert InvalidUsdGDecimals(type(uint8).max);
        }
        if (actualDecimals != USDG_DECIMALS) revert InvalidUsdGDecimals(actualDecimals);

        if (poolManager_ != CANONICAL_POOL_MANAGER) revert InvalidPoolManager(poolManager_);
        if (poolManager_.code.length == 0) revert PoolManagerHasNoCode(poolManager_);

        usdg = usdg_;
        poolManager = poolManager_;
        tagAI = msg.sender;
        tokenImplementation = address(new Token12());
        liquidityVaultImplementation = address(new PermanentLiquidityVault());
        burnNetImplementation = address(new BurnNet());
    }

    function createToken(CreateParams calldata params) external nonReentrant returns (address instance) {
        if (params.totalFeeBps < 100 || params.totalFeeBps > 1_000) revert InvalidTotalFeeBps();
        if (params.creatorShareBps > 3_000) revert InvalidCreatorShareBps();
        if (
            params.creatorFeeRecipient == address(0) || params.indexToken == address(0)
                || params.pTeamHolder == address(0)
        ) {
            revert InvalidAddress();
        }
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert EmptyTokenMetadata();
        address indexFactory = indexFundFactory;
        if (indexFactory == address(0)) revert PTeamImplementationsNotSet();
        if (!IndexFundFactory(indexFactory).isRegisteredIndex(params.indexToken)) {
            revert InvalidIndexToken();
        }

        bytes32 symbolHash = keccak256(bytes(params.symbol));
        if (createdSymbols[symbolHash]) revert SymbolAlreadyCreated();

        bytes32 cloneSalt = keccak256(abi.encode(msg.sender, params.salt));
        instance = Clones.predictDeterministicAddress(tokenImplementation, cloneSalt, address(this));
        if (createdTokens[instance]) revert SaltAlreadyUsed();

        createdSymbols[symbolHash] = true;
        createdTokens[instance] = true;
        instance = Clones.cloneDeterministic(tokenImplementation, cloneSalt);
        Token12(instance)
            .initialize(
                address(this),
                msg.sender,
                tagAI,
                usdg,
                params.name,
                params.symbol,
                params.totalFeeBps,
                params.creatorShareBps,
                params.creatorFeeRecipient,
                params.indexToken,
                params.pTeamHolder
            );

        emit TokenCreated(instance, msg.sender, params.symbol, params.salt);
    }

    function predictTokenAddress(address creator, bytes32 salt) external view returns (address) {
        bytes32 cloneSalt = keccak256(abi.encode(creator, salt));
        return Clones.predictDeterministicAddress(tokenImplementation, cloneSalt, address(this));
    }

    function setHook(address hook_) external {
        if (msg.sender != tagAI) revert OnlyTagAI();
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_.code.length == 0 || uint160(hook_) & ((1 << 14) - 1) != 0x20CC) revert InvalidHook();
        NetNetHook candidate = NetNetHook(hook_);
        if (
            address(candidate.poolManager()) != poolManager || address(candidate.pump()) != address(this)
                || address(candidate.usdg()) != usdg
        ) revert InvalidHook();
        hook = hook_;
        emit HookConfigured(hook_);
    }

    /// @notice Configures immutable clone templates without embedding their bytecode in Pump12 initcode.
    function setEmissionImplementations(
        address treasuryImplementation_,
        address sTokenImplementation_,
        address stakingImplementation_,
        address distributorImplementation_,
        address bondImplementation_,
        address premiumImplementation_
    ) external {
        if (msg.sender != tagAI) revert OnlyTagAI();
        if (treasuryImplementation != address(0)) revert EmissionImplementationsAlreadySet();
        if (
            treasuryImplementation_.code.length == 0 || sTokenImplementation_.code.length == 0
                || stakingImplementation_.code.length == 0 || distributorImplementation_.code.length == 0
                || bondImplementation_.code.length == 0 || premiumImplementation_.code.length == 0
        ) revert InvalidImplementation();
        treasuryImplementation = treasuryImplementation_;
        sTokenImplementation = sTokenImplementation_;
        stakingImplementation = stakingImplementation_;
        distributorImplementation = distributorImplementation_;
        bondImplementation = bondImplementation_;
        premiumImplementation = premiumImplementation_;
        emit EmissionImplementationsConfigured(
            treasuryImplementation_,
            sTokenImplementation_,
            stakingImplementation_,
            distributorImplementation_,
            bondImplementation_,
            premiumImplementation_
        );
    }

    function setPTeamImplementations(
        address pTeamImplementation_,
        address indexBondDeskImplementation_,
        address indexFundFactory_
    ) external {
        if (msg.sender != tagAI) revert OnlyTagAI();
        if (pTeamImplementation != address(0)) revert PTeamImplementationsAlreadySet();
        if (
            pTeamImplementation_.code.length == 0 || indexBondDeskImplementation_.code.length == 0
                || indexFundFactory_.code.length == 0 || IndexFundFactory(indexFundFactory_).pump() != address(this)
                || IndexFundFactory(indexFundFactory_).tagAI() != tagAI
                || IndexFundFactory(indexFundFactory_).usdg() != usdg
                || IndexFundFactory(indexFundFactory_).poolManager() != poolManager
        ) revert InvalidImplementation();
        pTeamImplementation = pTeamImplementation_;
        indexBondDeskImplementation = indexBondDeskImplementation_;
        indexFundFactory = indexFundFactory_;
        emit PTeamImplementationsConfigured(pTeamImplementation_, indexBondDeskImplementation_, indexFundFactory_);
    }

    /// @notice 售满后原子创建官方 v4 池，并将基础全域 POL 永久锁入无提款 Vault。
    function list(address token) external nonReentrant returns (PoolId poolId, address vaultAddress) {
        if (!createdTokens[token]) revert TokenNotCreated();
        Token12 token12 = Token12(token);
        if (token12.listed()) revert TokenAlreadyListed();
        if (token12.bondingCurveSupply() != CURVE_ALLOCATION || token12.curveReserveRaw() != 15_000e6) {
            revert CurveNotComplete();
        }
        address hook_ = hook;
        if (hook_ == address(0)) revert InvalidHook();
        if (treasuryImplementation == address(0)) revert EmissionImplementationsNotSet();
        if (pTeamImplementation == address(0)) revert PTeamImplementationsNotSet();

        PermanentLiquidityVault vault = PermanentLiquidityVault(Clones.clone(liquidityVaultImplementation));
        vault.initialize(IPoolManager(poolManager), address(this), token, usdg);
        vaultAddress = address(vault);

        Currency tokenCurrency = Currency.wrap(token);
        Currency usdgCurrency = Currency.wrap(usdg);
        (Currency currency0, Currency currency1) =
            tokenCurrency < usdgCurrency ? (tokenCurrency, usdgCurrency) : (usdgCurrency, tokenCurrency);
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(hook_)
        });
        poolId = key.toId();

        BurnNet burnNet = BurnNet(Clones.clone(burnNetImplementation));
        address burnNetAddress = address(burnNet);
        burnNet.initialize(hook_, token, usdg, poolManager, poolId, token12.curveEndPrice(), uint40(block.timestamp));
        tokenBurnNet[token] = burnNetAddress;

        Treasury treasury = Treasury(Clones.clone(treasuryImplementation));
        SToken sToken = SToken(Clones.clone(sTokenImplementation));
        Staking staking = Staking(Clones.clone(stakingImplementation));
        Distributor distributor = Distributor(Clones.clone(distributorImplementation));
        BondDepository bond = BondDepository(Clones.clone(bondImplementation));
        PremiumSeller premium = PremiumSeller(Clones.clone(premiumImplementation));
        PTeam pTeam = PTeam(Clones.clone(pTeamImplementation));
        IndexBondDesk indexBondDesk = IndexBondDesk(Clones.clone(indexBondDeskImplementation));
        address indexFund = IndexFundFactory(indexFundFactory)
            .createFund(
                token,
                token12.indexToken(),
                token12.creator(),
                token12.creatorFeeRecipient(),
                address(indexBondDesk),
                burnNetAddress,
                hook_,
                poolId
            );
        EmissionModules memory modules = EmissionModules({
            treasury: address(treasury),
            sToken: address(sToken),
            staking: address(staking),
            distributor: address(distributor),
            bondDepository: address(bond),
            premiumSeller: address(premium),
            pTeam: address(pTeam),
            indexBondDesk: address(indexBondDesk),
            indexFund: indexFund
        });
        tokenEmissionModules[token] = modules;

        sToken.initialize(
            address(staking), string.concat("Staked ", token12.name()), string.concat("s", token12.symbol())
        );
        staking.initialize(token, address(sToken), address(distributor), uint40(block.timestamp));
        distributor.initialize(
            address(treasury),
            token,
            address(sToken),
            address(staking),
            hook_,
            burnNetAddress,
            poolId,
            token12.curveEndPrice()
        );
        bond.initialize(usdg, token, hook_, burnNetAddress, address(treasury), poolId, uint40(block.timestamp));
        premium.initialize(
            token,
            usdg,
            hook_,
            burnNetAddress,
            address(treasury),
            vaultAddress,
            poolManager,
            poolId,
            uint40(block.timestamp)
        );
        indexBondDesk.initialize(usdg, token, hook_, burnNetAddress, indexFund, poolId);
        pTeam.initialize(
            token,
            token12.pTeamHolder(),
            address(treasury),
            address(indexBondDesk),
            hook_,
            burnNetAddress,
            poolId,
            uint40(block.timestamp)
        );
        treasury.initialize(
            token, burnNetAddress, address(distributor), address(bond), address(premium), address(pTeam)
        );

        NetNetHook(hook_).registerPool(key, token, vaultAddress, burnNetAddress, address(premium));
        token12.prepareListing(vaultAddress, burnNetAddress, address(treasury), PoolId.unwrap(poolId));

        uint256 amount0 = Currency.unwrap(currency0) == token ? BASE_POL_ALLOCATION : 15_000e6;
        uint256 amount1 = Currency.unwrap(currency1) == token ? BASE_POL_ALLOCATION : 15_000e6;
        uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(ratioX192));
        vault.initializeAndLock(key, sqrtPriceX96);

        emit TokenListed(token, poolId, vaultAddress, burnNetAddress, sqrtPriceX96);
    }
}
