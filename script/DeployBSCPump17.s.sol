// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Pump} from "../src/pump/Pump.sol";
import {Token} from "../src/pump/Token.sol";
import {TagAISwapHook} from "../src/hook/TagAISwapHook.sol";
import {TagAIBuybackRouter} from "../src/router/TagAIBuybackRouter.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BSC15DeploymentConfig as DC, IBSC15Multicall3 as MC} from "./config/BSC15DeploymentConfig.sol";

/// @notice Deploys a fresh V17 Pump/Token/Hook/BuybackRouter and preserves the V16 configuration and reuses its Nutbox/Basket stack.
/// @dev External owner approvals are printed separately. No confirmed deployment file is written by a dry run.
contract DeployBSCPump17Script is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint16 internal constant HOOK_BITMAP = 0x0CC1;
    DC.Config private _config;

    function deploymentConfig() external view returns (DC.Config memory) {
        return _config;
    }

    function run() external returns (Pump pump, TagAISwapHook hook, TagAIBuybackRouter buyback) {
        require(block.chainid == 56, "BSC mainnet only");
        DC.Config memory c = DC.loadFrom(block.number, 0xee8D16f44c89B5F858e223Ab77c6091E184AaDf8, 16);
        _config = c;
        uint256 key = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(key);
        address targetOwner = vm.envOr("PUMP17_OWNER", c.owner);
        require(targetOwner != address(0), "Owner missing");

        vm.startBroadcast(key);
        // Always deploy the changed Token. A V16 template does not contain cumulative buy limits or wallet transfers.
        pump = new Pump(c.ipshare, c.feeReceiver, c.constituents, address(0));
        vm.stopBroadcast();
        MC.Result[] memory initial = DC.aggregate(DC.pumpCalls(address(pump)), c.snapshotBlock);
        address template = DC.addr(initial, 19);
        require(
            template != c.previousTemplate && template.codehash == keccak256(type(Token).runtimeCode),
            "New V17 Token required"
        );
        require(template.code.length <= 24_576 && address(pump).code.length <= 24_576, "EIP-170 size exceeded");

        bytes memory creationCode = abi.encodePacked(
            type(TagAISwapHook).creationCode, abi.encode(ICLPoolManager(c.poolManager), IVault(c.vault), address(pump))
        );
        (bytes32 salt, address predicted) = _mineSalt(keccak256(creationCode));
        vm.startBroadcast(key);
        _preserveConfiguration(pump, c, initial);
        hook = new TagAISwapHook{salt: salt}(ICLPoolManager(c.poolManager), IVault(c.vault), address(pump));
        require(address(hook) == predicted, "CREATE2 deployer mismatch");
        pump.adminSetHookAddress(address(hook));
        buyback = new TagAIBuybackRouter(address(pump), c.router, c.basketRouter, c.settlement);
        pump.adminSetBuybackRouter(address(buyback));
        pump.adminSetOptionalPoolFactory(DC.TRADE_FACTORY, "Trade Curation", 8000, true);
        if (targetOwner != deployer) pump.transferOwnership(targetOwner);
        vm.stopBroadcast();

        _verify(pump, hook, buyback, template, deployer, targetOwner, c);
        console2.log("Snapshot block", c.snapshotBlock);
        console2.log("Pump17", address(pump));
        console2.log("NEW Token17 implementation", template);
        console2.log("NEW TagAISwapHook17", address(hook));
        console2.log("NEW TagAIBuybackRouter17", address(buyback));
        console2.log("Reused TradeCurationFactory", DC.TRADE_FACTORY);
        console2.log("Target Pump owner", targetOwner);
        console2.log("NEXT: NutboxRouter owner", c.routerOwner);
        console2.log("  target", c.router);
        console2.logBytes(abi.encodeWithSignature("addOperator(address)", address(pump)));
        console2.log("NEXT: BasketRegistry owner", c.registryOwner);
        console2.log("  target", c.basketRegistry);
        console2.logBytes(abi.encodeWithSignature("setCreatorForwarderApproval(address,bool)", address(pump), true));
        if (!c.stakingAllowed) _committeeAction(c, c.stakingFactory);
        if (!c.calculatorAllowed) _committeeAction(c, c.calculator);
        if (!c.tradeAllowed) _committeeAction(c, DC.TRADE_FACTORY);
        if (targetOwner != deployer) {
            console2.log("NEXT: target owner accepts Pump ownership; target", address(pump));
            console2.logBytes(abi.encodeWithSignature("acceptOwnership()"));
        }
        console2.log("Dry-run addresses are predictions until successful broadcast receipts exist.");
    }

    function _preserveConfiguration(Pump p, DC.Config memory c, MC.Result[] memory r) internal {
        if (DC.addr(r, 3) != c.poolManager) p.adminSetPoolManager(c.poolManager);
        if (DC.addr(r, 4) != c.vault) p.adminSetVault(c.vault);
        if (
            DC.addr(r, 5) != c.communityFactory || DC.addr(r, 6) != c.calculator || DC.addr(r, 7) != c.stakingFactory
                || DC.addr(r, 8) != c.committee
        ) {
            p.adminSetNutbox(c.communityFactory, c.calculator, c.stakingFactory, c.committee);
        }
        if (
            DC.addr(r, 9) != c.router || DC.addr(r, 10) != c.basketHook || DC.addr(r, 11) != c.v2Factory
                || DC.addr(r, 12) != c.settlement
        ) {
            p.adminSetIndexInfrastructure(c.router, c.basketHook, c.v2Factory, c.settlement);
        }
        if (DC.addr(r, 13) != c.keeper) p.adminSetListingKeeper(c.keeper);
        if (abi.decode(r[15].returnData, (uint256)) != c.createFee) p.adminChangeCreateFee(c.createFee);
        if (keccak256(r[16].returnData) != keccak256(abi.encode(c.feeRatios))) p.adminChangeFeeRatio(c.feeRatios);
        if (abi.decode(r[17].returnData, (uint16)) != c.listingSlippage) {
            p.adminSetListingSwapSlippageBps(c.listingSlippage);
        }
    }

    function _verify(
        Pump p,
        TagAISwapHook h,
        TagAIBuybackRouter b,
        address template,
        address deployer,
        address targetOwner,
        DC.Config memory c
    ) internal {
        MC.Call3[] memory calls = new MC.Call3[](12);
        calls[0] = DC.get(address(p), "VERSION()");
        calls[1] = DC.get(address(p), "getHookAddress()");
        calls[2] = DC.get(address(p), "buybackRouter()");
        calls[3] = DC.get(address(p), "owner()");
        calls[4] = DC.get(address(p), "pendingOwner()");
        calls[5] = DC.get(address(p), "tokenImplementation()");
        calls[6] = DC.get(address(h), "pump()");
        calls[7] = DC.get(address(b), "pump()");
        calls[8] = DC.get(address(b), "nutboxRouter()");
        calls[9] = DC.get(address(b), "basketRouter()");
        calls[10] = DC.get(address(b), "settlementToken()");
        calls[11] = DC.call(address(p), abi.encodeWithSignature("optionalPoolFactories(address)", DC.TRADE_FACTORY));
        MC.Result[] memory r = DC.aggregate(calls, c.snapshotBlock);
        require(
            abi.decode(r[0].returnData, (uint256)) == 17 && DC.addr(r, 1) == address(h) && DC.addr(r, 2) == address(b)
                && DC.addr(r, 3) == deployer && DC.addr(r, 4) == (targetOwner == deployer ? address(0) : targetOwner)
                && DC.addr(r, 5) == template,
            "Pump configuration failed"
        );
        require(
            DC.addr(r, 6) == address(p) && DC.addr(r, 7) == address(p) && DC.addr(r, 8) == c.router
                && DC.addr(r, 9) == c.basketRouter && DC.addr(r, 10) == c.settlement,
            "Hook/buyback binding failed"
        );
        (, uint16 maxRatio, bool enabled) = abi.decode(r[11].returnData, (string, uint16, bool));
        require(enabled && maxRatio == 8000, "Trade pool configuration failed");
    }

    function _committeeAction(DC.Config memory c, address target) internal pure {
        console2.log("NEXT: Committee owner", c.committeeOwner);
        console2.log("  target", c.committee);
        console2.logBytes(abi.encodeWithSignature("adminAddContract(address)", target));
    }

    function _mineSalt(bytes32 hash) internal pure returns (bytes32 salt, address predicted) {
        // Reuse one 85-byte CREATE2 preimage; allocating it on every trial can exhaust script memory.
        bytes memory preimage = abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(0), hash);
        for (uint256 i; i < 100_000_000; ++i) {
            bytes32 digest;
            assembly ("memory-safe") {
                mstore(add(preimage, 53), i)
                digest := keccak256(add(preimage, 32), 85)
            }
            salt = bytes32(i);
            predicted = address(uint160(uint256(digest)));
            if (uint16(uint160(predicted)) == HOOK_BITMAP) return (salt, predicted);
        }
        revert("Hook salt not found");
    }
}
