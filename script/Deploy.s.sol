// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/nutbox/Committee.sol";
import "../src/nutbox/calculators/HourlyTickCalculator.sol";
import "../src/pump/IPShare.sol";
import "../src/pump/Pump.sol";
import "../src/hook/TagAISwapHook.sol";
import "../src/mocks/MockCLPoolManager.sol";
import "../src/mocks/MockVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

/**
 * @title Deploy
 * @notice Local anvil full deployment script for testing.
 * @dev Run:
 *   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *   forge script script/Deploy.s.sol:Deploy --rpc-url http://localhost:8545 --broadcast
 *
 * Deploys the FULL stack (real Nutbox + Pump + Hook + DEX mocks) for local testing.
 *
 * Note: CommunityFactory and SocialCurationFactory are deployed via vm.getCode
 * to avoid ERC20 name collision between OpenZeppelin (used by MintableERC20) and
 * Solady (used by Token.sol) in the same compilation unit.
 *
 * After deployment, addresses are written to deployments/<chainid>/addresses.json
 * for frontend consumption.
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ─── Phase 1: Deploy Committee ───
        Committee committee = new Committee(payable(deployer));
        // Set fees to 0 for local testing
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);
        console.log("Committee:", address(committee));

        // ─── Phase 2: Deploy CommunityFactory ───
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

        // ─── Phase 5.5: Deploy DFXStarScoreStakingFactory ───
        address dfxFactory = _deployDFXStarScoreStakingFactory(communityFactory);
        committee.adminAddContract(dfxFactory);
        console.log("DFXStarScoreStakingFactory:", dfxFactory);

        // ─── Phase 6: Deploy IPShare ───
        IPShare ipshare = new IPShare(deployer);
        // Enable trading immediately for local testing
        ipshare.adminStartTrade();
        console.log("IPShare:", address(ipshare));

        // ─── Phase 7: Deploy DEX Mocks (PCS V4 substitute) ───
        MockCLPoolManager mockPoolManager = new MockCLPoolManager();
        console.log("MockCLPoolManager:", address(mockPoolManager));
        MockVault mockVault = new MockVault();
        console.log("MockVault:", address(mockVault));

        // ─── Phase 8: Deploy Pump ───
        Pump pump = new Pump(address(ipshare), deployer);
        pump.adminSetPoolManager(address(mockPoolManager));
        pump.adminSetVault(address(mockVault));
        console.log("Pump:", address(pump));

        // ─── Phase 9: Deploy TagAISwapHook ───
        TagAISwapHook hook = new TagAISwapHook(
            ICLPoolManager(address(mockPoolManager)),
            IVault(address(mockVault)),
            address(pump)
        );
        console.log("TagAISwapHook:", address(hook));

        // ─── Phase 10: Configure Pump ───
        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));
        console.log("Pump: configured with Hook, Calculator, Nutbox stack, and DEX mocks");

        vm.stopBroadcast();

        // ─── Write addresses to deployments/<chainid>/addresses.json ───
        _writeAddresses(
            address(committee),
            communityFactory,
            address(calculator),
            scf,
            dfxFactory,
            address(ipshare),
            address(mockPoolManager),
            address(mockVault),
            address(pump),
            address(hook),
            deployer
        );

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Committee:", address(committee));
        console.log("CommunityFactory:", communityFactory);
        console.log("HourlyTickCalculator:", address(calculator));
        console.log("SocialCurationFactory:", scf);
        console.log("DFXStarScoreStakingFactory:", dfxFactory);
        console.log("IPShare:", address(ipshare));
        console.log("MockCLPoolManager:", address(mockPoolManager));
        console.log("MockVault:", address(mockVault));
        console.log("Pump:", address(pump));
        console.log("TagAISwapHook:", address(hook));
    }

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

    function _deployDFXStarScoreStakingFactory(address _communityFactory) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("DFXStarScoreStakingFactory.sol:DFXStarScoreStakingFactory"),
            abi.encode(_communityFactory)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "DFXStarScoreStakingFactory deployment failed");
        return deployed;
    }

    function _writeAddresses(
        address committee,
        address communityFactory,
        address calculator,
        address scf,
        address dfxFactory,
        address ipshare,
        address mockPoolManager,
        address mockVault,
        address pump,
        address hook,
        address deployer
    ) internal {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory dir = string.concat("deployments/", chainIdStr);
        string memory path = string.concat(dir, "/addresses.json");

        // Build JSON manually for clarity & version-control friendliness
        string memory json = string.concat(
            "{\n",
            '  "chainId": ', chainIdStr, ',\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "Committee": "', vm.toString(committee), '",\n',
            '  "CommunityFactory": "', vm.toString(communityFactory), '",\n',
            '  "HourlyTickCalculator": "', vm.toString(calculator), '",\n',
            '  "SocialCurationFactory": "', vm.toString(scf), '",\n',
            '  "DFXStarScoreStakingFactory": "', vm.toString(dfxFactory), '",\n',
            '  "IPShare": "', vm.toString(ipshare), '",\n',
            '  "MockCLPoolManager": "', vm.toString(mockPoolManager), '",\n',
            '  "MockVault": "', vm.toString(mockVault), '",\n',
            '  "Pump": "', vm.toString(pump), '",\n',
            '  "TagAISwapHook": "', vm.toString(hook), '"\n',
            "}\n"
        );

        // Ensure dir exists by trying to create it (safe to ignore failure)
        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Addresses written to:", path);
    }
}
