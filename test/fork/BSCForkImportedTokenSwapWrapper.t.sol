// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ImportedTokenSwapWrapper} from "../../src/helper/ImportedTokenSwapWrapper.sol";
import {INutboxRouter} from "../../src/router/INutboxRouter.sol";

/**
 * @notice Exercises the wrapper against live Pancake V2 and V3 fee-on-transfer token pools.
 * @dev No block is pinned: every run forks the latest block returned by BSC_RPC_URL.
 *
 * Run:
 *   FOUNDRY_PROFILE=fork forge test --match-contract BSCForkImportedTokenSwapWrapper \
 *     --fork-url "$BSC_RPC_URL" -vv
 */
contract BSCForkImportedTokenSwapWrapper is Test {
    address private constant NUTBOX_ROUTER = 0x04e2d43bA38e3f3F0D0dab3A30D1B58BFE9B659f;
    address private constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address private constant PANCAKE_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address private constant NIULAI_QQQB_PAIR = 0x595d70977Dff3C841DF0bc0138Ce89f80C7C9423;
    address private constant NIULAI_USDT_V3_POOL = 0xab058332a7279F1e64162BE08F59ac0cd9601759;
    address private constant NIULAI = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;
    address private constant LAOWU_QQQB_PAIR = 0xcD53bB493Ed0dDe04CB54E0F1106Ec835c07bC47;
    address private constant LAOWU = 0x8b7abC1C0F2e6C0b76BC4FD0F7190f67d72E7777;
    address private constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address private constant FEE_RECEIVER = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;

    ImportedTokenSwapWrapper private wrapper;
    bool private forkReady;

    function setUp() public {
        if (block.chainid != 56) {
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        }
        if (block.chainid != 56 || NUTBOX_ROUTER.code.length == 0) return;

        forkReady = true;
        wrapper = new ImportedTokenSwapWrapper(NUTBOX_ROUTER, FEE_RECEIVER, IPSHARE);
    }

    modifier onlyBscFork() {
        if (!forkReady) vm.skip(true);
        _;
    }

    function test_fork_niulaiV2FeeOnTransferBuyAndSellUseActualBalances() external onlyBscFork {
        _assertV2FeeOnTransferRoundTrip(NIULAI, NIULAI_QQQB_PAIR, "niulaiTaxTokenTrader");
    }

    function test_fork_laowuV2FeeOnTransferBuyAndSellUseActualBalances() external onlyBscFork {
        _assertV2FeeOnTransferRoundTrip(LAOWU, LAOWU_QQQB_PAIR, "laowuTaxTokenTrader");
    }

    function test_fork_niulaiV3FeeOnTransferBuyUsesFinalRecipientBalance() external onlyBscFork {
        address trader = makeAddr("niulaiV3TaxTokenTrader");
        bytes memory sourceData = abi.encode(
            ImportedTokenSwapWrapper.V3Source({
                router: PANCAKE_V3_ROUTER, quoter: PANCAKE_V3_QUOTER, pool: NIULAI_USDT_V3_POOL
            })
        );
        uint256 nativeAmountIn = 0.001 ether;
        uint256 quotedTokenOut = wrapper.quoteBuy(NIULAI, INutboxRouter.SourceType.V3_POOL, sourceData, nativeAmountIn);

        vm.deal(trader, nativeAmountIn);
        vm.prank(trader);
        uint256 boughtAmount = wrapper.buyToken{value: nativeAmountIn}(
            NIULAI, INutboxRouter.SourceType.V3_POOL, sourceData, 1, trader, block.timestamp + 5 minutes, FEE_RECEIVER
        );

        assertGt(boughtAmount, 0, "V3 tax token buy returned zero");
        assertEq(IERC20(NIULAI).balanceOf(trader), boughtAmount, "V3 buy return is not final recipient amount");
        assertLt(boughtAmount, quotedTokenOut, "V3 tax was not reflected in actual buy output");
        assertEq(IERC20(NIULAI).balanceOf(address(wrapper)), 0, "wrapper retained V3 bought tokens");
    }

    function _assertV2FeeOnTransferRoundTrip(address token, address pair, string memory traderLabel) private {
        address trader = makeAddr(traderLabel);
        bytes memory sourceData = abi.encode(ImportedTokenSwapWrapper.V2Source({router: PANCAKE_V2_ROUTER, pair: pair}));
        uint256 nativeAmountIn = 0.001 ether;
        uint256 quotedTokenOut = wrapper.quoteBuy(token, INutboxRouter.SourceType.V2_PAIR, sourceData, nativeAmountIn);

        vm.deal(trader, nativeAmountIn);
        vm.prank(trader);
        uint256 boughtAmount = wrapper.buyToken{value: nativeAmountIn}(
            token, INutboxRouter.SourceType.V2_PAIR, sourceData, 1, trader, block.timestamp + 5 minutes, FEE_RECEIVER
        );

        assertGt(boughtAmount, 0, "tax token buy returned zero");
        assertEq(IERC20(token).balanceOf(trader), boughtAmount, "buy return is not actual recipient amount");
        assertLt(boughtAmount, quotedTokenOut, "live tax was not reflected in actual buy output");
        assertEq(IERC20(token).balanceOf(address(wrapper)), 0, "wrapper retained bought tokens");

        vm.warp(block.timestamp + 1);
        vm.startPrank(trader);
        IERC20(token).approve(address(wrapper), boughtAmount);
        uint256 nativeOut = wrapper.sellToken(
            token,
            INutboxRouter.SourceType.V2_PAIR,
            sourceData,
            boughtAmount,
            1,
            trader,
            block.timestamp + 5 minutes,
            FEE_RECEIVER
        );
        vm.stopPrank();

        assertGt(nativeOut, 0, "tax token sell returned zero");
        assertEq(trader.balance, nativeOut, "sell return is not actual native amount delivered");
        assertEq(IERC20(token).balanceOf(address(wrapper)), 0, "wrapper retained sold tokens");
    }
}
