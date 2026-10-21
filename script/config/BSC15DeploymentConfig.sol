// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BSCNutboxRouterConfig} from "./BSCNutboxRouterConfig.sol";

/// @dev ABI and BSC address: https://github.com/mds1/multicall3
interface IBSC15Multicall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }
    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory);
    function getBlockNumber() external view returns (uint256);
}

/// @notice Reads the existing BSC V14 stack in ordered Multicall stages at one snapshot block.
library BSC15DeploymentConfig {
    address internal constant MULTICALL = 0xcA11bde05977b3631167028862bE2a173976CA11;
    address internal constant PREVIOUS_PUMP = 0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34;
    address internal constant TRADE_FACTORY = 0x774A48Ba391a1013Ae43289eBdf871618822CD67;
    error SnapshotChanged();
    error RequiredReadFailed(uint256 index, address target);

    struct Config {
        uint256 snapshotBlock;
        address owner;
        address ipshare;
        address feeReceiver;
        address poolManager;
        address vault;
        address communityFactory;
        address calculator;
        address stakingFactory;
        address committee;
        address router;
        address basketHook;
        address v2Factory;
        address settlement;
        address keeper;
        address previousBuyback;
        address previousTemplate;
        uint256 createFee;
        uint256[2] feeRatios;
        uint16 listingSlippage;
        address basketRouter;
        address basketRegistry;
        address routerOwner;
        address registryOwner;
        address committeeOwner;
        bool stakingAllowed;
        bool calculatorAllowed;
        bool tradeAllowed;
        address[] constituents;
    }

    function call(address target, bytes memory data) internal pure returns (IBSC15Multicall3.Call3 memory) {
        return IBSC15Multicall3.Call3(target, false, data);
    }

    function get(address target, string memory signature) internal pure returns (IBSC15Multicall3.Call3 memory) {
        return call(target, abi.encodeWithSignature(signature));
    }

    function aggregate(IBSC15Multicall3.Call3[] memory calls, uint256 pin)
        internal
        returns (IBSC15Multicall3.Result[] memory results)
    {
        if (block.number != pin) revert SnapshotChanged();
        IBSC15Multicall3.Call3[] memory pinned = new IBSC15Multicall3.Call3[](calls.length + 1);
        pinned[0] = get(MULTICALL, "getBlockNumber()");
        for (uint256 i; i < calls.length; ++i) {
            pinned[i + 1] = call(calls[i].target, calls[i].callData);
        }
        IBSC15Multicall3.Result[] memory raw = IBSC15Multicall3(MULTICALL).aggregate3(pinned);
        require(raw.length == pinned.length, "Multicall result count");
        if (!raw[0].success || raw[0].returnData.length != 32 || abi.decode(raw[0].returnData, (uint256)) != pin) {
            revert SnapshotChanged();
        }
        results = new IBSC15Multicall3.Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            if (!raw[i + 1].success || raw[i + 1].returnData.length == 0) {
                revert RequiredReadFailed(i, calls[i].target);
            }
            results[i] = raw[i + 1];
        }
    }

    function addr(IBSC15Multicall3.Result[] memory r, uint256 i) internal pure returns (address) {
        return abi.decode(r[i].returnData, (address));
    }

    function flag(IBSC15Multicall3.Result[] memory r, uint256 i) internal pure returns (bool) {
        return abi.decode(r[i].returnData, (bool));
    }

    function pumpCalls(address pump) internal pure returns (IBSC15Multicall3.Call3[] memory calls) {
        string[20] memory names = [
            "owner()",
            "getIPShare()",
            "getFeeReceiver()",
            "getPoolManager()",
            "getVault()",
            "nutboxCommunityFactory()",
            "getCalculator()",
            "erc20StakingFactory()",
            "nutboxCommittee()",
            "nutboxRouter()",
            "basketHookV4()",
            "pancakeV2Factory()",
            "settlementToken()",
            "listingKeeper()",
            "buybackRouter()",
            "createFee()",
            "getFeeRatio()",
            "listingSwapSlippageBps()",
            "VERSION()",
            "tokenImplementation()"
        ];
        calls = new IBSC15Multicall3.Call3[](names.length);
        for (uint256 i; i < names.length; ++i) {
            calls[i] = get(pump, names[i]);
        }
    }

    function load(uint256 pin) internal returns (Config memory c) {
        c.snapshotBlock = pin;
        IBSC15Multicall3.Result[] memory r = aggregate(pumpCalls(PREVIOUS_PUMP), pin);
        require(abi.decode(r[18].returnData, (uint256)) == 14, "Expected previous BSC Pump14");
        c.owner = addr(r, 0);
        c.ipshare = addr(r, 1);
        c.feeReceiver = addr(r, 2);
        c.poolManager = addr(r, 3);
        c.vault = addr(r, 4);
        c.communityFactory = addr(r, 5);
        c.calculator = addr(r, 6);
        c.stakingFactory = addr(r, 7);
        c.committee = addr(r, 8);
        c.router = addr(r, 9);
        c.basketHook = addr(r, 10);
        c.v2Factory = addr(r, 11);
        c.settlement = addr(r, 12);
        c.keeper = addr(r, 13);
        c.previousBuyback = addr(r, 14);
        c.createFee = abi.decode(r[15].returnData, (uint256));
        c.feeRatios = abi.decode(r[16].returnData, (uint256[2]));
        c.listingSlippage = abi.decode(r[17].returnData, (uint16));
        c.previousTemplate = addr(r, 19);
        require(c.owner != address(0) && c.keeper != address(0), "Missing owner/keeper");

        IBSC15Multicall3.Call3[] memory calls = new IBSC15Multicall3.Call3[](14);
        calls[0] = get(c.basketHook, "tokenVersion()");
        calls[1] = get(c.basketHook, "nutboxRouter()");
        calls[2] = get(c.basketHook, "v2Factory()");
        calls[3] = get(c.basketHook, "settlementToken()");
        calls[4] = get(c.basketHook, "basketRegistry()");
        calls[5] = get(c.previousBuyback, "basketRouter()");
        calls[6] = get(c.router, "owner()");
        calls[7] = get(c.committee, "owner()");
        calls[8] = get(TRADE_FACTORY, "communityFactory()");
        calls[9] = get(c.calculator, "communityFactory()");
        calls[10] = call(c.committee, abi.encodeWithSignature("verifyContract(address)", c.stakingFactory));
        calls[11] = call(c.committee, abi.encodeWithSignature("verifyContract(address)", c.calculator));
        calls[12] = call(c.committee, abi.encodeWithSignature("verifyContract(address)", TRADE_FACTORY));
        calls[13] = get(c.previousBuyback, "nutboxRouter()");
        r = aggregate(calls, pin);
        require(abi.decode(r[0].returnData, (uint32)) == 4, "Basket V4 required");
        require(
            addr(r, 1) == c.router && addr(r, 2) == c.v2Factory && addr(r, 3) == c.settlement,
            "Basket infrastructure mismatch"
        );
        require(addr(r, 8) == c.communityFactory && addr(r, 9) == c.communityFactory, "Nutbox factory mismatch");
        require(addr(r, 13) == c.router, "Previous buyback/router mismatch");
        c.basketRegistry = addr(r, 4);
        c.basketRouter = addr(r, 5);
        c.routerOwner = addr(r, 6);
        c.committeeOwner = addr(r, 7);
        c.stakingAllowed = flag(r, 10);
        c.calculatorAllowed = flag(r, 11);
        c.tradeAllowed = flag(r, 12);

        address[] memory catalog = BSCNutboxRouterConfig.constituentAssets();
        calls = new IBSC15Multicall3.Call3[](4 + catalog.length * 3);
        calls[0] = get(c.basketRegistry, "owner()");
        calls[1] = get(c.basketRouter, "basketHook()");
        calls[2] = get(c.basketRouter, "settlementToken()");
        calls[3] = call(c.basketRegistry, abi.encodeWithSignature("approvedRegistrars(address)", c.basketHook));
        for (uint256 i; i < catalog.length; ++i) {
            calls[4 + i * 3] = call(PREVIOUS_PUMP, abi.encodeWithSignature("approvedConstituent(address)", catalog[i]));
            calls[5 + i * 3] =
                call(c.router, abi.encodeWithSignature("hasRoute(address,address)", address(0), catalog[i]));
            calls[6 + i * 3] =
                call(c.router, abi.encodeWithSignature("hasRoute(address,address)", c.settlement, catalog[i]));
        }
        r = aggregate(calls, pin);
        c.registryOwner = addr(r, 0);
        require(
            addr(r, 1) == c.basketHook && addr(r, 2) == c.settlement && flag(r, 3), "Basket router/registrar mismatch"
        );
        uint256 count;
        for (uint256 i; i < catalog.length; ++i) {
            if (flag(r, 4 + i * 3)) {
                require(flag(r, 5 + i * 3) && flag(r, 6 + i * 3), "Approved constituent route missing");
                ++count;
            }
        }
        require(count > 0, "No approved constituents");
        c.constituents = new address[](count);
        count = 0;
        for (uint256 i; i < catalog.length; ++i) {
            if (flag(r, 4 + i * 3)) c.constituents[count++] = catalog[i];
        }
    }
}
