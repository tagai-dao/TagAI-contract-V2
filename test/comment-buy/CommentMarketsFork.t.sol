// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommentBuyAdapter} from "../../src/helper/CommentBuyAdapter.sol";
import {CommentTradeVault} from "../../src/helper/CommentTradeVault.sol";
import {TagAITradeRouter} from "../../src/router/TagAITradeRouter.sol";

interface ICommentForkFactory { function getPair(address, address) external view returns (address); }

/// Read-only mainnet fork. Never signs or broadcasts real transactions.
/// Run with BSC_RPC_URL and FOUNDRY_PROFILE=fork; otherwise explicitly skipped.
contract CommentMarketsForkTest is Test {
    address constant ROUTER = 0x7D5480C10A98b0Feb4e5fA77aF3F01aE3a5E86F4;
    address constant HOOK = 0xaC29EaEb5764A83f7Ed03240EA2aF54018210cc1;
    address constant IMPORTED = 0xDfFc699FB095a693708E3c15e6F0a224cbbCc98F;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant SUBJECT = 0xf0a27ec9bb8AC28007cB474fC1ea0A9396fe6991;
    address constant CYBER = 0xbc59192DfaD0eF94db82B6dD1a2Dd97e040D3333;
    bool ready;
    CommentBuyAdapter adapter;
    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == 56);
        adapter = new CommentBuyAdapter(ROUTER, HOOK, IMPORTED);
        vm.deal(address(this), 1 ether);
        ready = true;
    }
    modifier onFork() { if (!ready) vm.skip(true); _; }
    function _buy(address token, uint8 kind, bytes memory plan) internal {
        (uint256 gross,,,) = adapter.quoteInput(token, 0.0001 ether, kind);
        address recipient = makeAddr("comment-buy-recipient");
        CommentTradeVault vault = new CommentTradeVault(address(this), makeAddr("platform"), address(adapter));
        vault.setPaused(false);
        vault.setMinTradeInterval(0);
        vm.deal(recipient, 1 ether);
        vm.startPrank(recipient);
        vault.authorize{value: 0.1 ether}(0.1 ether, 0.01 ether, 0.05 ether, 0, 100, block.timestamp + 1 days);
        vm.stopPrank();
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        // Quote the exact adapter from the vault context; rollback quote effects before execution.
        uint256 snapshot = vm.snapshotState();
        vm.deal(address(vault), address(vault).balance + gross);
        vm.prank(address(vault));
        uint256 quote = adapter.buy{value: gross}(token, recipient, SUBJECT, 1, block.timestamp + 60, kind, plan);
        vm.revertToState(snapshot);
        CommentTradeVault.Order memory order = CommentTradeVault.Order(bytes32(uint256(1)), recipient, token, SUBJECT,
            0.0001 ether, 0, 0, (quote * 9900 + 9999) / 10000, block.timestamp + 60, 1, quote, gross - 0.0001 ether, kind);
        uint256 output = vault.execute(order, plan);
        assertGt(output, 0); assertEq(IERC20(token).balanceOf(recipient) - beforeBalance, output);
        assertEq(IERC20(token).balanceOf(address(adapter)), 0);
        assertEq(vault.balanceOf(recipient), 0.1 ether - gross);
        vm.expectRevert(CommentTradeVault.Invalid.selector); vault.execute(order, plan);
    }
    function _externalV2(address token) internal {
        address pair = ICommentForkFactory(V2_FACTORY).getPair(WBNB, token);
        _buy(token, 2, abi.encode(uint8(0), abi.encode(V2_ROUTER, pair)));
    }
    function testForkBUIDL() public onFork { _externalV2(0x32ef878D527d860339818571E8DA17005110f04E); }
    function testForkTTAI() public onFork { _externalV2(0x8e11E90B463bf521382E2B88539F053270a3848c); }
    function testForkTagClaw() public onFork { _externalV2(0xe7324F2987aCd88Ee7286EB9DAb0EE926ad36a68); }
    function testForkCyberCab() public onFork {
        (uint256 gross,,,) = adapter.quoteInput(CYBER, 0.0001 ether, 1);
        TagAITradeRouter.Leg[] memory legs = new TagAITradeRouter.Leg[](1);
        legs[0] = TagAITradeRouter.Leg(0, gross, 0, 1, TagAITradeRouter(payable(ROUTER)).routeHash(address(0), CYBER));
        _buy(CYBER, 1, abi.encode(legs));
    }
    function testForkImportedV2NonNativeQuote() public onFork {
        address token = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
        _buy(token, 2, abi.encode(uint8(0), abi.encode(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E), address(0x595d70977Dff3C841DF0bc0138Ce89f80C7C9423))));
    }
    function testForkImportedV3UsdtQuote() public onFork {
        address token = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
        _buy(token, 2, abi.encode(uint8(1), abi.encode(
            address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4), address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997),
            address(0xab058332a7279F1e64162BE08F59ac0cd9601759))));
    }
}
