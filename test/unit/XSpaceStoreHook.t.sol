// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/pump/IPShare.sol";
import "../../src/hook/XSpaceStoreHook.sol";
import "../mocks/MockCLPoolManager.sol";
import "../mocks/MockVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

contract XSpaceStoreHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MockCLPoolManager public mockPoolManager;
    MockVault public mockVault;
    IPShare public ipshare;
    XSpaceStoreHook public hook;

    address public feeRecipient;
    address public token;
    address public ipshareSubject;

    uint256 constant DIVISOR = 10000;
    uint256 constant PLATFORM_FEE_BPS = 30;
    uint256 constant IPSHARE_FEE_BPS = 30;

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        token = makeAddr("xspaceToken");
        ipshareSubject = makeAddr("ipshareSubject");

        mockPoolManager = new MockCLPoolManager();
        mockVault = new MockVault();
        ipshare = new IPShare(feeRecipient);

        vm.deal(address(mockVault), 1000 ether);
        vm.deal(address(this), 10 ether);

        hook = new XSpaceStoreHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            token,
            feeRecipient,
            address(ipshare)
        );

        uint256 createPrice = ipshare.getPrice(10 ether, 0);
        ipshare.createShare{value: createPrice}(ipshareSubject);

        _initializePool();
    }

    function _buildPoolKey() internal view returns (PoolKey memory poolKey) {
        uint16 hookBitmap = hook.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hook.TICK_SPACING());

        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(token),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(mockPoolManager)),
            fee: hook.RECOMMENDED_LP_FEE_PIPS(),
            parameters: parameters
        });
    }

    function _initializePool() internal {
        PoolKey memory poolKey = _buildPoolKey();
        mockPoolManager.initialize(poolKey, uint160(79228162514264337593543950336)); // 1:1-ish
    }

    function test_beforeInitialize_revertsOnWrongToken() public {
        PoolKey memory badKey = _buildPoolKey();
        badKey.currency1 = Currency.wrap(makeAddr("wrongToken"));

        vm.expectRevert(XSpaceStoreHook.InvalidPoolPair.selector);
        mockPoolManager.initialize(badKey, uint160(79228162514264337593543950336));
    }

    function test_beforeInitialize_revertsOnWrongTickSpacing() public {
        PoolKey memory badKey = _buildPoolKey();
        badKey.parameters = CLPoolParametersHelper.setTickSpacing(badKey.parameters, 60);

        vm.expectRevert(XSpaceStoreHook.InvalidTickSpacing.selector);
        mockPoolManager.initialize(badKey, uint160(79228162514264337593543950336));
    }

    function test_beforeSwap_collectsFeesToPlatformWhenNoValidIPShare() public {
        uint256 swapAmount = 10 ether;
        uint256 expectedPlatform = (swapAmount * PLATFORM_FEE_BPS) / DIVISOR;
        uint256 expectedIpShare = (swapAmount * IPSHARE_FEE_BPS) / DIVISOR;

        uint256 feeRecipientBefore = feeRecipient.balance;

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(mockPoolManager));
        hook.beforeSwap(address(0), poolKey, params, bytes(""));

        assertEq(feeRecipient.balance - feeRecipientBefore, expectedPlatform + expectedIpShare);
        assertEq(mockVault.takeCount(), 1);
        assertEq(expectedPlatform, 0.03 ether);
        assertEq(expectedIpShare, 0.03 ether);
    }

    function test_beforeSwap_routesIpShareFeeWhenValidSubject() public {
        uint256 swapAmount = 10 ether;
        uint256 expectedPlatform = (swapAmount * PLATFORM_FEE_BPS) / DIVISOR;
        uint256 expectedIpShare = (swapAmount * IPSHARE_FEE_BPS) / DIVISOR;

        uint256 feeRecipientBefore = feeRecipient.balance;
        uint256 subjectSupplyBefore = ipshare.ipshareSupply(ipshareSubject);

        PoolKey memory poolKey = _buildPoolKey();
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(ipshareSubject);

        vm.prank(address(mockPoolManager));
        hook.beforeSwap(address(0), poolKey, params, hookData);

        assertEq(feeRecipient.balance - feeRecipientBefore, expectedPlatform);
        assertGt(ipshare.ipshareSupply(ipshareSubject), subjectSupplyBefore);
        assertEq(expectedPlatform, 0.03 ether);
        assertEq(expectedIpShare, 0.03 ether);
    }

    function test_getHooksRegistrationBitmap_correctBits() public view {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        uint16 expected = uint16((1 << 0) | (1 << 6) | (1 << 7) | (1 << 10) | (1 << 11));
        assertEq(bitmap, expected);
    }

    function test_constants() public view {
        assertEq(hook.TICK_SPACING(), 10);
        assertEq(hook.RECOMMENDED_LP_FEE_PIPS(), 4000);
        assertEq(hook.token(), token);
        assertEq(hook.feeReceiver(), feeRecipient);
        assertEq(hook.ipshare(), address(ipshare));
    }
}
