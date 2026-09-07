// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PumpVersion13Test, Version13Asset, Version13BasketHook} from "../unit/PumpVersion13.t.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {NutboxRouter} from "../../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SqrtPriceMath} from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";

/// @dev Local constant-product venue, with real balances and the Pancake V2 25-bps invariant.
/// Not mainnet bytecode: tests isolate price manipulation from V4 and Basket deployment.
contract AuditV2Pair {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address a, address b) {
        factory = msg.sender;
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function sync() public {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 a0 = IERC20(token0).balanceOf(address(this)) - reserve0;
        uint256 a1 = IERC20(token1).balanceOf(address(this)) - reserve1;
        if (totalSupply == 0) {
            liquidity = Math.sqrt(a0 * a1) - 1000;
            totalSupply = 1000;
            balanceOf[address(0)] = 1000;
        } else {
            liquidity = Math.min(a0 * totalSupply / reserve0, a1 * totalSupply / reserve1);
        }
        require(liquidity > 0, "ZERO_LIQUIDITY");
        totalSupply += liquidity;
        balanceOf[to] += liquidity;
        sync();
    }

    function swap(uint256 a0Out, uint256 a1Out, address to, bytes calldata) external {
        require(a0Out + a1Out > 0 && a0Out < reserve0 && a1Out < reserve1, "BAD_OUTPUT");
        if (a0Out > 0) require(IERC20(token0).transfer(to, a0Out));
        if (a1Out > 0) require(IERC20(token1).transfer(to, a1Out));
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0In = b0 > reserve0 - a0Out ? b0 - (reserve0 - a0Out) : 0;
        uint256 a1In = b1 > reserve1 - a1Out ? b1 - (reserve1 - a1Out) : 0;
        require(
            (b0 * 10_000 - a0In * 25) * (b1 * 10_000 - a1In * 25) >= uint256(reserve0) * reserve1 * 100_000_000, "K"
        );
        sync();
    }
}

contract AuditV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        require(getPair[a][b] == address(0), "PAIR_EXISTS");
        pair = address(new AuditV2Pair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract AuditWrappedNative is Version13Asset {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok);
    }
}

contract AuditFeeOnTransferAsset is Version13Asset {
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        super._transfer(from, address(0xdead), fee);
        super._transfer(from, to, amount - fee);
    }
}

contract AuditPairTaxAsset is Version13Asset {
    address public taxedPair;

    function setTaxedPair(address pair) external {
        taxedPair = pair;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (to != taxedPair) {
            super._transfer(from, to, amount);
            return;
        }
        uint256 fee = amount / 100;
        super._transfer(from, address(0xdead), fee);
        super._transfer(from, to, amount - fee);
    }
}

contract AuditDexRouter {
    address public immutable factory;
    address public immutable WETH;

    constructor(address factory_, address wrapped) {
        factory = factory_;
        WETH = wrapped;
    }

    function WETH9() external view returns (address) {
        return WETH;
    }

    function swapExactTokensForTokens(
        uint256 input,
        uint256 minOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2 && deadline >= block.timestamp);
        AuditV2Pair pair = AuditV2Pair(AuditV2Factory(factory).getPair(path[0], path[1]));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool forward = path[0] == pair.token0();
        (uint256 rIn, uint256 rOut) = forward ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 output = input * 9975 * rOut / (rIn * 10_000 + input * 9975);
        require(output >= minOut);
        require(IERC20(path[0]).transferFrom(msg.sender, address(pair), input));
        pair.swap(forward ? 0 : output, forward ? output : 0, to, "");
        amounts = new uint256[](2);
        amounts[0] = input;
        amounts[1] = output;
    }
}

