// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {PTeam} from "../../../src/pump12/pteam/PTeam.sol";
import {IndexBondDesk} from "../../../src/pump12/pteam/IndexBondDesk.sol";
import {IIndexFund} from "../../../src/pump12/fund/IIndexFund.sol";

contract PTeamDeskToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    uint8 private immutable _decimals;

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PTeamDeskHook {
    IERC20 public immutable usdg;
    uint256 public twap;
    mapping(PoolId => uint256) public pending;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function setTWAP(uint256 value) external {
        twap = value;
    }

    function validTWAP(PoolId) external view returns (uint256) {
        require(twap != 0, "invalid TWAP");
        return twap;
    }

    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256) {
        require(usdg.transferFrom(msg.sender, address(this), amount));
        pending[id] += amount;
        return amount;
    }
}

contract PTeamDeskBurnNet {
    uint256 public anchor;
    bool public mintingAvailable = true;

    constructor(uint256 anchor_) {
        anchor = anchor_;
    }

    function setAvailable(bool value) external {
        mintingAvailable = value;
    }
}

contract PTeamDeskTreasury {
    PTeamDeskToken public immutable token;
    address public pTeam;

    constructor(PTeamDeskToken token_) {
        token = token_;
    }

    function setPTeam(address pTeam_) external {
        require(pTeam == address(0));
        pTeam = pTeam_;
    }

    function mintByPTeam(address to, uint256 amount) external {
        require(msg.sender == pTeam, "only pteam");
        token.mint(to, amount);
    }
}

