// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {Distributor} from "../../../src/pump12/distributor/Distributor.sol";

contract DistributorMockToken {
    uint256 public totalSupply = 1_000_000_000e18;

    function mint(uint256 amount) external {
        totalSupply += amount;
    }
}

contract DistributorMockSToken {
    uint256 public totalSupply = 100e18;

    function setTotalSupply(uint256 amount) external {
        totalSupply = amount;
    }
}

contract DistributorMockHook {
    uint256 public price = 1e18;
    bool public shouldRevert;

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function validTWAP(PoolId) external view returns (uint256) {
        require(!shouldRevert, "invalid TWAP");
        return price;
    }
}

contract DistributorMockBurnNet {
    uint256 public anchor = 1e18;
    bool public mintingAvailable = true;
    uint256 public eligibleTradeFeeReserveUSDG;
    uint256 public consumedEligibleTradeFeeUSDG;
    uint256 public totalBurned;

    function setAnchor(uint256 value) external {
        anchor = value;
    }

    function setMintingAvailable(bool value) external {
        mintingAvailable = value;
    }

    function setCreditInputs(uint256 eligibleRaw, uint256 consumedRaw, uint256 burned) external {
        eligibleTradeFeeReserveUSDG = eligibleRaw;
        consumedEligibleTradeFeeUSDG = consumedRaw;
        totalBurned = burned;
    }
}

contract DistributorMockTreasury {
    DistributorMockToken public immutable token;
    uint256 public minted;

    constructor(DistributorMockToken token_) {
        token = token_;
    }

    function mintByDistributor(address, uint256 amount) external {
        minted += amount;
        token.mint(amount);
    }
}

contract DistributorTest is Test {
    Distributor internal distributor;
    DistributorMockToken internal token;
    DistributorMockSToken internal sToken;
    DistributorMockHook internal hook;
    DistributorMockBurnNet internal burnNet;
    DistributorMockTreasury internal treasury;

    function setUp() public {
        token = new DistributorMockToken();
        sToken = new DistributorMockSToken();
        hook = new DistributorMockHook();
        burnNet = new DistributorMockBurnNet();
        treasury = new DistributorMockTreasury(token);
        distributor = Distributor(Clones.clone(address(new Distributor())));
        distributor.initialize(
            address(treasury),
            address(token),
            address(sToken),
            address(this),
            address(hook),
            address(burnNet),
            PoolId.wrap(bytes32(uint256(1))),
            1e18
        );
    }

    function test_rateIsZeroLinearAndCappedByPremium() public {
        hook.setPrice(1e18);
        assertEq(distributor.currentRateWad(), 0);

        hook.setPrice(1_375e15);
        assertEq(distributor.currentRateWad(), distributor.MAX_RATE_WAD() / 2);

        hook.setPrice(1_750e15);
        assertEq(distributor.currentRateWad(), distributor.MAX_RATE_WAD());
        hook.setPrice(4e18);
        assertEq(distributor.currentRateWad(), distributor.MAX_RATE_WAD());
    }

    function test_currentAnchorAboveInitialRaisesEmissionThreshold() public {
        burnNet.setAnchor(2e18);
        hook.setPrice(2e18);
        assertEq(distributor.emissionAnchor(), 2e18);
        assertEq(distributor.currentRateWad(), 0);

        hook.setPrice(2_750e15);
        assertEq(distributor.currentRateWad(), distributor.MAX_RATE_WAD() / 2);
    }

    function test_invalidOracleFreezeAndZeroStakeAllMintZero() public {
        hook.setPrice(2e18);
        hook.setShouldRevert(true);
        assertEq(distributor.currentRateWad(), 0);
        assertEq(distributor.nextReward(), 0);

        hook.setShouldRevert(false);
        burnNet.setMintingAvailable(false);
        assertEq(distributor.nextReward(), 0);

        burnNet.setMintingAvailable(true);
        sToken.setTotalSupply(0);
        assertEq(distributor.nextReward(), 0);
        assertEq(distributor.distribute(), 0);
        assertEq(distributor.totalMinted(), 0);
    }

    function test_creditClampsThenEligibleAndBurnRestoreExactly() public {
        hook.setPrice(2e18);
        for (uint256 i; i < 20 && distributor.availableCredit() != 0; ++i) {
            distributor.distribute();
        }
        assertEq(distributor.totalMinted(), distributor.BOOTSTRAP_CREDIT());
        assertEq(distributor.availableCredit(), 0);

        burnNet.setCreditInputs(100e6, 0, 20e18);
        assertEq(distributor.reserveCredit(), 100e18);
        assertEq(distributor.availableCredit(), 120e18);
        assertEq(distributor.distribute(), 120e18);
        assertEq(distributor.availableCredit(), 0);

        burnNet.setCreditInputs(100e6, 50e6, 20e18);
        assertEq(distributor.reserveCredit(), 50e18);
        assertEq(distributor.availableCredit(), 0);
        burnNet.setCreditInputs(100e6, 200e6, 20e18);
        assertEq(distributor.reserveCredit(), 0);
    }

    function test_onlyStakingMayDistribute() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Distributor.OnlyStaking.selector);
        distributor.distribute();
    }
}
