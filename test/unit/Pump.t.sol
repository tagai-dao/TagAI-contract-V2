// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {Community} from "../../src/nutbox/Community.sol";
import {NutboxDeployConfigLib} from "../../src/pump/NutboxDeployConfig.sol";
import {V4PumpTestBase} from "../helpers/V4PumpTestBase.sol";

/**
 * @title PumpTest
 * @notice Unit tests for Pump — admin functions, createToken happy/revert paths (Uniswap v4 stack).
 */
contract PumpTest is V4PumpTestBase {
    // ─── Admin Functions ───

    function test_adminSetCalculator_onlyOwner() public onlyReady {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminSetCalculator(makeAddr("newCalc"));
    }

    function test_adminSetCalculator_updatesAddress() public onlyReady {
        address newCalc = makeAddr("newCalc");
        pump.adminSetCalculator(newCalc);
        assertEq(pump.getCalculator(), newCalc);
    }

    function test_adminSetHookAddress_onlyOwner() public onlyReady {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminSetHookAddress(makeAddr("newHook"));
    }

    function test_adminSetHookAddress_updatesAddress() public onlyReady {
        address newHook = makeAddr("newHook");
        pump.adminSetHookAddress(newHook);
        assertEq(pump.getHookAddress(), newHook);
    }

    function test_getCalculator_returnsConfiguredAddress() public onlyReady {
        assertEq(pump.getCalculator(), address(calculator));
    }

    function test_getHookAddress_returnsConfiguredAddress() public onlyReady {
        assertEq(pump.getHookAddress(), address(hook));
    }

    function test_getIPShare_returnsConfiguredAddress() public onlyReady {
        assertEq(pump.getIPShare(), address(ipshare));
    }

    function test_getFeeRatio_returnsDefaultValues() public onlyReady {
        uint256[2] memory ratio = pump.getFeeRatio();
        assertEq(ratio[0], 30);
        assertEq(ratio[1], 30);
    }

    function test_adminChangeFeeRatio_onlyOwner() public onlyReady {
        address rando = makeAddr("rando");
        uint256[2] memory newRatio = [uint256(50), uint256(50)];
        vm.prank(rando);
        vm.expectRevert();
        pump.adminChangeFeeRatio(newRatio);
    }

    function test_adminChangeFeeRatio_updatesValues() public onlyReady {
        uint256[2] memory newRatio = [uint256(50), uint256(50)];
        pump.adminChangeFeeRatio(newRatio);
        uint256[2] memory ratio = pump.getFeeRatio();
        assertEq(ratio[0], 50);
        assertEq(ratio[1], 50);
    }

    function test_adminChangeFeeRatio_revertsTooMuchFee() public onlyReady {
        uint256[2] memory tooMuch = [uint256(1001), uint256(50)];
        vm.expectRevert();
        pump.adminChangeFeeRatio(tooMuch);
    }

    function test_adminChangeCreateFee_onlyOwner() public onlyReady {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        pump.adminChangeCreateFee(0.01 ether);
    }

    function test_adminChangeCreateFee_revertsTooMuchFee() public onlyReady {
        vm.expectRevert();
        pump.adminChangeCreateFee(2 ether);
    }

    // ─── createToken ───

    function test_createToken_succeedsHappyPath() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("TEST", bytes32(uint256(1)));
        assertTrue(pump.createdTokens(tokenAddr));
        assertTrue(tokenAddr != address(0));
    }

    // ─── P1T3: devFund 交接给 creator ───

    function test_createToken_setsCommunityDevFundToCreator() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        address tokenAddr = pump.createToken{value: 0.005 ether}("DEVFUND", bytes32(uint256(42)));
        address community = Token(payable(tokenAddr)).nutboxCommunity();
        assertEq(Community(community).devFund(), creator);
        assertEq(Community(community).owner(), creator);
    }

    function test_createToken_revertsIfTickAlreadyExists() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        pump.createToken{value: 0.005 ether}("DUPE", bytes32(uint256(1)));
        vm.prank(creator, creator);
        vm.expectRevert();
        pump.createToken{value: 0.005 ether}("DUPE", bytes32(uint256(2)));
    }

    function test_createToken_revertsIfInsufficientFee() public onlyReady {
        _ensureCreatorIPShare();
        vm.prank(creator, creator);
        vm.expectRevert();
        pump.createToken{value: 0.001 ether}("LOWFEE", bytes32(uint256(1)));
    }

    function test_createToken_revertsIfNotEOA() public onlyReady {
        ContractCaller caller = new ContractCaller(address(pump));
        vm.deal(address(caller), 1 ether);
        vm.expectRevert();
        caller.callCreateToken{value: 0.005 ether}("PROXY", bytes32(uint256(1)));
    }

    function test_createToken_revertsIfNutboxNotConfigured() public onlyReady {
        Pump freshPump = new Pump(address(ipshare), feeRecipient, NutboxDeployConfigLib.empty());
        freshPump.adminSetCalculator(address(0));

        vm.startPrank(creator, creator);
        if (!ipshare.ipshareCreated(creator)) {
            ipshare.createShare{value: ipshare.createFee()}(creator);
        }
        vm.expectRevert();
        freshPump.createToken{value: 0.005 ether}("FRESH", bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_pump_doesNotHaveTradeSigner() public onlyReady {
        bytes4 selector = bytes4(keccak256("getTradeSigner()"));
        (bool success,) = address(pump).call(abi.encodeWithSelector(selector));
        assertFalse(success);
    }

    function test_pump_doesNotHaveAdminSetTradeSigner() public onlyReady {
        bytes4 selector = bytes4(keccak256("adminSetTradeSigner(address)"));
        (bool success,) = address(pump).call(abi.encodeWithSelector(selector, address(0)));
        assertFalse(success);
    }

    // ─── Bonding curve (RH constants) ───

    function test_getPrice_positive() public onlyReady {
        assertGt(pump.getPrice(0, 100 ether), 0);
    }

    function test_getBuyAmountByValue_positive() public onlyReady {
        assertGt(pump.getBuyAmountByValue(0, 1 ether), 0);
    }
}

contract ContractCaller {
    Pump public pump;

    constructor(address _pump) {
        pump = Pump(payable(_pump));
    }

    function callCreateToken(string calldata tick, bytes32 salt) external payable returns (address) {
        return pump.createToken{value: msg.value}(tick, salt);
    }

    receive() external payable {}
}

/**
 * @title PumpWithFeesTest
 * @notice Pump.createToken when nutboxFees > 0 — excess ETH must not refund nutbox portion.
 */
contract PumpWithFeesTest is V4PumpTestBase {
    uint256 constant CREATE_COMMUNITY_FEE = 0.01 ether;
    uint256 constant SETTINGS_FEE = 0.005 ether;
    uint256 constant NUTBOX_FEES = CREATE_COMMUNITY_FEE + SETTINGS_FEE;
    uint256 constant PUMP_CREATE_FEE = 0.005 ether;

    function _nutboxCreateCommunityFee() internal pure override returns (uint256) {
        return CREATE_COMMUNITY_FEE;
    }

    function _nutboxCommunitySettingsFee() internal pure override returns (uint256) {
        return SETTINGS_FEE;
    }

    function _zeroIpShareCreateFee() internal pure override returns (bool) {
        return true;
    }

    function test_createToken_withNutboxFees_doesNotRefundFees() public onlyReady {
        vm.startPrank(creator, creator);
        ipshare.createShare(creator);

        uint256 buyAmount = 0.1 ether;
        uint256 totalSent = PUMP_CREATE_FEE + NUTBOX_FEES + buyAmount;
        uint256 balanceBefore = creator.balance;

        address tokenAddr = pump.createToken{value: totalSent}("TESTFEE", bytes32(uint256(1)));
        uint256 actualSpent = balanceBefore - creator.balance;

        assertTrue(pump.createdTokens(tokenAddr));
        assertGe(actualSpent, PUMP_CREATE_FEE + NUTBOX_FEES);
        assertLe(totalSent - actualSpent, buyAmount);
        vm.stopPrank();
    }

    function test_createToken_withNutboxFees_exactBalanceChange() public onlyReady {
        vm.startPrank(creator, creator);
        ipshare.createShare(creator);

        uint256 buyAmount = 0.1 ether;
        uint256 totalSent = PUMP_CREATE_FEE + NUTBOX_FEES + buyAmount;
        uint256 balanceBefore = creator.balance;

        pump.createToken{value: totalSent}("TESTFEE2", bytes32(uint256(2)));
        uint256 actualSpent = balanceBefore - creator.balance;

        assertGt(actualSpent, PUMP_CREATE_FEE);
        assertGe(actualSpent, PUMP_CREATE_FEE + NUTBOX_FEES);
        vm.stopPrank();
    }

    function test_createToken_withNutboxFees_noRefundWhenExactAmount() public onlyReady {
        vm.startPrank(creator, creator);
        ipshare.createShare(creator);

        uint256 totalSent = PUMP_CREATE_FEE + NUTBOX_FEES;
        uint256 balanceBefore = creator.balance;

        pump.createToken{value: totalSent}("TESTFEE3", bytes32(uint256(3)));
        assertEq(balanceBefore - creator.balance, totalSent);
        vm.stopPrank();
    }
}
