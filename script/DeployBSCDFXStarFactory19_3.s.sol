// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DFXStarScoreStakingFactory} from "../src/nutbox/dapps/dfxstar-score-staking/DFXStarScoreStakingFactory.sol";
import {DFXStarScoreStaking} from "../src/nutbox/dapps/dfxstar-score-staking/DFXStarScoreStaking.sol";
import {ICommittee} from "../src/nutbox/interfaces/ICommittee.sol";

/**
 * @title DeployBSCDFXStarFactory19_3Script
 * @notice Redeploys World-bound DFXStarScoreStakingFactory after deposit reward + refund fixes.
 *
 * Fixes vs 19.2 template:
 * - depositFromGame settles community rewards on prior stake before top-up
 * - ETH residual refund goes to tx.origin (not msg.sender)
 *
 * Simulate:
 *   forge script script/DeployBSCDFXStarFactory19_3.s.sol:DeployBSCDFXStarFactory19_3Script \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 -vv
 *
 * Broadcast + verify:
 *   forge script script/DeployBSCDFXStarFactory19_3.s.sol:DeployBSCDFXStarFactory19_3Script \
 *     --rpc-url $BSC_RPC_URL --chain-id 56 --broadcast --legacy \
 *     --verify --etherscan-api-key $BSCSCAN_API_KEY -vv
 *
 * Env: PRIVATE_KEY_MAIN; optional DFX19_3_OWNER
 */
contract DeployBSCDFXStarFactory19_3Script is Script {
    address internal constant COMMUNITY_FACTORY = 0x5597e814399906095ecaA5769A40394F58E5E0Cf;
    address internal constant COMMITTEE = 0xe10F967DD356504EDB731612789D0D0f0ba2929f;
    // Prior World-bound factory (19.2); keep for reference, do not reuse for new pools.
    address internal constant PREVIOUS_FACTORY = 0xd436Bb8fF9BdF45b85aAC0dB038F14a9Ad14610B;

    function run() external returns (DFXStarScoreStakingFactory factory) {
        require(block.chainid == 56, "BSC mainnet only");
        require(COMMUNITY_FACTORY.code.length > 0, "CommunityFactory missing");
        require(COMMITTEE.code.length > 0, "Committee missing");

        uint256 key = vm.envUint("PRIVATE_KEY_MAIN");
        address deployer = vm.addr(key);
        address targetOwner = vm.envOr("DFX19_3_OWNER", deployer);

        console2.log("version", "19.3");
        console2.log("deployer", deployer);
        console2.log("targetOwner", targetOwner);
        console2.log("CommunityFactory", COMMUNITY_FACTORY);
        console2.log("Committee", COMMITTEE);
        console2.log("PreviousFactory(19.2)", PREVIOUS_FACTORY);
        console2.log("Committee.verifyContract(previous)", ICommittee(COMMITTEE).verifyContract(PREVIOUS_FACTORY));

        vm.startBroadcast(key);
        factory = new DFXStarScoreStakingFactory(COMMUNITY_FACTORY);
        if (targetOwner != deployer) {
            factory.transferOwnership(targetOwner);
        }
        vm.stopBroadcast();

        address template = factory.poolTemplate();
        require(factory.communityFactory() == COMMUNITY_FACTORY, "wrong communityFactory");
        require(template.code.length > 0, "pool template missing");
        require(template.code.length <= 24_576, "EIP-170 template");
        require(address(factory).code.length <= 24_576, "EIP-170 factory");

        console2.log("NEW DFXStarScoreStakingFactory", address(factory));
        console2.log("NEW DFXStarScoreStaking template", template);
        console2.log("factory.owner", factory.owner());
        console2.log("Committee.verifyContract(newFactory)", ICommittee(COMMITTEE).verifyContract(address(factory)));

        console2.log("NEXT: Committee owner must whitelist the new factory");
        console2.log("  target", COMMITTEE);
        console2.logBytes(abi.encodeWithSignature("adminAddContract(address)", address(factory)));
        if (targetOwner != deployer) {
            console2.log("NEXT: target owner accepts factory ownership");
            console2.log("  target", address(factory));
            console2.logBytes(abi.encodeWithSignature("acceptOwnership()"));
        }
        console2.log("NEXT: after World deploy, community.adminAddPool(..., abi.encode(world))");
        console2.log("Dry-run addresses are predictions until successful broadcast receipts exist.");
    }
}
