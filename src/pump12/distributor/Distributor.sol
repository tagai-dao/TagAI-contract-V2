// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IToken12Distributor {
    function totalSupply() external view returns (uint256);
}

interface ISTokenDistributor {
    function totalSupply() external view returns (uint256);
}

interface ITreasuryDistributor {
    function mintByDistributor(address to, uint256 amount) external;
}

interface IHookDistributor {
    function validTWAP(PoolId id) external view returns (uint256 priceWad);
}

interface IBurnNetDistributor {
    function anchor() external view returns (uint256);
    function mintingAvailable() external view returns (bool);
    function eligibleTradeFeeReserveUSDG() external view returns (uint256);
    function consumedEligibleTradeFeeUSDG() external view returns (uint256);
    function totalBurned() external view returns (uint256);
}

/// @title Distributor
/// @notice Premium-throttled staking emissions constrained by eligible reserve and actual-burn credit.
contract Distributor {
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_RATE_WAD = 45e14; // 0.45% per 8 hours.
    uint256 public constant FULL_RATE_PREMIUM_WAD = 175e16; // 1.75x.
    uint256 public constant BOOTSTRAP_CREDIT = 37_500_000e18;
    uint256 private constant RAW_USDG_TO_TOKEN_WAD_SCALE = 1e30;

    error AlreadyInitialized();
    error InvalidInitialization();
    error OnlyStaking();

    bool public initialized;
    ITreasuryDistributor public treasury;
    IToken12Distributor public token;
    ISTokenDistributor public sToken;
    address public staking;
    IHookDistributor public hook;
    IBurnNetDistributor public burnNet;
    PoolId public poolId;
    uint256 public initialAnchor;
    uint256 public totalMinted;
    uint64 public epochsDistributed;

    event DistributorInitialized(
        address indexed token, address indexed staking, address indexed treasury, PoolId poolId, uint256 initialAnchor
    );
    event Distributed(uint64 indexed epoch, uint256 minted, uint256 rateWad, uint256 availableCreditBefore);

    constructor() {
        initialized = true;
    }

    function initialize(
        address treasury_,
        address token_,
        address sToken_,
        address staking_,
        address hook_,
        address burnNet_,
        PoolId poolId_,
        uint256 initialAnchor_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            treasury_.code.length == 0 || token_.code.length == 0 || sToken_.code.length == 0
                || staking_.code.length == 0 || hook_.code.length == 0 || burnNet_.code.length == 0
                || PoolId.unwrap(poolId_) == bytes32(0) || initialAnchor_ == 0
        ) revert InvalidInitialization();
        initialized = true;
        treasury = ITreasuryDistributor(treasury_);
        token = IToken12Distributor(token_);
        sToken = ISTokenDistributor(sToken_);
        staking = staking_;
        hook = IHookDistributor(hook_);
        burnNet = IBurnNetDistributor(burnNet_);
        poolId = poolId_;
        initialAnchor = initialAnchor_;
        emit DistributorInitialized(token_, staking_, treasury_, poolId_, initialAnchor_);
    }

    function distribute() external returns (uint256 minted) {
        if (msg.sender != staking) revert OnlyStaking();
        uint256 rate = currentRateWad();
        uint256 credit = availableCredit();
        if (rate != 0 && credit != 0 && sToken.totalSupply() != 0) {
            uint256 formulaReward = Math.mulDiv(token.totalSupply(), rate, WAD);
            minted = formulaReward < credit ? formulaReward : credit;
        }
        ++epochsDistributed;
        if (minted != 0) {
            totalMinted += minted;
            treasury.mintByDistributor(staking, minted);
        }
        emit Distributed(epochsDistributed, minted, rate, credit);
    }

    function premiumWad() public view returns (uint256) {
        uint256 marketPrice = hook.validTWAP(poolId);
        uint256 referencePrice = emissionAnchor();
        return referencePrice == 0 ? 0 : Math.mulDiv(marketPrice, WAD, referencePrice);
    }

    function emissionAnchor() public view returns (uint256) {
        uint256 currentAnchor = burnNet.anchor();
        return currentAnchor > initialAnchor ? currentAnchor : initialAnchor;
    }

    function currentRateWad() public view returns (uint256) {
        try burnNet.mintingAvailable() returns (bool available) {
            if (!available) return 0;
        } catch {
            return 0;
        }

        uint256 premium;
        try Distributor(address(this)).premiumWad() returns (uint256 value) {
            premium = value;
        } catch {
            return 0;
        }
        if (premium <= WAD) return 0;
        if (premium >= FULL_RATE_PREMIUM_WAD) return MAX_RATE_WAD;
        return Math.mulDiv(MAX_RATE_WAD, premium - WAD, FULL_RATE_PREMIUM_WAD - WAD);
    }

    function reserveCredit() public view returns (uint256) {
        uint256 eligible = burnNet.eligibleTradeFeeReserveUSDG();
        uint256 consumed = burnNet.consumedEligibleTradeFeeUSDG();
        if (consumed >= eligible) return 0;
        return Math.mulDiv(eligible - consumed, RAW_USDG_TO_TOKEN_WAD_SCALE, initialAnchor);
    }

    function currentCreditLimit() public view returns (uint256) {
        return BOOTSTRAP_CREDIT + reserveCredit() + burnNet.totalBurned();
    }

    function availableCredit() public view returns (uint256) {
        uint256 limit = currentCreditLimit();
        return totalMinted >= limit ? 0 : limit - totalMinted;
    }

    function nextReward() external view returns (uint256) {
        if (sToken.totalSupply() == 0) return 0;
        uint256 rate = currentRateWad();
        if (rate == 0) return 0;
        uint256 reward = Math.mulDiv(token.totalSupply(), rate, WAD);
        uint256 credit = availableCredit();
        return reward < credit ? reward : credit;
    }
}
