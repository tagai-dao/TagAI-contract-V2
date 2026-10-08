// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {DeployRHPump14Script} from "./DeployRHPump14.s.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {INutboxRouter} from "../src/router/INutboxRouter.sol";
import {RHVersion14StockConfig as Stocks} from "./config/RHVersion14StockConfig.sol";

/// @notice Finish the audited interrupted deployment without redeploying its existing Router.
/// @dev First run only. If this script itself is interrupted, resume its broadcast with --resume.
contract ResumeRHPump14Script is DeployRHPump14Script {
    function run() external override returns (Stack memory s) {
        address deployer = vm.envAddress("RH14_DEPLOYER");
        NutboxRouter router = validateRecovery(deployer);
        Config memory c = loadConfig();
        vm.startBroadcast(deployer);
        INutboxRouter.InitialRoute[] memory routes = Stocks.initialRoutes();
        for (uint256 i; i < routes.length; ++i) {
            // The already-deployed immutable Router predates the new batch methods.
            if (!router.hasRoute(routes[i].tokenIn, routes[i].tokenOut)) {
                router.addRoute(routes[i].tokenIn, routes[i].tokenOut, routes[i].poolIds);
            }
        }
        s = _deployRemaining(c, CREATE2_DEPLOYER, router);
        _handover(c, s);
        vm.stopBroadcast();
        _report(c, s);
    }

    function validateRecovery(address deployer) public view returns (NutboxRouter router) {
        require(block.chainid == 4663, "RH_MAINNET_ONLY");
        require(block.timestamp <= Stocks.SNAPSHOT_TIMESTAMP + 1 days, "RECOVERY_SNAPSHOT_EXPIRED");
        string memory plan = vm.readFile("deployments/4663/rh14-recovery/plan.json");
        require(deployer == vm.parseJsonAddress(plan, ".deployer"), "RECOVERY_DEPLOYER_MISMATCH");
        require(vm.getNonce(deployer) == vm.parseJsonUint(plan, ".expectedNonce"), "RECOVERY_NONCE_CHANGED_USE_RESUME");
        router = NutboxRouter(payable(vm.parseJsonAddress(plan, ".router")));
        require(
            address(router).codehash == vm.parseJsonBytes32(plan, ".routerCodeHash"), "RECOVERY_ROUTER_CODE_MISMATCH"
        );
        require(router.owner() == deployer, "RECOVERY_OWNER_MISMATCH");
        require(router.pendingOwner() == address(0), "RECOVERY_OWNERSHIP_ALREADY_STARTED");
        INutboxRouter.InitialPricePool[] memory pools = Stocks.initialPricePools();
        INutboxRouter.InitialRoute[] memory routes = Stocks.initialRoutes();
        require(
            keccak256(abi.encode(pools, routes)) == vm.parseJsonBytes32(plan, ".configHash"), "RECOVERY_CONFIG_CHANGED"
        );
        for (uint256 i; i < pools.length; ++i) {
            bytes32 id = router.pricePoolId(pools[i].token0, pools[i].token1);
            (bool enabled,, address a, address b, INutboxRouter.SourceType kind, bytes memory data) =
                router.pricePool(id);
            require(
                enabled && a == pools[i].token0 && b == pools[i].token1 && kind == pools[i].sourceType
                    && keccak256(data) == keccak256(pools[i].sourceData),
                "RECOVERY_POOL_MISMATCH"
            );
        }
        uint256 configured;
        for (uint256 i; i < routes.length; ++i) {
            if (!router.hasRoute(routes[i].tokenIn, routes[i].tokenOut)) continue;
            ++configured;
            require(
                router.routePoolCount(routes[i].tokenIn, routes[i].tokenOut) == routes[i].poolIds.length,
                "RECOVERY_ROUTE_LENGTH_MISMATCH"
            );
            for (uint256 j; j < routes[i].poolIds.length; ++j) {
                require(
                    router.routePoolAt(routes[i].tokenIn, routes[i].tokenOut, j) == routes[i].poolIds[j],
                    "RECOVERY_ROUTE_MISMATCH"
                );
            }
        }
        require(configured == vm.parseJsonUint(plan, ".configuredRoutes"), "RECOVERY_ROUTE_COUNT_CHANGED");
    }
}
