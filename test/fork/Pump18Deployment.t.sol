// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployBSCPump18Script} from "../../script/DeployBSCPump18.s.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "../../script/config/BSC15DeploymentConfig.sol";
import {Pump} from "../../src/pump/Pump.sol";
import {Token} from "../../src/pump/Token.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {IToken} from "../../src/interfaces/IToken.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {TagAIBuybackRouter} from "../../src/router/TagAIBuybackRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILive18Governance {
    function addOperator(address) external;
    function setCreatorForwarderApproval(address, bool) external;
    function adminAddContract(address) external;
    function adminRegister(string calldata, address) external;
}

interface ILive18Router {
    function swapExactInput(address, address, uint256, uint256, address, uint256) external payable returns (uint256);
}

interface ILive18BasketRouter {
    function sellExactBasket(address, uint256, uint256, bytes calldata, address) external returns (uint256);
}

/// @notice Real deployed BSC Nutbox, Basket V4, NFT and DEX bytecode. No mocks/etch or RPC broadcasts.
/// @dev Existing owner approvals and NFT registration are executed ONLY inside this disposable fork.
contract Pump18DeploymentForkTest is Test {
    address constant HANDLE_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    uint256 constant DEFAULT_BLOCK = 130212794;
    DC.Config c;
    Pump pump;
    TagAISwapHook hook;
    TagAIBuybackRouter buyback;
    address creator;
    uint256 pin;
    address constant SAFE = 0x871fb7006C5964B21695Ba20006021777A26146C;
    address handleOwner;
    uint256 handleLength;

    struct BasketTradeData {
        address frontend;
        uint256 minBasketOut;
        uint256 minSettlementOut;
        uint256[] legMins;
        uint160[] legSqrtPriceLimitsX96;
        uint160 settlementToWbnbSqrtPriceLimitX96;
        bool[] allowFailedLegs;
    }
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        pin = vm.envOr("PUMP18_FORK_BLOCK", DEFAULT_BLOCK);
        vm.createSelectFork(rpc, pin);
        require(block.chainid == 56, "BSC fork required");
        vm.deal(vm.addr(1), 100 ether);
        vm.deal(address(this), 1000 ether);
        creator = makeAddr("v18-live-fork-creator");
        vm.deal(creator, 1000 ether);
        vm.setEnv("PRIVATE_KEY_MAIN", "1");
        vm.setEnv("PUMP18_OWNER", vm.toString(SAFE));
        DeployBSCPump18Script deployment = new DeployBSCPump18Script();
        (pump, hook, buyback) = deployment.run();
        c = deployment.deploymentConfig();
        _activateInFork();
    }

    function _activateInFork() internal {
        vm.prank(SAFE);
        pump.acceptOwnership();
        vm.prank(c.routerOwner);
        ILive18Governance(c.router).addOperator(address(pump));
        vm.prank(c.registryOwner);
        ILive18Governance(c.basketRegistry).setCreatorForwarderApproval(address(pump), true);
        if (!c.stakingAllowed) {
            vm.prank(c.committeeOwner);
            ILive18Governance(c.committee).adminAddContract(c.stakingFactory);
        }
        if (!c.calculatorAllowed) {
            vm.prank(c.committeeOwner);
            ILive18Governance(c.committee).adminAddContract(c.calculator);
        }
        if (!c.tradeAllowed) {
            vm.prank(c.committeeOwner);
            ILive18Governance(c.committee).adminAddContract(DC.TRADE_FACTORY);
        }
    }

    function _number(address target, bytes memory data) internal returns (uint256) {
        MC.Call3[] memory calls = new MC.Call3[](1);
        calls[0] = DC.call(target, data);
        return abi.decode(DC.aggregate(calls, pin)[0].returnData, (uint256));
    }

    function _createWithPremine() internal returns (Token t, address community) {
        MC.Call3[] memory calls = new MC.Call3[](5);
        calls[0] = DC.call(c.ipshare, abi.encodeWithSignature("ipshareCreated(address)", creator));
        calls[1] = DC.get(c.ipshare, "createFee()");
        calls[2] = DC.get(c.committee, "getCreateCommunityFee()");
        calls[3] = DC.get(c.committee, "getCommunitySettingsFee()");
        calls[4] = DC.call(HANDLE_REGISTRY, abi.encodeWithSignature("handleOf(address)", creator));
        MC.Result[] memory r = DC.aggregate(calls, pin);
        assertEq(bytes(abi.decode(r[4].returnData, (string))).length, 0);
        uint256 fee = c.createFee + (DC.flag(r, 0) ? 0 : abi.decode(r[1].returnData, (uint256)))
            + abi.decode(r[2].returnData, (uint256)) + 3 * abi.decode(r[3].returnData, (uint256));
        IPump.IndexConfig memory index;
        index.name = "V18 live stack integration";
        index.symbol = "V18I";
        index.constituentAssets = new address[](2);
        index.constituentAssets[0] = c.constituents[0];
        index.constituentAssets[1] = c.constituents[1];
        index.targetWeights = new uint16[](2);
        index.targetWeights[0] = 5000;
        index.targetWeights[1] = 5000;
        index.basketFeeBps = 100;
        index.creatorShareBps = 3000;
        index.retainCommunityOwnership = true;
        IPump.OptionalPoolConfig[] memory optional = new IPump.OptionalPoolConfig[](1);
        optional[0] = IPump.OptionalPoolConfig(DC.TRADE_FACTORY, 8000, "");
        vm.prank(creator, creator);
        t = Token(payable(pump.createToken{value: fee + 0.01 ether}("LIVE17", bytes32(uint256(15)), index, optional)));
        community = address(uint160(_number(address(t), abi.encodeWithSignature("nutboxCommunity()"))));
        calls = new MC.Call3[](6);
        calls[0] = DC.get(community, "owner()");
        calls[1] = DC.call(community, abi.encodeWithSignature("activedPools(uint256)", 0));
        calls[2] = DC.call(community, abi.encodeWithSignature("activedPools(uint256)", 1));
        calls[3] = DC.call(community, abi.encodeWithSignature("activedPools(uint256)", 2));
        calls[4] = DC.call(DC.TRADE_FACTORY, abi.encodeWithSignature("createdPoolOfCommunity(address)", community));
        calls[5] = DC.call(address(t), abi.encodeWithSignature("balanceOf(address)", creator));
        r = DC.aggregate(calls, pin);
        assertEq(DC.addr(r, 0), creator);
        assertTrue(DC.addr(r, 1) != address(0) && DC.addr(r, 2) != address(0) && DC.addr(r, 3) != address(0));
        assertTrue(DC.flag(r, 4));
        assertGt(abi.decode(r[5].returnData, (uint256)), 0);
    }

    function _registerCreatorInFork() internal {
        MC.Call3[] memory calls = new MC.Call3[](3);
        calls[0] = DC.get(HANDLE_REGISTRY, "owner()");
        calls[1] = DC.get(HANDLE_REGISTRY, "minLen()");
        calls[2] = DC.get(HANDLE_REGISTRY, "maxLen()");
        MC.Result[] memory r = DC.aggregate(calls, pin);
        handleOwner = DC.addr(r, 0);
        require(handleOwner != address(0), "NFT owner renounced");
        uint256 minimum = abi.decode(r[1].returnData, (uint8));
        uint256 maximum = abi.decode(r[2].returnData, (uint8));
        uint256 length = minimum > 17 ? minimum : (maximum < 17 ? maximum : 17);
        handleLength = length;
        _registerWalletInFork(creator);
    }

    function _registerWalletInFork(address account) internal {
        uint256 length = handleLength;
        bytes memory handle = new bytes(length);
        bytes memory alphabet = "0123456789abcdef";
        bytes32 entropy = keccak256(abi.encode(account, "v18-live-fork"));
        for (uint256 i; i < length; ++i) {
            handle[i] = alphabet[uint8(entropy[i % 32]) & 15];
        }
        vm.prank(handleOwner);
        ILive18Governance(HANDLE_REGISTRY).adminRegister(string(handle), account);
    }

    function _list(Token t) internal {
        uint256 cap = 650_000_000 ether;
        uint256 supply = _number(address(t), abi.encodeWithSignature("bondingCurveSupply()"));
        uint256 count;
        while (supply < cap) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("v18-live-buyer", count++)))));
            _registerWalletInFork(buyer);
            vm.deal(buyer, 1000 ether);
            MC.Call3[] memory priceCalls = new MC.Call3[](2);
            priceCalls[0] =
                DC.call(address(pump), abi.encodeWithSignature("getPrice(uint256,uint256)", supply, 9_000_000 ether));
            priceCalls[1] = DC.get(address(t), "getBuyFeeRatios()");
            MC.Result[] memory quotes = DC.aggregate(priceCalls, pin);
            uint256 price = abi.decode(quotes[0].returnData, (uint256));
            (uint256 platform, uint256 salesman) = abi.decode(quotes[1].returnData, (uint256, uint256));
            uint256 denom = 10000 - platform - salesman;
            uint256 value = cap - supply <= 9_000_000 ether ? 100 ether : (price * 10000 + denom - 1) / denom;
            vm.startPrank(buyer, buyer);
            uint256 received = t.buyToken{value: value}(0, creator, 0);
            t.transfer(creator, received);
            vm.stopPrank();
            assertLe(
                _number(address(t), abi.encodeWithSignature("innerMarketBought(address)", buyer)), 10_000_000 ether
            );
            supply = _number(address(t), abi.encodeWithSignature("bondingCurveSupply()"));
        }
        uint256 budget = _number(address(t), abi.encodeWithSignature("componentListingNativeBudget()"));
        MC.Call3[] memory calls = new MC.Call3[](2);
        calls[0] = DC.call(
            c.router,
            abi.encodeWithSignature("quote(address,address,uint256)", address(0), c.constituents[0], budget / 2)
        );
        calls[1] = DC.call(
            c.router,
            abi.encodeWithSignature(
                "quote(address,address,uint256)", address(0), c.constituents[1], budget - budget / 2
            )
        );
        MC.Result[] memory r = DC.aggregate(calls, pin);
        uint256[] memory mins = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            mins[i] = abi.decode(r[i].returnData, (uint256)) * 95 / 100;
            assertGt(mins[i], 0);
        }
        vm.prank(c.keeper);
        pump.finalizeTokenListing(address(t), mins, block.timestamp + 60);
    }

    function test_v18_liveIpShareAutoCreationOnAllTradeEntrypoints() public {
        (Token t,) = _createWithPremine();
        _registerCreatorInFork();
        vm.warp(block.timestamp + 16);
        address buyer = makeAddr("v18-explicit-buyer");
        address direct = makeAddr("v18-direct-buyer");
        address seller = makeAddr("v18-transfer-recipient");
        address[3] memory traders = [buyer, direct, seller];
        for (uint256 i; i < traders.length; ++i) {
            _registerWalletInFork(traders[i]);
            vm.deal(traders[i], 1 ether);
            assertEq(_number(c.ipshare, abi.encodeWithSignature("ipshareCreated(address)", traders[i])), 0);
        }
        vm.prank(buyer, buyer);
        assertGt(t.buyToken{value: 0.01 ether}(0, buyer, 0), 0);
        vm.prank(direct, direct);
        (bool ok,) = address(t).call{value: 0.01 ether}("");
        assertTrue(ok);
        vm.prank(creator, creator);
        t.transfer(seller, 1000 ether);
        assertEq(_number(c.ipshare, abi.encodeWithSignature("ipshareCreated(address)", seller)), 0);
        vm.prank(seller, seller);
        t.sellToken(1000 ether, 0, seller, 0);
        for (uint256 i; i < traders.length; ++i) {
            assertEq(_number(c.ipshare, abi.encodeWithSignature("ipshareCreated(address)", traders[i])), 1);
            assertEq(_number(c.ipshare, abi.encodeWithSignature("totalStakedIPshare(address)", traders[i])), 10 ether);
        }
        assertEq(_number(c.ipshare, abi.encodeWithSignature("ipshareCreated(address)", address(pump))), 0);
    }

    function test_v18_liveNutboxBasketNFTListingAndBuyback() public {
        (Token t,) = _createWithPremine();
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, creator));
        t.buyToken{value: 0.01 ether}(0, creator, 0);
        vm.prank(creator, creator);
        (bool ok,) = address(t).call{value: 0.01 ether}("");
        assertFalse(ok);
        _registerCreatorInFork();
        vm.warp(block.timestamp + 16);
        vm.prank(creator, creator);
        t.buyToken{value: 0.01 ether}(0, creator, 0);
        address unregistered = makeAddr("v18-unregistered-recipient");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, unregistered));
        t.transfer(unregistered, 1 ether);
        vm.prank(creator);
        t.approve(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IToken.HandleNotRegistered.selector, unregistered));
        t.transferFrom(creator, unregistered, 1 ether);
        assertEq(
            _number(address(t), abi.encodeWithSignature("allowance(address,address)", creator, address(this))), 1 ether
        );
        _list(t);
        address index = address(uint160(_number(address(t), abi.encodeWithSignature("indexToken()"))));
        MC.Call3[] memory calls = new MC.Call3[](4);
        calls[0] = DC.get(address(t), "listed()");
        calls[1] = DC.call(c.basketRegistry, abi.encodeWithSignature("isBasket(address)", index));
        calls[2] = DC.get(index, "protocolVersion()");
        calls[3] = DC.get(c.vault, "getUnsettledDeltasCount()");
        MC.Result[] memory r = DC.aggregate(calls, pin);
        assertTrue(DC.flag(r, 0) && DC.flag(r, 1));
        assertEq(abi.decode(r[2].returnData, (uint32)), 4);
        assertEq(abi.decode(r[3].returnData, (uint256)), 0);
        assertGt(
            ILive18Router(c.router).swapExactInput{value: 1 ether}(
                address(0), address(t), 1 ether, 1, address(this), block.timestamp + 60
            ),
            0
        );
        uint256 reserve = _number(address(hook), abi.encodeWithSignature("buybackBnbReserve(address)", address(t)));
        assertGt(reserve, 0);
        uint256 settlementMin = _number(
                c.router, abi.encodeWithSignature("quote(address,address,uint256)", address(0), c.settlement, reserve)
            ) * 95 / 100;
        BasketTradeData memory d;
        d.legMins = new uint256[](2);
        d.legMins[0] = 1;
        d.legMins[1] = 1;
        d.legSqrtPriceLimitsX96 = new uint160[](0);
        d.allowFailedLegs = new bool[](2);
        uint256 out = hook.executeBuyback(address(t), 1, block.timestamp + 60, abi.encode(settlementMin, abi.encode(d)));
        assertGt(out, 0);
        assertGt(t.claimBuybackReward(creator), 0);
        t.claimBuybackReward(address(this));
        uint256 shares = _number(index, abi.encodeWithSignature("balanceOf(address)", address(this)));
        assertGt(shares, 0);
        IERC20(index).approve(c.basketRouter, shares);
        assertGt(ILive18BasketRouter(c.basketRouter).sellExactBasket(index, shares, 1, "", address(this)), 0);
        assertEq(block.number, pin);
    }
}
