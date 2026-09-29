// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../src/router/INutboxRouter.sol";
import {BSCNutboxRouterConfig as Config} from "./config/BSCNutboxRouterConfig.sol";

interface IStockRoutePump {
    function owner() external view returns (address);
    function nutboxRouter() external view returns (address);
    function approvedConstituent(address) external view returns (bool);
    function adminSetConstituentApproval(address, bool) external;
}

interface IStockRoutePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IStockRouteFactory {
    function getPool(address, address, uint24) external view returns (address);
}

/// @notice Read-only mainnet preparation: executes only inside a local fork.
/// @dev No private key, startBroadcast or on-chain transaction submission.
contract PrepareBSCStockRoutes is Script {
    address public constant ROUTER = 0x72dc4F38A7E4159e97d826a6ab594748C6b68f17;
    address public constant PUMP = 0xcd4e721Fc418f4D723C04c71e8d8EcCb75C3CD34;

    struct Call {
        address to;
        bytes data;
        string description;
    }

    function prepare() public view returns (address owner, Call[] memory calls) {
        require(block.chainid == 56, "BSC only");
        NutboxRouter router = NutboxRouter(payable(ROUTER));
        owner = router.owner();
        require(owner != address(0) && IStockRoutePump(PUMP).owner() == owner, "Owner mismatch");
        require(IStockRoutePump(PUMP).nutboxRouter() == ROUTER, "Pump router mismatch");
        require(router.wrappedNative() == Config.wrappedNative(), "WBNB mismatch");
        require(router.allowedV3Factory(Config.pancakeV3Factory()), "Factory not allowed");
        bytes32 hub = router.pricePoolId(Config.settlementToken(), Config.wrappedNative());
        require(router.hasPricePool(hub), "Hub missing");
        router.quote(Config.settlementToken(), Config.wrappedNative(), 1 ether);
        Config.AssetConfig[] memory assets = Config.stockExpansionAssets();
        calls = new Call[](assets.length * 4);
        uint256 n;
        for (uint256 i; i < assets.length; ++i) {
            Config.AssetConfig memory a = assets[i];
            IStockRoutePool pool = IStockRoutePool(a.pool);
            require(pool.factory() == Config.pancakeV3Factory() && pool.fee() == a.fee, "Pool metadata mismatch");
            require(
                IStockRouteFactory(Config.pancakeV3Factory()).getPool(a.token, a.quoteToken, a.fee) == a.pool,
                "Noncanonical pool"
            );
            require(
                (pool.token0() == a.token && pool.token1() == a.quoteToken)
                    || (pool.token1() == a.token && pool.token0() == a.quoteToken),
                "Pool tokens mismatch"
            );
            require(pool.liquidity() > 0, "No active liquidity");
            bytes32 id = router.pricePoolId(a.token, a.quoteToken);
            bytes memory source = abi.encode(Config.pancakeV3Factory(), a.pool);
            if (!router.hasPricePool(id)) {
                calls[n++] = Call(
                    ROUTER,
                    abi.encodeCall(INutboxRouter.addPricePool, (INutboxRouter.SourceType.V3_POOL, source)),
                    string.concat(a.symbol, ": add V3 /USDT pool")
                );
            } else {
                (,,,, INutboxRouter.SourceType kind, bytes memory existing) = router.pricePool(id);
                require(
                    kind == INutboxRouter.SourceType.V3_POOL && keccak256(existing) == keccak256(source),
                    "Existing pool differs; review manually"
                );
            }
            bytes32[] memory direct = new bytes32[](1);
            direct[0] = id;
            if (!_routeMatches(router, a.token, a.quoteToken, direct)) {
                calls[n++] = Call(
                    ROUTER,
                    abi.encodeCall(INutboxRouter.addRoute, (a.token, a.quoteToken, direct)),
                    string.concat(a.symbol, ": add bidirectional USDT route")
                );
            }
            bytes32[] memory cross = new bytes32[](2);
            cross[0] = id;
            cross[1] = hub;
            if (!_routeMatches(router, a.token, Config.wrappedNative(), cross)) {
                calls[n++] = Call(
                    ROUTER,
                    abi.encodeCall(INutboxRouter.addRoute, (a.token, Config.wrappedNative(), cross)),
                    string.concat(a.symbol, ": add bidirectional BNB route")
                );
            }
            if (!IStockRoutePump(PUMP).approvedConstituent(a.token)) {
                calls[n++] = Call(
                    PUMP,
                    abi.encodeCall(IStockRoutePump.adminSetConstituentApproval, (a.token, true)),
                    string.concat(a.symbol, ": approve Pump14 constituent")
                );
            }
        }
        assembly ("memory-safe") { mstore(calls, n) }
    }

    function _routeMatches(NutboxRouter router, address a, address b, bytes32[] memory ids)
        private
        view
        returns (bool)
    {
        if (!router.hasRoute(a, b)) return false;
        require(router.routePoolCount(a, b) == ids.length, "Existing route differs; review manually");
        for (uint256 i; i < ids.length; ++i) {
            require(router.routePoolAt(a, b, i) == ids[i], "Existing route differs; review manually");
        }
        return true;
    }

    function run() external {
        (address owner, Call[] memory calls) = prepare();
        uint256 sourceBlock = block.number;
        string memory transactions = "[";
        for (uint256 i; i < calls.length; ++i) {
            Call memory c = calls[i];
            vm.prank(owner);
            (bool ok, bytes memory reason) = c.to.call(c.data);
            if (!ok) assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            transactions = string.concat(
                transactions,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(c.to),
                '","value":"0","data":"',
                vm.toString(c.data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
            console2.log(c.description);
        }
        transactions = string.concat(transactions, "]");
        (, Call[] memory remaining) = prepare();
        require(remaining.length == 0, "Incomplete update");
        string memory json = string.concat(
            '{"version":"1.0","chainId":"56","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"BSC stock routes + Pump14 constituents","description":"INTCB, AMZNB, SNDKB, METAB; local fork simulation only; execute in listed order","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(owner),
            '","createdFromOwnerAddress":""},"transactions":',
            transactions,
            "}"
        );
        vm.writeJson(json, "deployments/56/stock-routes-20260929.safe.json");
        console2.log("Simulated calls", calls.length);
        console2.log("Source block", sourceBlock);
        console2.log("Required owner", owner);
        console2.log("No transactions broadcast. Safe batch written to deployments/56/stock-routes-20260929.safe.json");
    }
}
