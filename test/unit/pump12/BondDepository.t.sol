// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BondDepository} from "../../../src/pump12/bond/BondDepository.sol";

contract BondMockToken is ERC20 {
    constructor() ERC20("Token", "TKN") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BondMockUSDG is ERC20 {
    constructor() ERC20("USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BondMockHook {
    IERC20 public immutable usdg;
    uint256 public price = 1e18;
    uint256 public pending;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function setPrice(uint256 value) external {
        price = value;
    }

    function validTWAP(PoolId) external view returns (uint256) {
        return price;
    }

    function addPendingUSDG(PoolId, uint256 amount) external returns (uint256) {
        usdg.transferFrom(msg.sender, address(this), amount);
        pending += amount;
        return amount;
    }
}

contract BondMockBurnNet {
    uint256 public anchor = 1e18;

    function setAnchor(uint256 value) external {
        anchor = value;
    }
}

contract BondMockTreasury {
    BondMockToken public immutable token;

    constructor(BondMockToken token_) {
        token = token_;
    }

    function mintByBond(address to, uint256 amount) external {
        token.mint(to, amount);
    }
}

contract BondDepositoryTest is Test {
    address internal user = makeAddr("user");
    BondMockToken internal token;
    BondMockUSDG internal usdg;
    BondMockHook internal hook;
    BondMockBurnNet internal burnNet;
    BondMockTreasury internal treasury;
    BondDepository internal bond;
    uint40 internal start;

    function setUp() public {
        token = new BondMockToken();
        usdg = new BondMockUSDG();
        hook = new BondMockHook(usdg);
        burnNet = new BondMockBurnNet();
        treasury = new BondMockTreasury(token);
        bond = BondDepository(Clones.clone(address(new BondDepository())));
        start = uint40(block.timestamp);
        bond.initialize(
            address(usdg),
            address(token),
            address(hook),
            address(burnNet),
            address(treasury),
            PoolId.wrap(bytes32(uint256(1))),
            start
        );
        usdg.mint(user, 60_000_000e6);
        vm.prank(user);
        usdg.approve(address(bond), type(uint256).max);
    }

    function test_priceUsesDiscountButNeverFallsBelowAnchor() public {
        hook.setPrice(2e18);
        assertEq(bond.bondPrice(), 1.94e18);
        hook.setPrice(0.5e18);
        assertEq(bond.bondPrice(), 1e18);
    }

    function test_epochAndThirtyDayCapsUsePeriodStartSupply() public {
        hook.setPrice(1e18);
        vm.prank(user);
        bond.deposit(2_500_000e6, 1e18, user);
        vm.prank(user);
        vm.expectRevert(BondDepository.EpochCapExceeded.selector);
        bond.deposit(1, 1e18, user);

        for (uint256 i = 1; i < 20; ++i) {
            vm.warp(start + i * 8 hours);
            vm.prank(user);
            bond.deposit(2_500_000e6, 1e18, user);
        }
        vm.prank(user);
        vm.expectRevert(BondDepository.PeriodCapExceeded.selector);
        bond.deposit(1, 1e18, user);

        vm.warp(start + 30 days);
        vm.prank(user);
        bond.deposit(1, 1e18, user);
        (, uint256 periodStartSupply,,) = bond.periodCapacity();
        assertEq(periodStartSupply, 1_050_000_000e18);
    }
}
