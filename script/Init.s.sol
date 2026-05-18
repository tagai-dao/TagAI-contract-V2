// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/nutbox/Committee.sol";
import "../src/pump/IPShare.sol";
import "../src/interfaces/ICommunity.sol";
import "../src/interfaces/IHourlyTickCalculator.sol";

/**
 * @title Init
 * @notice Local initialization script - run after Deploy.s.sol
 * @dev Run:
 *   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *   forge script script/Init.s.sol:Init --rpc-url http://localhost:8545 --broadcast
 *
 * Steps:
 * 1. Read deployed addresses from deployments/<chainid>/addresses.json
 * 2. Deploy DFXStarScoreStakingFactory and whitelist in Committee
 * 3. Create a test token via Pump.createToken (creates Community + SocialCuration pool)
 * 4. Add DFXStarScoreStaking pool to Community with 100% reward ratio
 * 5. Write initialized addresses to deployments/<chainid>/initialized.json
 *
 * Note: DFXStarScoreStakingFactory is deployed via vm.getCode to avoid ERC20
 * name collision between OpenZeppelin (used by DFXStarScoreStaking) and
 * Solady (used by Token.sol) in the same compilation unit.
 */
contract Init is Script {
    // Config
    string constant TICK = "TEST";
    bytes32 constant SALT = bytes32(uint256(1));

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read deployed addresses
        string memory addressesJson = _readAddresses();
        address committeeAddr = vm.parseJsonAddress(addressesJson, ".Committee");
        address communityFactoryAddr = vm.parseJsonAddress(addressesJson, ".CommunityFactory");
        address pumpAddr = vm.parseJsonAddress(addressesJson, ".Pump");
        address ipshareAddr = vm.parseJsonAddress(addressesJson, ".IPShare");
        address calculatorAddr = vm.parseJsonAddress(addressesJson, ".HourlyTickCalculator");

        address dfxFactoryAddr = vm.parseJsonAddress(addressesJson, ".DFXStarScoreStakingFactory");

        IPShare ipshare = IPShare(payable(ipshareAddr));

        vm.startBroadcast(deployerPrivateKey);

        // ─── Step 2: Create test token via Pump (creates Community + SocialCuration) ───
        // Pump.createToken requires:
        // - IPShare created for msg.sender (or pays createFee)
        // - Nutbox fees (0 in local)
        // - Pump createFee (0.005 ETH default)

        // Ensure IPShare is created for deployer (free in local since createFee=0)
        if (!ipshare.ipshareCreated(deployer)) {
            ipshare.createShare(deployer);
            console.log("IPShare created for deployer");
        }

        // Create token via Pump.createToken
        // Fee breakdown: createFee(0.005) + ipshareCreateFee(0) + nutboxFees(0) = 0.005 ETH
        address token = _createToken(pumpAddr, TICK, SALT, 0.005 ether);
        console.log("Token:", token);

        // Get Community address from Token (Token.nutboxCommunity is public)
        address community;
        {
            (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("nutboxCommunity()"));
            require(success, "Failed to get nutboxCommunity");
            community = abi.decode(data, (address));
        }
        console.log("Community:", community);

        // Get SocialCuration pool
        address socialPool;
        {
            (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("nutboxSocialPool()"));
            require(success, "Failed to get nutboxSocialPool");
            socialPool = abi.decode(data, (address));
        }
        console.log("SocialCuration Pool:", socialPool);

        // ─── Step 3: Add DFXStarScoreStaking pool with 100% reward ───
        // Current: SocialCuration has 100% (ratios=[10000])
        // After: SocialCuration 0%, DFXStarScoreStaking 100% (ratios=[0, 10000])

        // First add DFXStarScoreStaking pool (requires settingsFee=0 in local)
        uint16[] memory ratios = new uint16[](2);
        ratios[0] = 0;      // SocialCuration gets 0%
        ratios[1] = 10000;  // DFXStarScoreStaking gets 100%

        ICommunity(community).adminAddPool{value: 0}(
            "DFXStar Score Staking",
            ratios,
            dfxFactoryAddr,
            bytes("")
        );

        // Get DFXStarScoreStaking pool address (index 1)
        address dfxPool = ICommunity(community).activedPools(1);
        console.log("DFXStarScoreStaking Pool:", dfxPool);

        // ─── Step 4: Configure DFXStarScoreStakingFactory admin ───
        // Add deployer as admin so they can call depositFromGame
        _addAdmin(dfxFactoryAddr, deployer);
        console.log("DFXStarScoreStakingFactory: added deployer as admin");

        vm.stopBroadcast();

        // ─── Write initialized addresses ───
        _writeInitialized(
            dfxFactoryAddr,
            token,
            community,
            socialPool,
            dfxPool,
            calculatorAddr,
            deployer
        );

        console.log("");
        console.log("=== Initialization Summary ===");
        console.log("DFXStarScoreStakingFactory:", dfxFactoryAddr);
        console.log("Token:", token);
        console.log("Community:", community);
        console.log("SocialCuration Pool:", socialPool);
        console.log("DFXStarScoreStaking Pool:", dfxPool);
        console.log("HourlyTickCalculator:", calculatorAddr);
    }

    function _createToken(address pump, string memory tick, bytes32 salt, uint256 value) internal returns (address) {
        (bool success, bytes memory data) = pump.call{value: value}(
            abi.encodeWithSignature("createToken(string,bytes32)", tick, salt)
        );
        require(success, "createToken failed");
        return abi.decode(data, (address));
    }

    function _addAdmin(address factory, address admin) internal {
        (bool success, ) = factory.call(abi.encodeWithSignature("addAdmin(address)", admin));
        require(success, "addAdmin failed");
    }

    function _readAddresses() internal returns (string memory) {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory path = string.concat("deployments/", chainIdStr, "/addresses.json");
        return vm.readFile(path);
    }

    function _writeInitialized(
        address dfxFactory,
        address token,
        address community,
        address socialPool,
        address dfxPool,
        address calculator,
        address deployer
    ) internal {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory dir = string.concat("deployments/", chainIdStr);
        string memory path = string.concat(dir, "/initialized.json");

        string memory json = string.concat(
            "{\n",
            '  "chainId": ', chainIdStr, ',\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "DFXStarScoreStakingFactory": "', vm.toString(dfxFactory), '",\n',
            '  "Token": "', vm.toString(token), '",\n',
            '  "Community": "', vm.toString(community), '",\n',
            '  "SocialCurationPool": "', vm.toString(socialPool), '",\n',
            '  "DFXStarScoreStakingPool": "', vm.toString(dfxPool), '",\n',
            '  "HourlyTickCalculator": "', vm.toString(calculator), '"\n',
            "}\n"
        );

        try vm.createDir(dir, true) {} catch {}
        vm.writeFile(path, json);
        console.log("Initialized addresses written to:", path);
    }
}