contract PTeamDeskFund is IIndexFund {
    IERC20 public immutable usdg;
    uint256 public invested;
    bool public shouldRevert;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function initialize(InitParams calldata) external pure {
        revert("not clone implementation");
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function onDeskProceeds(uint256 amount) external returns (uint256) {
        if (shouldRevert) revert("index purchase failed");
        require(usdg.balanceOf(address(this)) >= invested + amount);
        invested += amount;
        return amount * 1e12;
    }
}

contract PTeamInventoryGate {
    bool public allowed = true;

    function setAllowed(bool value) external {
        allowed = value;
    }

    function canReceiveInventory(uint256, uint256) external view returns (bool) {
        return allowed;
    }
}

contract PTeamDeskTest is Test {
    uint256 internal constant ANCHOR = 60_000_000_000_000;
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));

    address internal holder = makeAddr("holder");
    address internal buyer = makeAddr("buyer");
    PTeamDeskToken internal token;
    PTeamDeskToken internal usdg;
    PTeamDeskHook internal hook;
    PTeamDeskBurnNet internal burnNet;
    PTeamDeskTreasury internal treasury;
    PTeamDeskFund internal fund;
    PTeam internal pTeam;
    IndexBondDesk internal desk;
    uint40 internal listedAt;

    function setUp() public {
        vm.warp(10 days);
        listedAt = uint40(block.timestamp);
        token = new PTeamDeskToken("Token", "TOK", 18);
        usdg = new PTeamDeskToken("USDG", "USDG", 6);
        token.mint(address(this), 1_000_000_000e18);
        hook = new PTeamDeskHook(IERC20(address(usdg)));
        hook.setTWAP(ANCHOR * 2);
        burnNet = new PTeamDeskBurnNet(ANCHOR);
        treasury = new PTeamDeskTreasury(token);
        fund = new PTeamDeskFund(IERC20(address(usdg)));
        pTeam = PTeam(Clones.clone(address(new PTeam())));
        desk = IndexBondDesk(Clones.clone(address(new IndexBondDesk())));
        desk.initialize(address(usdg), address(token), address(hook), address(burnNet), address(fund), POOL_ID);
        pTeam.initialize(
            address(token), holder, address(treasury), address(desk), address(hook), address(burnNet), POOL_ID, listedAt
        );
        treasury.setPTeam(address(pTeam));
    }

    function test_pTeamRequiresDelayPremiumHolderAndMintAvailability() public {
        vm.expectRevert(PTeam.OnlyHolder.selector);
        pTeam.exercise(1e18);

        vm.expectRevert(PTeam.NotActive.selector);
        vm.prank(holder);
        pTeam.exercise(1e18);

        vm.warp(listedAt + 24 hours);
        hook.setTWAP(ANCHOR * 12 / 10 - 1);
        vm.expectRevert(PTeam.NotActive.selector);
        vm.prank(holder);
        pTeam.exercise(1e18);

        hook.setTWAP(ANCHOR * 12 / 10);
        burnNet.setAvailable(false);
        vm.expectRevert(PTeam.NotActive.selector);
        vm.prank(holder);
        pTeam.exercise(1e18);
    }

    function test_pTeamMintsOnlyToDeskAndEnforcesUnsoldInventoryCap() public {
        vm.warp(listedAt + 24 hours);
        vm.prank(holder);
        pTeam.exercise(5_000_000e18);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(desk)), 5_000_000e18);
        assertEq(pTeam.exercised(), 5_000_000e18);

        vm.expectRevert(PTeam.ExceedsDeskInventoryCap.selector);
        vm.prank(holder);
        pTeam.exercise(100_000e18);
    }

    function test_pTeamDynamicCumulativeCap() public {
        PTeamInventoryGate permissiveDesk = new PTeamInventoryGate();
        PTeam isolated = PTeam(Clones.clone(address(new PTeam())));
        PTeamDeskTreasury isolatedTreasury = new PTeamDeskTreasury(token);
        isolated.initialize(
            address(token),
            holder,
            address(isolatedTreasury),
            address(permissiveDesk),
            address(hook),
            address(burnNet),
            POOL_ID,
            listedAt
        );
        isolatedTreasury.setPTeam(address(isolated));
        vm.warp(listedAt + 24 hours);
        uint256 cap = isolated.exercisableNow();
        assertEq(cap, 100_000_000e18);
        vm.prank(holder);
        isolated.exercise(cap);
        assertEq(isolated.exercised(), cap);
        assertEq(isolated.exercisableNow(), 10_000_000e18);
    }

    function test_deskPriceRoutesAnchorAndPremiumAndVestsForTwoDays() public {
        token.mint(address(desk), 1_000_000e18);
        uint256 amount = 100_000e18;
        uint256 expectedPrice = ANCHOR * 9_350 / 10_000 * 2;
        assertEq(desk.deskPrice(), expectedPrice);
        uint256 expectedTotal = amount * expectedPrice / 1e30;
        uint256 expectedAnchor = amount * ANCHOR / 1e30;
        usdg.mint(buyer, expectedTotal);

        vm.startPrank(buyer);
        usdg.approve(address(desk), expectedTotal);
        (uint256 noteId, uint256 paid) = desk.subscribe(amount, expectedPrice, buyer);
        vm.stopPrank();

        assertEq(paid, expectedTotal);
        assertEq(hook.pending(POOL_ID), expectedAnchor);
        assertEq(fund.invested(), expectedTotal - expectedAnchor);
        assertEq(desk.outstandingVestingLiability(), amount);
        assertEq(desk.unsoldInventory(), 900_000e18);
        assertEq(token.balanceOf(buyer), 0);

        vm.warp(listedAt + 1 days);
        vm.prank(buyer);
        uint256 half = desk.redeem(noteId, buyer);
        assertEq(half, amount / 2);
        vm.warp(listedAt + 2 days);
        vm.prank(buyer);
        uint256 rest = desk.redeem(noteId, buyer);
        assertEq(rest, amount - half);
        assertEq(token.balanceOf(buyer), amount);
        assertEq(desk.outstandingVestingLiability(), 0);
        assertEq(desk.unsoldInventory(), 900_000e18);
    }

    function test_indexPurchaseFailureRevertsEntireSubscription() public {
        token.mint(address(desk), 1_000_000e18);
        uint256 amount = 100_000e18;
        uint256 total = amount * desk.deskPrice() / 1e30;
        usdg.mint(buyer, total);
        fund.setShouldRevert(true);

        vm.startPrank(buyer);
        usdg.approve(address(desk), total);
        vm.expectRevert(bytes("index purchase failed"));
        desk.subscribe(amount, type(uint256).max, buyer);
        vm.stopPrank();
        assertEq(usdg.balanceOf(buyer), total);
        assertEq(hook.pending(POOL_ID), 0);
        assertEq(desk.noteCount(buyer), 0);
    }

    function test_deskSubscriptionStopsDuringUnifiedMintFreeze() public {
        token.mint(address(desk), 1_000_000e18);
        uint256 total = 100_000e18 * desk.deskPrice() / 1e30;
        usdg.mint(buyer, total);
        burnNet.setAvailable(false);

        vm.startPrank(buyer);
        usdg.approve(address(desk), total);
        vm.expectRevert(IndexBondDesk.NotActive.selector);
        desk.subscribe(100_000e18, type(uint256).max, buyer);
        vm.stopPrank();
    }
}
