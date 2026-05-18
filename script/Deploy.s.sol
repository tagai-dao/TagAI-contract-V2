// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/nutbox/Committee.sol";
import "../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../src/pump/IPShare.sol";
import "../src/pump/Pump.sol";
import "../src/hook/TagAISwapHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

/**
 * @title Deploy
 * @notice Local anvil full deployment script for testing.
 * @dev Run: forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Deploys ALL contracts (real Nutbox stack + Pump + Hook) for local integration testing.
 *
 * Note: CommunityFactory and SocialCurationFactory are deployed via vm.getCode
 * to avoid ERC20 name collision between OpenZeppelin (used by MintableERC20) and
 * Solady (used by Token.sol) in the same compilation unit.
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ─── Phase 1: Deploy Committee ───
        Committee committee = new Committee(payable(deployer));
        console.log("Committee:", address(committee));

        // ─── Phase 2: Deploy CommunityFactory ───
        // Deployed via low-level create to avoid OZ ERC20 / Solady ERC20 name collision
        address communityFactory = _deployCommunityFactory(address(committee));
        console.log("CommunityFactory:", communityFactory);

        // ─── Phase 3: Deploy HourlyTickCalculator ───
        HourlyTickCalculator calculator = new HourlyTickCalculator(communityFactory);
        console.log("HourlyTickCalculator:", address(calculator));

        // ─── Phase 4: Deploy SocialCurationFactory ───
        address scf = _deploySocialCurationFactory(communityFactory, deployer);
        console.log("SocialCurationFactory:", scf);

        // ─── Phase 5: Whitelist Calculator + SCF in Committee ───
        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);
        console.log("Committee: whitelisted Calculator + SCF");

        // ─── Phase 6: Deploy IPShare ───
        IPShare ipshare = new IPShare(deployer);
        console.log("IPShare:", address(ipshare));

        // ─── Phase 7: Deploy Pump ───
        Pump pump = new Pump(address(ipshare), deployer);
        console.log("Pump:", address(pump));

        // ─── Phase 8: Deploy TagAISwapHook ───
        // Note: In production, need to mine CREATE2 salt for correct hooks bitmap address.
        // For local testing, deploy normally (hook bitmap validation is skipped in mocks).
        TagAISwapHook hook = new TagAISwapHook(
            ICLPoolManager(address(0)), // placeholder for local testing
            IVault(address(0)),          // placeholder for local testing
            address(pump)
        );
        console.log("TagAISwapHook:", address(hook));

        // ─── Phase 9: Configure Pump ───
        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(
            communityFactory,
            address(calculator),
            scf,
            address(committee)
        );
        console.log("Pump: configured with Hook, Calculator, and Nutbox stack");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Committee:", address(committee));
        console.log("CommunityFactory:", communityFactory);
        console.log("HourlyTickCalculator:", address(calculator));
        console.log("SocialCurationFactory:", scf);
        console.log("IPShare:", address(ipshare));
        console.log("Pump:", address(pump));
        console.log("TagAISwapHook:", address(hook));
    }

    /// @dev Deploy CommunityFactory using vm.getCode to avoid ERC20 collision
    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "CommunityFactory deployment failed");
        return deployed;
    }

    /// @dev Deploy SocialCurationFactory using vm.getCode to avoid ERC20 collision
    function _deploySocialCurationFactory(address _communityFactory, address _claimSigner) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_communityFactory, _claimSigner)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "SocialCurationFactory deployment failed");
        return deployed;
    }
}
