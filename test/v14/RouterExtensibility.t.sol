// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {NutboxRouter, INutboxRouter} from "../../src/router/NutboxRouter.sol";
import {
    RouterTestToken,
    RouterV3FactoryMock,
    RouterV3PoolMock,
    RouterPancakeV3RouterMock,
    RouterUniswapV4ManagerMock,
    RouterV2FactoryMock,
    RouterV2RouterMock
} from "../unit/NutboxRouter.t.sol";

contract OperatorPump {
    mapping(address => bool) public createdTokens;

    function register(address t) external {
        createdTokens[t] = true;
    }
}

contract RouterExtensibilityTest is Test {
    NutboxRouter router;
    RouterTestToken weth;
    RouterTestToken stock;
    RouterV3FactoryMock oldFactory;
    RouterPancakeV3RouterMock oldExecutor;

    function setUp() public {
        weth = new RouterTestToken("WETH", "WETH");
        stock = new RouterTestToken("Stock", "STK");
        oldFactory = new RouterV3FactoryMock();
        oldExecutor = new RouterPancakeV3RouterMock(address(oldFactory), address(weth));
        address[] memory fs = new address[](1);
        fs[0] = address(oldFactory);
        router = new NutboxRouter(
            address(weth),
            address(oldExecutor),
            new address[](0),
            new address[](0),
            fs,
            new address[](0),
            new address[](0),
            ""
        );
    }

    function _pool(RouterV3FactoryMock f) internal returns (address p) {
        (address a, address b) =
            address(weth) < address(stock) ? (address(weth), address(stock)) : (address(stock), address(weth));
        RouterV3PoolMock pool = new RouterV3PoolMock(address(f), a, b, 3000);
        pool.setState(uint160(1 << 96), 1 ether);
        f.setPool(a, b, 3000, address(pool));
        return address(pool);
    }

    function test_registerSecondV3FactoryExecutesNewRouterAndDisableBlocks() public {
        RouterV3FactoryMock f = new RouterV3FactoryMock();
        RouterPancakeV3RouterMock e = new RouterPancakeV3RouterMock(address(f), address(weth));
        router.setV3Router(address(f), address(e), true);
        address p = _pool(f);
        bytes32 id = router.addPricePool(INutboxRouter.SourceType.V3_POOL, abi.encode(address(f), p));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        router.addRoute(address(weth), address(stock), ids);
        weth.mint(address(this), 1 ether);
        weth.approve(address(router), 1 ether);
        assertEq(
            router.swapExactInput(address(weth), address(stock), 1 ether, 1, address(this), block.timestamp), 2 ether
        );
        assertEq(e.lastPath(), abi.encodePacked(address(weth), uint24(3000), address(stock)));
        assertEq(oldExecutor.lastPath().length, 0);
        assertEq(weth.allowance(address(router), address(e)), 0);
        router.setV3Router(address(f), address(0), false);
        vm.expectRevert();
        router.quote(address(weth), address(stock), 1 ether);
    }

    function test_runtimeManagerRegistrationAndOwnerOnly() public {
        RouterUniswapV4ManagerMock m = new RouterUniswapV4ManagerMock();
        assertFalse(router.allowedUniswapV4Manager(address(m)));
        router.setUniswapV4Manager(address(m), true);
        assertTrue(router.allowedUniswapV4Manager(address(m)));
        router.setUniswapV4Manager(address(m), false);
        assertFalse(router.allowedUniswapV4Manager(address(m)));
        vm.prank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        router.setUniswapV4Manager(address(m), true);
        vm.expectRevert(NutboxRouter.InvalidAddress.selector);
        router.setUniswapV4Manager(address(0x123), true);
    }

    function test_runtimeV2RouterChecksFactoryAndWrappedNative() public {
        RouterV2FactoryMock f = new RouterV2FactoryMock();
        RouterV2RouterMock e = new RouterV2RouterMock(address(f), address(weth));
        router.setV2Router(address(f), address(e), true);
        assertEq(router.v2RouterForFactory(address(f)), address(e));
        vm.expectRevert(NutboxRouter.InvalidAddress.selector);
        router.setV2Router(address(oldFactory), address(e), true);
        router.setV2Router(address(f), address(0), false);
        assertFalse(router.allowedV2Factory(address(f)));
    }

    function test_operatorCanOnlyAddOwnTokenRoutesAndCannotReplace() public {
        address p = _pool(oldFactory);
        OperatorPump op = new OperatorPump();
        router.addOperator(address(op));
        bytes memory data = abi.encode(address(oldFactory), p);
        vm.prank(address(op));
        vm.expectRevert(NutboxRouter.OperatorScope.selector);
        router.addPricePool(INutboxRouter.SourceType.V3_POOL, data);
        op.register(address(stock));
        vm.prank(address(op));
        bytes32 id = router.addPricePool(INutboxRouter.SourceType.V3_POOL, data);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.prank(address(op));
        router.addRoute(address(stock), address(weth), ids);
        vm.prank(address(op));
        vm.expectRevert("Ownable: caller is not the owner");
        router.replacePricePool(INutboxRouter.SourceType.V3_POOL, data);
        vm.prank(address(op));
        vm.expectRevert("Ownable: caller is not the owner");
        router.replaceRoute(address(stock), address(weth), ids);
        router.removeOperator(address(op));
        assertFalse(router.operators(address(op)));
    }

    function test_operatorCannotConfigureDex() public {
        OperatorPump op = new OperatorPump();
        router.addOperator(address(op));
        vm.prank(address(op));
        vm.expectRevert("Ownable: caller is not the owner");
        router.setV3Router(address(oldFactory), address(oldExecutor), true);
    }
}
