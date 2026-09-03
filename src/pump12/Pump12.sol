// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {Token12} from "./Token12.sol";

/// @title Pump12
/// @notice Pump12 工厂；创建 Token12 并在后续阶段协调原子 Listing。
contract Pump12 is ReentrancyGuard {
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
    error TaskNotImplemented();
    error InvalidTotalFeeBps();
    error InvalidCreatorShareBps();
    error InvalidAddress();
    error EmptyTokenMetadata();
    error SymbolAlreadyCreated();
    error SaltAlreadyUsed();

    event TokenCreated(address indexed token, address indexed creator, string symbol, bytes32 indexed salt);

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

    mapping(address token => bool created) public createdTokens;
    mapping(bytes32 symbolHash => bool created) public createdSymbols;

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

    /// @dev Task 1 将替换为原子 Listing 流程。
    function list(address) external pure {
        revert TaskNotImplemented();
    }
}
