// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IndexFundV1} from "../../../src/pump12/fund/IndexFundV1.sol";
import {IIndexFund} from "../../../src/pump12/fund/IIndexFund.sol";
import {
    Pump12TestBasketRegistry,
    Pump12TestWETH,
    Pump12TestBasket,
    Pump12TestBasketHookConfig,
    Pump12TestRouteRegistry
} from "./Pump12IndexTestHelpers.sol";

contract IndexFundTestPendingHook {
    IERC20 public immutable usdg;
    mapping(PoolId => uint256) public pending;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function addPendingUSDG(PoolId id, uint256 amount) external returns (uint256) {
        require(usdg.transferFrom(msg.sender, address(this), amount));
        pending[id] += amount;
        return amount;
    }
}

contract IndexFundTestBasketRouter {
    IPoolManager public immutable poolManager;
    Pump12TestWETH public immutable usdgToken;
    address public immutable basketHook;

    constructor(IPoolManager manager_, Pump12TestWETH usdg_, address basketHook_) {
        poolManager = manager_;
        usdgToken = usdg_;
        basketHook = basketHook_;
    }

    function usdg() external view returns (address) {
        return address(usdgToken);
    }

    function buyExactUsdg(address basket, uint256 amount, uint256 minimum, bytes calldata, address recipient)
        external
        returns (uint256 output)
    {
        require(usdgToken.transferFrom(msg.sender, address(this), amount));
        output = amount * 1e12;
        require(output >= minimum, "min buy");
        Pump12TestBasket(basket).mint(recipient, output);
    }

    function sellExactBasket(address basket, uint256 amount, uint256 minimum, bytes calldata, address recipient)
        external
        returns (uint256 output)
    {
        require(IERC20(basket).transferFrom(msg.sender, address(this), amount));
        output = amount / 1e12;
        require(output >= minimum, "min sell");
        usdgToken.mint(recipient, output);
    }
}

contract IndexFundV1Test is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q96 = 1 << 96;
    PoolId internal constant PUMP_POOL_ID = PoolId.wrap(bytes32(uint256(777)));
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    address internal attacker = makeAddr("attacker");

    IPoolManager internal manager;
    Pump12TestWETH internal usdg;
    Pump12TestWETH internal weth;
    Pump12TestBasket internal basket;
    Pump12TestBasketRegistry internal registry;
    IndexFundTestPendingHook internal pendingHook;
    IndexFundV1 internal fund;
    PoolKey internal hubKey;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        usdg = new Pump12TestWETH();
        weth = new Pump12TestWETH();
        basket = new Pump12TestBasket(address(weth));
        registry = new Pump12TestBasketRegistry();
        registry.setBasket(address(basket), true);
        pendingHook = new IndexFundTestPendingHook(IERC20(address(usdg)));

        Pump12TestRouteRegistry routes = new Pump12TestRouteRegistry(manager, address(usdg));
        Pump12TestBasketHookConfig basketHookConfig =
            new Pump12TestBasketHookConfig(manager, address(registry), address(routes), address(usdg), address(weth));
        IndexFundTestBasketRouter router = new IndexFundTestBasketRouter(manager, usdg, address(basketHookConfig));
        hubKey = routes.hubRoute();

        _initializeHubPool();
        fund = IndexFundV1(payable(Clones.clone(address(new IndexFundV1()))));
        fund.initialize(
            IIndexFund.InitParams({
                usdg: address(usdg),
                indexToken: address(basket),
                creator: address(this),
                creatorFeeRecipient: creatorFeeRecipient,
                desk: address(this),
                burnNet: address(this),
                hook: address(pendingHook),
                poolId: PUMP_POOL_ID,
                basketRegistry: address(registry),
                basketRouter: address(router),
                basketRouteRegistry: address(routes),
                poolManager: address(manager),
                weth: address(weth)
            })
        );
    }

    function test_deskProceedsBuyOnlyBoundIndexThroughOfficialRouter() public {
        usdg.mint(address(fund), 100e6);
        uint256 output = fund.onDeskProceeds(100e6);
        assertEq(output, 100e18);
        assertEq(basket.balanceOf(address(fund)), 100e18);

        vm.expectRevert(IndexFundV1.OnlyDesk.selector);
        vm.prank(attacker);
        fund.onDeskProceeds(1);
    }

    function test_creatorSellSplitsOnePercentAndNinetyNinePercentNonEligiblePending() public {
        usdg.mint(address(fund), 100e6);
        fund.onDeskProceeds(100e6);
        uint256 sold = basket.balanceOf(address(fund)) / 2;
        uint256 output = fund.sellIndex(sold, 1);

        assertEq(output, 50e6);
        assertEq(usdg.balanceOf(creatorFeeRecipient), 500_000);
        assertEq(pendingHook.pending(PUMP_POOL_ID), 49_500_000);
        assertEq(usdg.balanceOf(address(fund)), 0);
    }

    function test_onlyCreatorCanSellOrClaimAndMinOutCannotBeZero() public {
        vm.expectRevert(IndexFundV1.OnlyCreator.selector);
        vm.prank(attacker);
        fund.sellIndex(1, 1);

        vm.expectRevert(IndexFundV1.OnlyCreator.selector);
        vm.prank(attacker);
        fund.claimHolderFees(1);

        vm.expectRevert(IndexFundV1.InvalidAmount.selector);
        fund.sellIndex(1, 0);
        vm.expectRevert(IndexFundV1.InvalidAmount.selector);
        fund.claimHolderFees(0);
    }

    function test_holderFeesAreUnwrappedSwappedAndSplitWithoutWethResidue() public {
        uint256 fee = 0.01 ether;
        uint256 donatedDust = 0.001 ether;
        vm.deal(address(weth), fee + donatedDust);
        weth.mint(address(fund), donatedDust);
        weth.mint(address(this), fee);
        weth.approve(address(basket), fee);
        basket.injectHolderFees(address(fund), fee);

        (uint256 realizedWeth, uint256 output) = fund.claimHolderFees(1);
        uint256 creatorAmount = usdg.balanceOf(creatorFeeRecipient);
        uint256 pendingAmount = pendingHook.pending(PUMP_POOL_ID);
        assertEq(realizedWeth, fee + donatedDust);
        assertGt(output, 0);
        assertEq(creatorAmount + pendingAmount, output);
        assertEq(creatorAmount, output / 100);
        assertEq(IERC20(address(weth)).balanceOf(address(fund)), 0);
        assertEq(address(fund).balance, 0);
        assertEq(usdg.balanceOf(address(fund)), 0);
    }

    function _initializeHubPool() private {
        manager.initialize(hubKey, uint160(Q96 / 1e6));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        usdg.mint(address(this), 10e6);
        usdg.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), 2 ether);
        liquidityRouter.modifyLiquidity{value: 2 ether}(
            hubKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: int256(1e12), salt: bytes32(0)
            }),
            bytes("")
        );
    }

    receive() external payable {}
}
