// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {INutboxRouter} from "../src/router/INutboxRouter.sol";
import {NutboxRouter} from "../src/router/NutboxRouter.sol";
import {BSCNutboxRouterConfig} from "./config/BSCNutboxRouterConfig.sol";

interface IRouterDeployPancakeV4CLManager {
    function vault() external view returns (address);
}

interface IRouterDeployPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IRouterDeployPancakeV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}

/**
 * @title DeployBSCNutboxRouter
 * @notice Deploys and configures the single shared NutboxRouter used by Basket V3 and Index Broker NFT.
 *
 * Dry run:
 *   forge script script/DeployBSCNutboxRouter.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast and verify (all initial pools and routes are written atomically by the deployment):
 *   forge script script/DeployBSCNutboxRouter.s.sol \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * NUTBOX_ROUTER_OWNER must explicitly select the final owner. Ownership uses Ownable2Step,
 * so a different target owner must call acceptOwnership() after deployment. Do not write the
 * authoritative deployment record until every transaction is confirmed and validated.
 */
contract DeployBSCNutboxRouterScript is Script {
    string internal constant VERSION11_PATH = "deployments/56/version11.json";

    address internal clPoolManager;
    address internal vault;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        _loadVersion11();

        uint256 privateKey = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(privateKey);
        require(vm.envExists("NUTBOX_ROUTER_OWNER"), "NUTBOX_ROUTER_OWNER must be explicit");
        address targetOwner = vm.envAddress("NUTBOX_ROUTER_OWNER");

        require(targetOwner != address(0), "NutboxRouter owner missing");
        _validateDependencies();

        console2.log("=== BSC Shared NutboxRouter Deploy ===");
        console2.log("Deployment record", VERSION11_PATH);
        console2.log("Deployer", deployer);
        console2.log("Target owner", targetOwner);
        console2.log("Pancake V4 CL manager", clPoolManager);

        vm.startBroadcast(privateKey);
        NutboxRouter router = _deployRouter();
        if (targetOwner != deployer) router.transferOwnership(targetOwner);
        vm.stopBroadcast();

        _validateDeployment(router, deployer, targetOwner);

        console2.log("NutboxRouter", address(router));
        if (targetOwner != deployer) {
            console2.log("ACTION REQUIRED: target owner must accept NutboxRouter ownership", targetOwner);
        }
        console2.log("ACTION REQUIRED: record the Router only after every broadcast transaction is confirmed");
    }

    function _deployRouter() internal returns (NutboxRouter router) {
        address[] memory v2Factories = new address[](1);
        v2Factories[0] = BSCNutboxRouterConfig.pancakeV2Factory();
        address[] memory v2Routers = new address[](1);
        v2Routers[0] = BSCNutboxRouterConfig.pancakeV2Router();
        address[] memory v3Factories = new address[](1);
        v3Factories[0] = BSCNutboxRouterConfig.pancakeV3Factory();
        address[] memory pancakeV4Managers = new address[](1);
        pancakeV4Managers[0] = clPoolManager;
        bytes memory initialConfig = BSCNutboxRouterConfig.initialConfig();

        router = new NutboxRouter(
            BSCNutboxRouterConfig.wrappedNative(),
            BSCNutboxRouterConfig.pancakeV3Router(),
            v2Routers,
            v2Factories,
            v3Factories,
            new address[](0),
            pancakeV4Managers,
            initialConfig
        );
    }

    function _loadVersion11() internal {
        require(vm.exists(VERSION11_PATH), "deployments/56/version11.json missing");
        string memory json = vm.readFile(VERSION11_PATH);
        require(vm.parseJsonUint(json, ".version") == 11, "Expected deployment version 11");

        clPoolManager = vm.parseJsonAddress(json, ".CLPoolManager");
        vault = vm.parseJsonAddress(json, ".Vault");

        require(vm.parseJsonAddress(json, ".WBNB") == BSCNutboxRouterConfig.wrappedNative(), "V11 WBNB mismatch");
        require(vm.parseJsonAddress(json, ".USDT") == BSCNutboxRouterConfig.settlementToken(), "V11 USDT mismatch");
        require(
            vm.parseJsonAddress(json, ".PancakeV2Factory") == BSCNutboxRouterConfig.pancakeV2Factory(),
            "V11 Pancake V2 factory mismatch"
        );
        require(
            vm.parseJsonAddress(json, ".PancakeV3Factory") == BSCNutboxRouterConfig.pancakeV3Factory(),
            "V11 Pancake V3 factory mismatch"
        );
        require(
            vm.parseJsonAddress(json, ".PancakeV3SmartRouter") == BSCNutboxRouterConfig.pancakeV3Router(),
            "V11 Pancake V3 router mismatch"
        );
    }

    function _validateDependencies() internal view {
        require(clPoolManager.code.length > 0, "Pancake V4 CL manager missing");
        require(vault.code.length > 0, "Pancake V4 Vault missing");
        require(IRouterDeployPancakeV4CLManager(clPoolManager).vault() == vault, "Pancake V4 Vault mismatch");
        require(BSCNutboxRouterConfig.wrappedNative().code.length > 0, "WBNB missing");
        require(BSCNutboxRouterConfig.settlementToken().code.length > 0, "USDT missing");
        require(BSCNutboxRouterConfig.pancakeV2Factory().code.length > 0, "Pancake V2 factory missing");
        require(BSCNutboxRouterConfig.pancakeV2Router().code.length > 0, "Pancake V2 router missing");
        require(BSCNutboxRouterConfig.pancakeV3Factory().code.length > 0, "Pancake V3 factory missing");
        require(BSCNutboxRouterConfig.pancakeV3Router().code.length > 0, "Pancake V3 router missing");

        BSCNutboxRouterConfig.AssetConfig memory hub = BSCNutboxRouterConfig.hubPoolConfig();
        _validateLiveV3Pool(hub);
        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            require(assets[i].token.code.length > 0, "Configured asset missing");
            _validateLiveV3Pool(assets[i]);
        }
    }

    function _validateDeployment(NutboxRouter router, address deployer, address targetOwner) internal view {
        address wbnb = BSCNutboxRouterConfig.wrappedNative();
        address usdt = BSCNutboxRouterConfig.settlementToken();

        require(address(router).code.length > 0, "NutboxRouter deployment failed");
        require(router.wrappedNative() == wbnb, "Router WBNB mismatch");
        require(router.pancakeV3Router() == BSCNutboxRouterConfig.pancakeV3Router(), "Router V3 executor mismatch");
        require(router.pancakeV3Factory() == BSCNutboxRouterConfig.pancakeV3Factory(), "Router V3 factory mismatch");
        require(router.allowedV2Factory(BSCNutboxRouterConfig.pancakeV2Factory()), "Router V2 factory missing");
        require(
            router.v2RouterForFactory(BSCNutboxRouterConfig.pancakeV2Factory())
                == BSCNutboxRouterConfig.pancakeV2Router(),
            "Router V2 executor mismatch"
        );
        require(router.allowedV3Factory(BSCNutboxRouterConfig.pancakeV3Factory()), "Router V3 factory missing");
        require(router.allowedPancakeV4CLManager(clPoolManager), "Router V4 manager missing");
        require(router.allowedPancakeV4Vault(vault), "Router V4 Vault missing");
        require(router.hasRoute(usdt, wbnb), "Router USDT/WBNB route missing");
        require(router.routePoolCount(usdt, wbnb) == 1, "Router USDT/WBNB route invalid");
        router.validateRoute(usdt, wbnb);
        router.validateRoute(wbnb, usdt);
        require(router.quote(usdt, wbnb, 1 ether) > 0, "Router USDT/WBNB quote failed");
        require(router.quote(wbnb, usdt, 1 ether) > 0, "Router WBNB/USDT quote failed");

        bytes32 hubPoolId = router.pricePoolId(usdt, wbnb);
        _validateStoredPool(router, BSCNutboxRouterConfig.hubPoolConfig(), 15);
        require(router.routePoolAt(usdt, wbnb, 0) == hubPoolId, "Router hub pool mismatch");
        require(router.routePoolAt(wbnb, usdt, 0) == hubPoolId, "Router reverse hub pool mismatch");

        BSCNutboxRouterConfig.AssetConfig[] memory assets = BSCNutboxRouterConfig.assetConfigs();
        for (uint256 i; i < assets.length; ++i) {
            _validateStoredAssetRoutes(router, assets[i], hubPoolId, usdt, wbnb);
        }

        require(router.owner() == deployer, "Unexpected Router owner");
        if (targetOwner != deployer) {
            require(router.pendingOwner() == targetOwner, "Router owner handover missing");
        }
    }

    function _validateStoredPool(
        NutboxRouter router,
        BSCNutboxRouterConfig.AssetConfig memory config,
        uint32 expectedReferences
    ) internal view returns (bytes32 poolId) {
        poolId = router.pricePoolId(config.token, config.quoteToken);
        (
            bool enabled,
            uint32 routeReferences,
            address token0,
            address token1,
            INutboxRouter.SourceType sourceType,
            bytes memory sourceData
        ) = router.pricePool(poolId);
        (address expectedToken0, address expectedToken1) = uint160(config.token) < uint160(config.quoteToken)
            ? (config.token, config.quoteToken)
            : (config.quoteToken, config.token);

        require(enabled, "Configured Router pool missing");
        require(routeReferences == expectedReferences, "Configured Router pool references mismatch");
        require(token0 == expectedToken0 && token1 == expectedToken1, "Configured Router pool endpoints mismatch");
        require(sourceType == INutboxRouter.SourceType.V3_POOL, "Configured Router pool type mismatch");
        require(
            keccak256(sourceData) == keccak256(abi.encode(BSCNutboxRouterConfig.pancakeV3Factory(), config.pool)),
            "Configured Router pool source mismatch"
        );
    }

    function _validateStoredAssetRoutes(
        NutboxRouter router,
        BSCNutboxRouterConfig.AssetConfig memory config,
        bytes32 hubPoolId,
        address usdt,
        address wbnb
    ) internal view {
        bytes32 assetPoolId = _validateStoredPool(router, config, 2);
        address crossToken = config.quoteToken == usdt ? wbnb : usdt;

        require(router.routePoolCount(config.token, config.quoteToken) == 1, "Router direct route length mismatch");
        require(
            router.routePoolAt(config.token, config.quoteToken, 0) == assetPoolId, "Router direct route pool mismatch"
        );
        require(router.routePoolCount(config.token, crossToken) == 2, "Router cross route length mismatch");
        require(router.routePoolAt(config.token, crossToken, 0) == assetPoolId, "Router cross asset pool mismatch");
        require(router.routePoolAt(config.token, crossToken, 1) == hubPoolId, "Router cross hub pool mismatch");
        require(router.routePoolAt(crossToken, config.token, 0) == hubPoolId, "Router reverse hub pool mismatch");
        require(router.routePoolAt(crossToken, config.token, 1) == assetPoolId, "Router reverse asset pool mismatch");

        router.validateRoute(config.token, config.quoteToken);
        router.validateRoute(config.quoteToken, config.token);
        router.validateRoute(config.token, crossToken);
        router.validateRoute(crossToken, config.token);
        require(router.quote(config.token, config.quoteToken, 1 ether) > 0, "Router direct quote failed");
        require(router.quote(config.quoteToken, config.token, 1 ether) > 0, "Router reverse direct quote failed");
        require(router.quote(config.token, crossToken, 1 ether) > 0, "Router cross quote failed");
        require(router.quote(crossToken, config.token, 1 ether) > 0, "Router reverse cross quote failed");
    }

    function _validateLiveV3Pool(BSCNutboxRouterConfig.AssetConfig memory config) internal view {
        address factory = BSCNutboxRouterConfig.pancakeV3Factory();
        IRouterDeployPancakeV3Pool pool = IRouterDeployPancakeV3Pool(config.pool);
        require(config.pool.code.length > 0, "Configured V3 pool missing");
        require(pool.factory() == factory, "Configured V3 pool factory mismatch");
        require(pool.fee() == config.fee, "Configured V3 pool fee mismatch");
        require(
            IRouterDeployPancakeV3Factory(factory).getPool(config.token, config.quoteToken, config.fee) == config.pool,
            "Configured V3 pool is not canonical"
        );
        require(
            (pool.token0() == config.token && pool.token1() == config.quoteToken)
                || (pool.token0() == config.quoteToken && pool.token1() == config.token),
            "Configured V3 pool endpoints mismatch"
        );
        (uint160 sqrtPriceX96,,,,,, bool unlocked) = pool.slot0();
        require(sqrtPriceX96 != 0, "Configured V3 pool not initialized");
        require(pool.liquidity() != 0, "Configured V3 pool has no active liquidity");
        require(unlocked, "Configured V3 pool is locked");
    }
}
