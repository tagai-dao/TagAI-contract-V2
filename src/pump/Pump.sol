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
import "./NutboxDeployConfig.sol";

contract Pump is Ownable2Step, IPump, ReentrancyGuard, IBondingCurve {
    address private ipshare;
    address public tokenImplementation;
    uint256 public createFee = 0.005 ether;
    uint256 private divisor = 10000;
    address private feeReceiver = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    uint256[2] private feeRatio = [30, 30]; // 0: to tiptag; 1: to salesman（仅内盘；上市后 Hook 硬编码费率，不读此处）

    // BSC Nutbox stack
    address public nutboxCommunityFactory = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address public hourlyTickCalculator; // HourlyTickCalculator (replaces linearTimeCalculator)
    address public socialCurationFactory = 0xc4674D3fBbD201Ea401a8B7e7285F956178593D8;
    address public nutboxCommittee = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;

    // Uniswap v4 PoolManager (Robinhood testnet PM552; override before deploy)
    address private poolManager = 0x552815eF68E6eb418A3d65D0AA1043d93204F612;
    // Legacy PCS vault — unused on Uniswap v4; kept for IPump ABI compatibility.
    address private vault = address(0);
    address private hookAddress; // TagAISwapHook address

    mapping(address => bool) public createdTokens;
    mapping(string => bool) public createdTicks;

    uint256 public totalTokens;

    /**
     * @param _ipshare IPShare contract address
     * @param _feeReceiver Fee receiver address, pass address(0) to use default
     * @param cfg Nutbox + PoolManager overrides; use NutboxDeployConfigLib.empty() for compile-time defaults
     */
    constructor(address _ipshare, address _feeReceiver, NutboxDeployConfig memory cfg) {
        _initPump(_ipshare, _feeReceiver, cfg);
    }

    function _initPump(address _ipshare, address _feeReceiver, NutboxDeployConfig memory cfg) private {
        ipshare = _ipshare;
        tokenImplementation = address(new Token());
        if (_feeReceiver != address(0)) feeReceiver = _feeReceiver;
        if (cfg.communityFactory != address(0)) nutboxCommunityFactory = cfg.communityFactory;
        if (cfg.calculator != address(0)) hourlyTickCalculator = cfg.calculator;
        if (cfg.socialCurationFactory != address(0)) socialCurationFactory = cfg.socialCurationFactory;
        if (cfg.committee != address(0)) nutboxCommittee = cfg.committee;
        if (cfg.poolManager != address(0)) poolManager = cfg.poolManager;
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

    /// @notice Wire Nutbox stack (CommunityFactory, HourlyTickCalculator, SocialCurationFactory, Committee).
    function adminSetNutbox(
        address communityFactory_,
        address calculator_,
        address socialCurationFactory_,
        address committee_
    ) external onlyOwner {
        nutboxCommunityFactory = communityFactory_;
        hourlyTickCalculator = calculator_;
        socialCurationFactory = socialCurationFactory_;
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

    function createToken(string calldata tick, bytes32 salt) public payable override nonReentrant returns (address) {
        require(msg.sender == tx.origin, "Only EOA");

        if (
            nutboxCommunityFactory == address(0) || hourlyTickCalculator == address(0)
                || socialCurationFactory == address(0) || nutboxCommittee == address(0)
        ) {
            revert NutboxNotConfigured();
        }

        if (createdTicks[tick]) {
            revert TickHasBeenCreated();
        }
        
        // Predict the token address and check if it already exists
        // If the same user uses the same salt, they would get the same token address
        bytes32 cloneSalt = keccak256(abi.encode(msg.sender, salt));
        address predictedAddress = Clones.predictDeterministicAddress(tokenImplementation, cloneSalt, address(this));
        if (createdTokens[predictedAddress]) {
            revert SaltNotAvailable();
        }
        
        createdTicks[tick] = true;

        address creator = msg.sender;
        bool needCreateIPShare = !IIPShare(ipshare).ipshareCreated(creator);
        uint256 ipshareCreateFee = 0;
        if (needCreateIPShare) {
            ipshareCreateFee = IIPShare(ipshare).createFee();
        }

        uint256 nutboxFees = ICommittee(nutboxCommittee).getCreateCommunityFee()
            + ICommittee(nutboxCommittee).getCommunitySettingsFee();
        uint256 totalFixedFee = createFee + ipshareCreateFee + nutboxFees;

        if (msg.value < totalFixedFee) {
            revert InsufficientCreateFee();
        }

        if (needCreateIPShare) {
            IIPShare(ipshare).createShare{value: ipshareCreateFee}(creator);
        }

        if (createFee > 0) {
            (bool success,) = feeReceiver.call{value: createFee}("");
            if (!success) {
                revert InsufficientCreateFee();
            }
        }

        address instance = Clones.cloneDeterministic(tokenImplementation, cloneSalt);

        emit NewToken(tick, instance, creator);

        Token(payable(instance)).initialize(address(this), creator, tick);

        if (msg.value > totalFixedFee) {
            // V11: Pump 捆绑预购由 Token._isPumpPremine() 判定（msg.sender==manager && community 未绑定 && 曲线未售出），走普通 feeRatio。
            (bool success1, bytes memory receiveAmount) = instance.call{value: msg.value - totalFixedFee}(
                abi.encodeWithSignature("buyToken(uint256,address,uint16)", 0, creator, 0)
            );
            if (!success1) {
                revert PreMineTokenFail();
            }
            uint256 receiveAmountUint = abi.decode(receiveAmount, (uint256));

            IERC20(instance).transfer(msg.sender, receiveAmountUint);
            uint256 leftValue = address(this).balance > nutboxFees ? address(this).balance - nutboxFees : 0;
            if (leftValue > 0) {
                (bool success2,) = msg.sender.call{value: leftValue}("");
                if (!success2) {
                    revert RefundFail();
                }
            }
        }

        // HourlyTickCalculator does not need era policy — pass empty bytes
        bytes memory policy = bytes("");

        uint256 createCommFee = ICommittee(nutboxCommittee).getCreateCommunityFee();
        uint256 settingsFee = ICommittee(nutboxCommittee).getCommunitySettingsFee();

        address community = ICommunityFactory(nutboxCommunityFactory).createCommunity{value: createCommFee}(
            false,
            instance,
            address(0),
            bytes(""),
            hourlyTickCalculator,
            policy
        );

        // v2: DO NOT transfer NUTBOX_ALLOCATION to Community.
        // Token holds it until listing, then transfers to Hook.

        ICommunity(community).adminAddPool{value: settingsFee}(
            "Social Curation", _singlePoolRatios(), socialCurationFactory, bytes("")
        );

        address pool = ICommunity(community).activedPools(0);
        Token(payable(instance)).setNutboxAddresses(community, pool);

        emit NutboxLinked(instance, community, pool);

        // Transfer community devFund + ownership to creator (creator becomes dev & owner).
        (bool setDevOk,) = community.call(abi.encodeWithSignature("adminSetDev(address)", creator));
        require(setDevOk, "Set dev failed");
        (bool txOk,) = community.call(abi.encodeWithSignature("transferOwnership(address)", creator));
        require(txOk, "Transfer ownership failed");

        createdTokens[instance] = true;
        totalTokens += 1;
        return instance;
    }

    function _singlePoolRatios() private pure returns (uint16[] memory ratios) {
        ratios = new uint16[](1);
        ratios[0] = 10_000;
    }

    /**
     * Predict the cloned token address from deployer and salt.
     */
    function predictTokenAddress(address deployer, bytes32 salt) public view returns (address) {
        bytes32 cloneSalt = keccak256(abi.encode(deployer, salt));
        return Clones.predictDeterministicAddress(tokenImplementation, cloneSalt, address(this));
    }

    /********************************** bonding curve ********************************/

    /**
     * calculate the eth price when user buy amount tokens
     */
    function getPrice(uint256 supply, uint256 amount) public pure override returns (uint256) {
        require(supply <= 1000000000 ether && amount <= 1000000000 ether, "supply or amount too large");
        // RH: `a` scaled so 650M sell raises ~5 ETH (BSC ~19.17 ETH at a=6.5e9, same `b`).
        uint256 a = 1_624_898_729;
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
        uint256 a = 1_624_898_729;
        uint256 b = 2.5175516438e26;
        uint256 ab = FixedPointMathLib.mulWad(a, b);
        uint256 sab = FixedPointMathLib.divWad(ethAmount, ab);
        uint256 e = uint256(FixedPointMathLib.expWad(int256((bondingCurveSupply * 1e18) / b)));
        uint256 ln = uint256(FixedPointMathLib.lnWad(int256(sab + e)));
        return FixedPointMathLib.mulWad(b, ln) - bondingCurveSupply;
    }
}