contract Version13SecurityTest is PumpVersion13Test {
    NutboxRouter internal liveRouter;
    AuditV2Factory internal dexFactory;
    AuditWrappedNative internal wrapped;
    AuditV2Pair internal marketB;

    function _one(address value) private pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = value;
    }

    function _configureRealRouter() internal {
        vm.deal(address(this), 10_000 ether);
        wrapped = new AuditWrappedNative();
        wrapped.deposit{value: 2000 ether}();
        dexFactory = new AuditV2Factory();
        AuditDexRouter dex = new AuditDexRouter(address(dexFactory), address(wrapped));
        // V4 state is a deterministic fixture. The Router and V2 executions are real code paths.
        vm.mockCall(address(manager), abi.encodeWithSignature("vault()"), abi.encode(address(vault)));
        liveRouter = new NutboxRouter(
            address(wrapped),
            address(dex),
            _one(address(dex)),
            _one(address(dexFactory)),
            _one(address(dexFactory)),
            new address[](0),
            _one(address(manager)),
            ""
        );
        liveRouter.addOperator(address(pump));
        _market(assetA, 200 ether, 20_000 ether);
        marketB = _market(assetB, 200 ether, 20_000 ether);
        Version13Asset settlement = new Version13Asset();
        _market(settlement, 200 ether, 20_000 ether);
        basket = new Version13BasketHook(address(settlement), address(dexFactory), address(liveRouter));
        pump.adminSetIndexInfrastructure(address(liveRouter), address(basket), address(dexFactory), address(settlement));
        uint256 creationFee = pump.createFee();
        vm.prank(creator, creator);
        token = Token(payable(pump.createToken{value: creationFee}("AUDIT", bytes32(uint256(101)), _config())));
    }

    function _market(Version13Asset asset, uint256 bnb, uint256 tokens) private returns (AuditV2Pair pair) {
        pair = AuditV2Pair(dexFactory.createPair(address(wrapped), address(asset)));
        wrapped.transfer(address(pair), bnb);
        asset.mint(address(pair), tokens);
        pair.mint(address(this));
        bytes32 id =
            liveRouter.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(dexFactory), address(pair)));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        liveRouter.addRoute(address(0), address(asset), ids);
    }

    function _prepareListing() internal {
        uint160 price = 225060284636549774439465527763777;
        uint128 liquidity = 52804626975085827442929;
        uint256 nativeSeed = SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtRatioAtTick(191940), liquidity, true);
        uint256 tokenSeed = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(-887220), price, liquidity, true);
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.modifyLiquidity.selector),
            abi.encode(toBalanceDelta(-int128(int256(nativeSeed)), -int128(int256(tokenSeed))), BalanceDelta.wrap(0))
        );
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(ICLPoolManager.getSlot0.selector),
            abi.encode(price, int24(0), uint24(0), uint24(0))
        );
        vm.mockCall(
            address(manager), abi.encodeWithSelector(bytes4(keccak256("getLiquidity(bytes32)"))), abi.encode(liquidity)
        );
        vm.warp(block.timestamp + 16);
    }

    function _finishListing() internal {
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory mins = _keeperMins(9_700);
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
    }

    function _keeperMins(uint256 bps) private view returns (uint256[] memory mins) {
        uint256 count = token.componentCount();
        mins = new uint256[](count);
        uint256 totalNativeBudget = token.componentListingNativeBudget();
        uint256 allocatedNative;
        for (uint256 i; i < count; ++i) {
            (address asset, uint16 weight,) = token.componentAt(i);
            uint256 nativeBudget =
                i + 1 == count ? totalNativeBudget - allocatedNative : totalNativeBudget * weight / 10_000;
            allocatedNative += nativeBudget;
            mins[i] = liveRouter.quote(address(0), asset, nativeBudget) * bps / 10_000;
        }
    }

    function testAudit_keeperMinimumRejectsFrontRunPriceManipulation() public {
        _configureRealRouter();
        _prepareListing();
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory keeperMins = _keeperMins(9_700);
        uint256 snapshot = vm.snapshotState();
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), keeperMins, block.timestamp);
        (,, address cleanPair) = token.componentAt(1);
        uint256 honestAssets = assetB.balanceOf(cleanPair);
        vm.revertToState(snapshot);

        address attacker = makeAddr("sandwichAttacker");
        vm.deal(attacker, 100 ether);
        vm.startPrank(attacker);
        liveRouter.swapExactInput{value: 100 ether}(
            address(0), address(assetB), 100 ether, 1, attacker, block.timestamp
        );
        vm.stopPrank();

        vm.prank(listingKeeper);
        vm.expectRevert(NutboxRouter.PriceUnavailable.selector);
        pump.finalizeTokenListing(address(token), keeperMins, block.timestamp);
        (,, address attackedPair) = token.componentAt(1);
        uint256 manipulatedAssets = assetB.balanceOf(attackedPair);
        assertTrue(token.listingPending());
        assertFalse(token.listed());
        assertEq(manipulatedAssets, 0);
        emit log_named_uint("honest component units", honestAssets);
    }

    function testAudit_routerHonorsIndependentMinimumAfterFrontRun() public {
        _configureRealRouter();
        uint256 input = 3 ether;
        uint256 independentMin = liveRouter.quote(address(0), address(assetB), input) * 9700 / 10_000;
        liveRouter.swapExactInput{value: 100 ether}(
            address(0), address(assetB), 100 ether, 1, address(this), block.timestamp
        );
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(NutboxRouter.PriceUnavailable.selector);
        liveRouter.swapExactInput{value: input}(
            address(0), address(assetB), input, independentMin, address(this), block.timestamp
        );
        assertEq(address(this).balance, balanceBefore);
    }

    function testAudit_feeOnTransferComponentCannotList() public {
        _configureRealRouter();
        AuditFeeOnTransferAsset taxed = new AuditFeeOnTransferAsset();
        _market(taxed, 200 ether, 20_000 ether);
        pump.adminSetConstituentApproval(address(taxed), true);
        IPump.IndexConfig memory c = _config();
        c.constituentAssets[0] = address(taxed);
        uint256 creationFee = pump.createFee();
        vm.prank(creator, creator);
        token = Token(payable(pump.createToken{value: creationFee}("FOT", bytes32(uint256(103)), c)));

        _prepareListing();
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory mins = _keeperMins(9_700);
        vm.prank(listingKeeper);
        vm.expectRevert(NutboxRouter.InvalidSwapOutput.selector);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listingPending());
        assertFalse(token.listed());
    }

    function testAudit_pairSpecificTransferTaxCannotSilentlyUnderseedComponentPool() public {
        _configureRealRouter();
        AuditPairTaxAsset taxed = new AuditPairTaxAsset();
        _market(taxed, 200 ether, 20_000 ether);
        pump.adminSetConstituentApproval(address(taxed), true);
        IPump.IndexConfig memory c = _config();
        c.constituentAssets[0] = address(taxed);
        uint256 creationFee = pump.createFee();
        vm.prank(creator, creator);
        token = Token(payable(pump.createToken{value: creationFee}("PAIRTAX", bytes32(uint256(104)), c)));
        (,, address componentPair) = token.componentAt(0);
        taxed.setTaxedPair(componentPair);

        _prepareListing();
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory mins = _keeperMins(9_700);
        vm.prank(listingKeeper);
        vm.expectRevert(Token.ComponentSwapFailed.selector);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listingPending());
        assertFalse(token.listed());
    }

    function testAudit_v3HookIsRejectedByPumpConfiguration() public {
        vm.mockCall(address(basket), abi.encodeWithSignature("tokenVersion()"), abi.encode(uint32(3)));
        address settlement = basket.settlementToken();
        vm.expectRevert(IPump.IndexInfrastructureNotConfigured.selector);
        pump.adminSetIndexInfrastructure(address(router), address(basket), address(factory), settlement);
    }

    function testAudit_existingComponentPricePoolIsLeftUntouchedDuringListing() public {
        _configureRealRouter();
        _prepareListing();
        (,, address pair) = token.componentAt(0);
        // Model an owner/operator pre-registering a price source. Mock reserves only for registration;
        // do not modify pair storage or give an unprivileged account Router permissions.
        vm.mockCall(pair, abi.encodeWithSignature("getReserves()"), abi.encode(uint112(1), uint112(1), uint32(0)));
        liveRouter.addPricePool(INutboxRouter.SourceType.V2_PAIR, abi.encode(address(dexFactory), pair));
        vm.clearMockedCalls();
        _prepareListing();
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory mins = _keeperMins(9_700);
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertFalse(token.listingPending());
        assertTrue(token.listed());
        assertEq(token.bondingCurveSupply(), 650_000_000 ether);
        assertGt(token.balanceOf(address(hook)), 0);
        assertTrue(token.indexToken() != address(0));
        assertGt(address(vault).balance, 0);
        assertTrue(liveRouter.hasRoute(address(token), address(0)));
        assertEq(liveRouter.routePoolCount(address(token), address(0)), 1);
        assertEq(
            liveRouter.routePoolAt(address(token), address(0), 0), liveRouter.pricePoolId(address(token), address(0))
        );
        assertTrue(liveRouter.hasRoute(address(token), basket.settlementToken()));
        assertEq(liveRouter.routePoolCount(address(token), basket.settlementToken()), 2);
    }

    function testAudit_listingOnlyRegistersTokenNativePricePool() public {
        _configureRealRouter();
        _prepareListing();
        _finishListing();
        assertTrue(token.listed());
        assertTrue(token.indexToken() != address(0));
        assertTrue(liveRouter.hasPricePool(liveRouter.pricePoolId(address(token), address(0))));
        liveRouter.validateRoute(address(token), address(0));
        liveRouter.validateRoute(address(token), basket.settlementToken());
        for (uint256 i; i < token.componentCount(); ++i) {
            (address asset,, address pair) = token.componentAt(i);
            assertFalse(liveRouter.hasPricePool(liveRouter.pricePoolId(address(token), asset)));
            assertGt(token.balanceOf(pair), 0);
            assertGt(Version13Asset(asset).balanceOf(pair), 0);
        }
    }

    function testAudit_missingOperatorRollsBackListingAndCanBeRecovered() public {
        _configureRealRouter();
        _prepareListing();
        vm.prank(creator, creator);
        token.buyToken{value: 100 ether}(0, creator, 0);
        uint256[] memory mins = _keeperMins(9_700);
        liveRouter.removeOperator(address(pump));
        vm.prank(listingKeeper);
        vm.expectRevert(NutboxRouter.NotOwnerOrOperator.selector);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listingPending());
        assertFalse(token.listed());
        assertEq(token.bondingCurveSupply(), 650_000_000 ether);
        assertEq(address(vault).balance, 0);
        liveRouter.addOperator(address(pump));
        vm.prank(listingKeeper);
        pump.finalizeTokenListing(address(token), mins, block.timestamp);
        assertTrue(token.listed());
    }

    function testAudit_componentDonationAndSyncCannotPreseedTokenSide() public {
        _configureRealRouter();
        (,, address pair) = token.componentAt(0);
        assetA.mint(pair, 1 ether);
        AuditV2Pair(pair).sync();
        assertEq(token.balanceOf(pair), 0);
        assertEq(AuditV2Pair(pair).totalSupply(), 0);
        _prepareListing();
        _finishListing();
        assertTrue(token.listed(), "one-sided sync does not permanently block first mint");
        assertGt(AuditV2Pair(pair).balanceOf(token.LP_BURN_ADDRESS()), 0);
    }

    function testAudit_componentTransferFromBlockedBeforeListing() public {
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        token.buyToken{value: 1 ether}(0, creator, 0);
        (,, address pair) = token.componentAt(0);
        vm.prank(creator);
        token.approve(address(this), type(uint256).max);
        vm.expectRevert(IToken.TokenNotListed.selector);
        token.transferFrom(creator, pair, 1 ether);
    }

    function testAudit_componentPoolTaxPreservesV2InvariantUsingActualInputAndOutput() public {
        _configureRealRouter();
        _prepareListing();
        _finishListing();

        (address assetAddress,, address pairAddress) = token.componentAt(0);
        Version13Asset component = Version13Asset(assetAddress);
        AuditV2Pair pair = AuditV2Pair(pairAddress);
        bool tokenIsToken0 = pair.token0() == address(token);
        uint256 grossTokenAmount = 100 ether;
        uint256 tokenTax = grossTokenAmount * token.COMPONENT_POOL_TAX_BPS() / 10_000;
        uint256 netTokenInput = grossTokenAmount - tokenTax;

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 tokenReserve, uint256 componentReserve) =
            tokenIsToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 expectedComponentOut =
            netTokenInput * 9_975 * componentReserve / (tokenReserve * 10_000 + netTokenInput * 9_975);

        uint256 componentBefore = component.balanceOf(creator);
        vm.prank(creator);
        token.transfer(pairAddress, grossTokenAmount);
        pair.swap(tokenIsToken0 ? 0 : expectedComponentOut, tokenIsToken0 ? expectedComponentOut : 0, creator, "");
        assertEq(component.balanceOf(creator) - componentBefore, expectedComponentOut, "taxed sell preserves V2 K");

        (reserve0, reserve1,) = pair.getReserves();
        (tokenReserve, componentReserve) =
            tokenIsToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 componentInput = 1 ether;
        uint256 grossTokenOut =
            componentInput * 9_975 * tokenReserve / (componentReserve * 10_000 + componentInput * 9_975);
        uint256 expectedNetTokenOut = grossTokenOut - grossTokenOut * token.COMPONENT_POOL_TAX_BPS() / 10_000;
        address buyer = makeAddr("taxedV2Buyer");
        component.mint(buyer, componentInput);
        vm.prank(buyer);
        component.transfer(pairAddress, componentInput);

        uint256 buyerBefore = token.balanceOf(buyer);
        pair.swap(tokenIsToken0 ? grossTokenOut : 0, tokenIsToken0 ? 0 : grossTokenOut, buyer, "");
        assertEq(token.balanceOf(buyer) - buyerBefore, expectedNetTokenOut, "taxed buy preserves V2 K");
    }
}
