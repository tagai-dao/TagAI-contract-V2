// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/helper/ImportHelperV3.sol";
import "../../src/helper/AgentSwapWrapper.sol";

contract ImportV3ForkToken is ERC20 {
    constructor() ERC20("Import V3 Fork", "IV3") {}
}

/// @dev Local fixed-block fork only. Safe impersonation never creates a signature or mainnet tx.
contract BSCImportHelperV3ForkTest is Test {
    address private constant OLD = 0x40BACB12D79dadf045c21C999b74484816F746F7;
    address private constant SAFE = 0x871fb7006C5964B21695Ba20006021777A26146C;
    address private constant MANAGER = 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611;
    ImportedTokenSwapWrapper private ordinary;
    AgentSwapWrapper private agent;
    ImportHelperV3 private helper;
    ImportV3ForkToken private token;
    address private creator;
    uint256 private fee;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("IMPORT_HELPER_V3_FORK_BLOCK"));
        ImportHelperV2 old = ImportHelperV2(OLD);
        ordinary = ImportedTokenSwapWrapper(payable(address(old.swapWrapper())));
        agent = AgentSwapWrapper(payable(0x3F7146D3D234Ed4C2021DE1A5B14da8754e6C577));
        address deployed = vm.envOr("IMPORT_HELPER_V3_ADDRESS", address(0));
        helper = deployed == address(0)
            ? new ImportHelperV3(
                old.communityFactory(),
                old.tradeCurationFactory(),
                old.committee(),
                old.hourlyTickCalculator(),
                address(ordinary),
                address(agent),
                MANAGER
            )
            : ImportHelperV3(deployed);
        token = new ImportV3ForkToken();
        creator = makeAddr("forkImporter");
        fee = ICommittee(helper.committee()).getCreateCommunityFee()
            + ICommittee(helper.committee()).getCommunitySettingsFee();
        vm.deal(creator, fee + 1 ether);
    }

    function test_realSafeActivationAndRealCommunityDualRegistrationThenWalletFeeManagement() public {
        assertEq(helper.owner(), SAFE);
        assertEq(helper.managementOperator(), MANAGER);
        vm.startPrank(SAFE);
        agent.setOperator(address(helper));
        ordinary.setRegistrar(address(helper));
        vm.stopPrank();
        vm.prank(creator);
        (address community, address pool) = helper.createCommunityAndPool{value: fee}(address(token), address(0));
        (bool normalRegistered, address normalCommunity, address normalCreator) =
            ordinary.getImportedMarket(address(token));
        (bool agentRegistered, address agentCommunity, address agentCreator) = agent.getImportedMarket(address(token));
        assertTrue(normalRegistered && agentRegistered);
        assertEq(normalCommunity, community);
        assertEq(agentCommunity, community);
        assertEq(normalCreator, creator);
        assertEq(agentCreator, creator);
        assertEq(Community(payable(community)).owner(), creator);
        assertEq(Community(payable(community)).activedPools(0), pool);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 0);
        vm.prank(MANAGER);
        helper.setTokenNutboxFee(address(token), 20);
        assertEq(agent.tokenNutboxFeeBps(address(token)), 20);
    }

    function test_operatorOnlyActivationDoesNotSilentlyProduceAPartialImport() public {
        address oldRegistrar = ordinary.registrar();
        vm.prank(SAFE);
        agent.setOperator(address(helper));
        assertEq(ordinary.registrar(), oldRegistrar);
        uint256 beforeBalance = creator.balance;
        vm.prank(creator);
        vm.expectRevert(ImportedTokenSwapWrapper.UnauthorizedRegistrar.selector);
        helper.createCommunityAndPool{value: fee}(address(token), address(0));
        (bool registered,,) = agent.getImportedMarket(address(token));
        assertFalse(registered);
        assertEq(creator.balance, beforeBalance);
    }
}
