// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentSwapWrapper} from "../../src/helper/AgentSwapWrapper.sol";
import {ImportedTokenSwapWrapper} from "../../src/helper/ImportedTokenSwapWrapper.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";
import {IPShare} from "../../src/pump/IPShare.sol";

interface IAgentLiveHandle {
    function owner() external view returns (address);
    function minLen() external view returns (uint8);
    function maxLen() external view returns (uint8);
    function adminRegister(string calldata, address) external;
}

/// @notice Fixed-block BSC fork; live registry, IPShare, router and DEX bytecode without mocks.
/// @dev Handle registration and Safe execution are impersonated ONLY in the disposable fork.
contract AgentSwapWrapperDeploymentForkTest is Test {
    address constant ROUTER = 0x72dc4F38A7E4159e97d826a6ab594748C6b68f17;
    address constant FEES = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    address constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address constant HANDLE = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant SAFE = 0x871fb7006C5964B21695Ba20006021777A26146C;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    AgentSwapWrapper agent;
    address trader;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envUint("AGENT_WRAPPER_FORK_BLOCK");
        require(pin > 0, "Fixed fork block required");
        vm.createSelectFork(rpc, pin);
        assertEq(block.chainid, 56);
        assertEq(block.number, pin);
        agent = new AgentSwapWrapper(ROUTER, FEES, IPSHARE);
        trader = makeAddr("fresh-live-agent-wrapper-trader");
        vm.deal(trader, 1 ether);
    }

    function _register() private {
        IAgentLiveHandle registry = IAgentLiveHandle(HANDLE);
        uint256 length = registry.maxLen();
        require(length >= registry.minLen(), "Invalid Handle bounds");
        bytes memory handle = new bytes(length);
        for (uint256 i; i < length; ++i) {
            handle[i] = bytes1(uint8(97 + i % 26));
        }
        address owner = registry.owner();
        vm.prank(owner);
        registry.adminRegister(string(handle), trader);
    }

    function _v3Source() private pure returns (bytes memory) {
        return abi.encode(
            ImportedTokenSwapWrapper.V3Source(
                0x13f4EA83D0bd40E75C8222255bc855a974568Dd4,
                0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997,
                0x172fcD41E0913e95784454622d1c3724f546f849
            )
        );
    }

    function test_liveRegistryRejectsUnregisteredWallet() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(AgentSwapWrapper.HandleNotRegistered.selector, trader));
        agent.buyToken{value: 0.001 ether}(
            USDT, INutboxRouter.SourceType.V3_POOL, _v3Source(), 1, trader, block.timestamp + 60, address(0)
        );
        assertFalse(IPShare(payable(IPSHARE)).ipshareCreated(trader));
    }

    function test_liveV3BuySellCreatesShareAndSafeCanAcceptOwnership() public {
        _register();
        uint256 feeBefore = FEES.balance;
        vm.prank(trader);
        uint256 bought = agent.buyToken{value: 0.001 ether}(
            USDT, INutboxRouter.SourceType.V3_POOL, _v3Source(), 1, trader, block.timestamp + 60, address(0)
        );
        assertGt(bought, 0);
        assertEq(IERC20(USDT).balanceOf(trader), bought);
        IPShare shares = IPShare(payable(IPSHARE));
        assertTrue(shares.ipshareCreated(trader));
        assertEq(shares.ipshareSupply(trader), 10 ether);
        assertEq(shares.totalStakedIPshare(trader), 10 ether);
        assertEq(FEES.balance - feeBefore, 0.001 ether * 40 / 10_000);
        assertEq(agent.pendingNutboxInjection(USDT), 0);
        vm.startPrank(trader);
        IERC20(USDT).approve(address(agent), bought);
        uint256 received = agent.sellToken(
            USDT, INutboxRouter.SourceType.V3_POOL, _v3Source(), bought, 1, trader, block.timestamp + 60, address(0)
        );
        vm.stopPrank();
        assertGt(received, 0);
        assertEq(IERC20(USDT).balanceOf(address(agent)), 0);
        assertEq(address(agent).balance, 0);
        assertEq(shares.ipshareSupply(trader), 10 ether);
        agent.transferOwnership(SAFE);
        vm.prank(SAFE);
        agent.acceptOwnership();
        assertEq(agent.owner(), SAFE);
        assertEq(agent.pendingOwner(), address(0));
        assertEq(agent.operator(), address(0));
        vm.prank(SAFE);
        agent.setOperator(trader);
        assertEq(agent.operator(), trader);
    }
}
