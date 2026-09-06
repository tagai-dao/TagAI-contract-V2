// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Pump12} from "../../../src/pump12/Pump12.sol";
import {Token12} from "../../../src/pump12/Token12.sol";

contract CurveTestUsdG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CurveTestPoolManager {}

contract CurveTestIndexFundFactory {
    address public immutable pump;
    address public immutable tagAI;
    address public immutable usdg;
    address public immutable poolManager;

    constructor(address pump_, address tagAI_, address usdg_, address poolManager_) {
        pump = pump_;
        tagAI = tagAI_;
        usdg = usdg_;
        poolManager = poolManager_;
    }

    function isRegisteredIndex(address candidate) external pure returns (bool) {
        return candidate != address(0);
    }
}

contract RejectUsdGReceiver {}

contract Token12CurveTest is Test {
    uint256 internal constant RH_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address internal tagAI = makeAddr("tagAI");
    address internal creator = makeAddr("creator");
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    address internal buyer = makeAddr("buyer");
    address internal indexToken = makeAddr("indexToken");
    address internal pTeamHolder = makeAddr("pTeamHolder");

    Pump12 internal pump;
    Token12 internal token;

    function setUp() public {
        vm.chainId(RH_CHAIN_ID);

        CurveTestUsdG usdgImplementation = new CurveTestUsdG();
        vm.etch(USDG, address(usdgImplementation).code);
        CurveTestPoolManager poolManagerImplementation = new CurveTestPoolManager();
        vm.etch(POOL_MANAGER, address(poolManagerImplementation).code);

        vm.prank(tagAI);
        pump = new Pump12(USDG, POOL_MANAGER);
        CurveTestIndexFundFactory indexFactory = new CurveTestIndexFundFactory(address(pump), tagAI, USDG, POOL_MANAGER);
        CurveTestPoolManager pTeamImplementation = new CurveTestPoolManager();
        CurveTestPoolManager deskImplementation = new CurveTestPoolManager();
        vm.prank(tagAI);
        pump.setPTeamImplementations(address(pTeamImplementation), address(deskImplementation), address(indexFactory));

        vm.prank(creator);
        token = Token12(pump.createToken(_params(bytes32("salt"), "P12", 500, 2_000, creatorFeeRecipient)));

        CurveTestUsdG(USDG).mint(buyer, 30_000e6);
        vm.prank(buyer);
        CurveTestUsdG(USDG).approve(address(token), type(uint256).max);
    }

    function test_createMintsFixedInitialSupplyToTokenInventory() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(token)), 1_000_000_000e18);
        assertEq(token.bondingCurveSupply(), 0);
        assertEq(token.curveReserveRaw(), 0);
        assertEq(token.manager(), address(pump));
        assertEq(token.creator(), creator);
        assertEq(token.tagAI(), tagAI);
        assertEq(token.indexToken(), indexToken);
        assertEq(token.pTeamHolder(), pTeamHolder);
    }

    function test_createRequiresIndexFactoryConfiguration() public {
        vm.prank(tagAI);
        Pump12 unconfiguredPump = new Pump12(USDG, POOL_MANAGER);

        vm.expectRevert(Pump12.PTeamImplementationsNotSet.selector);
        vm.prank(creator);
        unconfiguredPump.createToken(_params(bytes32("unconfigured"), "UNCONFIG", 500, 2_000, creatorFeeRecipient));
    }

    function test_createRejectsFeeAndAddressBounds() public {
        vm.startPrank(creator);

        vm.expectRevert(Pump12.InvalidTotalFeeBps.selector);
        pump.createToken(_params(bytes32("low"), "LOW", 99, 0, creatorFeeRecipient));

        vm.expectRevert(Pump12.InvalidTotalFeeBps.selector);
        pump.createToken(_params(bytes32("high"), "HIGH", 1_001, 0, creatorFeeRecipient));

        vm.expectRevert(Pump12.InvalidCreatorShareBps.selector);
        pump.createToken(_params(bytes32("share"), "SHARE", 100, 3_001, creatorFeeRecipient));

        vm.expectRevert(Pump12.InvalidAddress.selector);
        pump.createToken(_params(bytes32("recipient"), "RECIPIENT", 100, 0, address(0)));

        vm.stopPrank();
    }

    function test_createRejectsDuplicateSymbolAndSalt() public {
        vm.startPrank(creator);

        vm.expectRevert(Pump12.SymbolAlreadyCreated.selector);
        pump.createToken(_params(bytes32("different-salt"), "P12", 500, 2_000, creatorFeeRecipient));

        vm.expectRevert(Pump12.SaltAlreadyUsed.selector);
        pump.createToken(_params(bytes32("salt"), "DIFFERENT", 500, 2_000, creatorFeeRecipient));

        vm.stopPrank();
    }

    function test_buyAccruesOnlyTagAIAndCreatorInnerFees() public {
        uint256 maxInput = 1_000e6;
        (uint256 tokenOut, uint256 grossUsed, uint256 curveRaw, uint256 tagAIFee, uint256 creatorFee) =
            token.quoteBuy(maxInput);

        uint256 buyerBefore = CurveTestUsdG(USDG).balanceOf(buyer);
        vm.prank(buyer);
        (uint256 actualTokenOut, uint256 actualGrossUsed) = token.buy(maxInput, tokenOut);

        assertEq(actualTokenOut, tokenOut);
        assertEq(actualGrossUsed, grossUsed);
        assertEq(CurveTestUsdG(USDG).balanceOf(buyer), buyerBefore - grossUsed);
        assertEq(token.balanceOf(buyer), tokenOut);
        assertEq(token.curveReserveRaw(), curveRaw);
        assertEq(token.claimableTagAI(), tagAIFee);
        assertEq(token.claimableCreator(), creatorFee);
        assertEq(grossUsed, curveRaw + tagAIFee + creatorFee);
        assertEq(CurveTestUsdG(USDG).balanceOf(address(token)), grossUsed);
    }

    function test_fillToCapUsesExactlyFifteenThousandReserveAndRefundsRest() public {
        uint256 maxInput = 20_000e6;
        (uint256 tokenOut, uint256 grossUsed, uint256 curveRaw, uint256 tagAIFee, uint256 creatorFee) =
            token.quoteBuy(maxInput);
        assertEq(tokenOut, 750_000_000e18);
        assertEq(curveRaw, 15_000e6);

        uint256 buyerBefore = CurveTestUsdG(USDG).balanceOf(buyer);
        vm.prank(buyer);
        (uint256 actualTokenOut, uint256 actualGrossUsed) = token.buy(maxInput, tokenOut);

        assertEq(actualTokenOut, 750_000_000e18);
        assertEq(actualGrossUsed, grossUsed);
        assertEq(CurveTestUsdG(USDG).balanceOf(buyer), buyerBefore - grossUsed);
        assertEq(token.curveReserveRaw(), 15_000e6);
        assertEq(token.bondingCurveSupply(), 750_000_000e18);
        assertEq(token.balanceOf(address(token)), 250_000_000e18);
        assertEq(grossUsed, curveRaw + tagAIFee + creatorFee);
    }

    function test_splitBuysStillEndAtExactlyFifteenThousandReserve() public {
        vm.prank(buyer);
        token.buy(1_000e6, 0);

        vm.prank(buyer);
        token.buy(20_000e6, 0);

        assertEq(token.bondingCurveSupply(), 750_000_000e18);
        assertEq(token.curveReserveRaw(), 15_000e6);
    }

    function test_buyThenSellRestoresCurvePrincipal() public {
        (uint256 tokenOut,,,,) = token.quoteBuy(1_000e6);
        vm.prank(buyer);
        token.buy(1_000e6, tokenOut);

        uint256 reserveBeforeSell = token.curveReserveRaw();
        uint256 tagAIBeforeSell = token.claimableTagAI();
        uint256 creatorBeforeSell = token.claimableCreator();
        (uint256 grossRefund, uint256 netRefund, uint256 tagAIFee, uint256 creatorFee) = token.quoteSell(tokenOut);
        uint256 buyerBefore = CurveTestUsdG(USDG).balanceOf(buyer);

        vm.prank(buyer);
        uint256 actualRefund = token.sell(tokenOut, netRefund);

        assertEq(actualRefund, netRefund);
        assertEq(CurveTestUsdG(USDG).balanceOf(buyer), buyerBefore + netRefund);
        assertEq(token.bondingCurveSupply(), 0);
        assertEq(token.curveReserveRaw(), reserveBeforeSell - grossRefund);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.claimableTagAI(), tagAIBeforeSell + tagAIFee);
        assertEq(token.claimableCreator(), creatorBeforeSell + creatorFee);
    }

    function test_fullRoundTripReturnsAllCurveInventoryAndLeavesOnlyFees() public {
        vm.prank(buyer);
        token.buy(20_000e6, 750_000_000e18);

        (, uint256 netRefund,,) = token.quoteSell(750_000_000e18);
        vm.prank(buyer);
        token.sell(750_000_000e18, netRefund);

        assertEq(token.bondingCurveSupply(), 0);
        assertEq(token.curveReserveRaw(), 0);
        assertEq(token.balanceOf(address(token)), 1_000_000_000e18);
        assertEq(CurveTestUsdG(USDG).balanceOf(address(token)), token.claimableTagAI() + token.claimableCreator());
    }

    function test_buyAndSellEnforceMinimumOutputs() public {
        (uint256 tokenOut,,,,) = token.quoteBuy(100e6);

        vm.prank(buyer);
        vm.expectRevert(Token12.SlippageExceeded.selector);
        token.buy(100e6, tokenOut + 1);

        vm.prank(buyer);
        token.buy(100e6, tokenOut);

        (, uint256 netRefund,,) = token.quoteSell(tokenOut);
        vm.prank(buyer);
        vm.expectRevert(Token12.SlippageExceeded.selector);
        token.sell(tokenOut, netRefund + 1);
    }

    function test_maliciousCreatorRecipientCannotBlockCurveTrade() public {
        RejectUsdGReceiver rejectRecipient = new RejectUsdGReceiver();
        vm.prank(creator);
        Token12 maliciousRecipientToken =
            Token12(pump.createToken(_params(bytes32("reject"), "REJECT", 1_000, 3_000, address(rejectRecipient))));

        vm.prank(buyer);
        CurveTestUsdG(USDG).approve(address(maliciousRecipientToken), type(uint256).max);
        (uint256 tokenOut,,,,) = maliciousRecipientToken.quoteBuy(100e6);

        vm.prank(buyer);
        maliciousRecipientToken.buy(100e6, tokenOut);

        assertGt(maliciousRecipientToken.claimableCreator(), 0);
    }

    function test_feeClaimsDoNotTouchCurveReserve() public {
        (uint256 tokenOut,,,,) = token.quoteBuy(1_000e6);
        vm.prank(buyer);
        token.buy(1_000e6, tokenOut);

        uint256 reserveBefore = token.curveReserveRaw();
        uint256 tagAIClaim = token.claimableTagAI();
        uint256 creatorClaim = token.claimableCreator();

        token.claimTagAIFees();
        token.claimCreatorFees();

        assertEq(CurveTestUsdG(USDG).balanceOf(tagAI), tagAIClaim);
        assertEq(CurveTestUsdG(USDG).balanceOf(creatorFeeRecipient), creatorClaim);
        assertEq(token.curveReserveRaw(), reserveBefore);
        assertEq(token.claimableTagAI(), 0);
        assertEq(token.claimableCreator(), 0);
    }

    function _params(
        bytes32 salt,
        string memory symbol,
        uint16 totalFeeBps,
        uint16 creatorShareBps,
        address feeRecipient
    ) internal view returns (Pump12.CreateParams memory p) {
        p = Pump12.CreateParams({
            name: string.concat("Pump12 ", symbol),
            symbol: symbol,
            salt: salt,
            totalFeeBps: totalFeeBps,
            creatorShareBps: creatorShareBps,
            creatorFeeRecipient: feeRecipient,
            indexToken: indexToken,
            pTeamHolder: pTeamHolder
        });
    }
}
