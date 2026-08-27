// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SPCXBSwapExecutor} from "../../src/helper/SPCXBSwapExecutor.sol";

contract SPCXBSwapExecutorBSCForkTest is Test {
    address private constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address private constant IPSHARE = 0x95450AaD4Cc195e03BB4791B7f6f04aC6D9BA922;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address private constant EXISTING_IPSHARE_CREATOR = 0x16290796F2cD9f3ee97D3DD6bddfe9557c6d9b67;

    function test_bscDeepRoutePaysFeesAndDeliversSpcxb() public {
        require(block.chainid == 56, "BSC fork required");
        address feeAddress = makeAddr("feeAddress");
        address buyer = makeAddr("buyer");
        SPCXBSwapExecutor executor = new SPCXBSwapExecutor(SMART_ROUTER, IPSHARE, WBNB, USDT, SPCXB, feeAddress);
        bytes memory path = abi.encodePacked(WBNB, uint24(100), USDT, uint24(2_500), SPCXB);
        uint256 amountIn = 0.01 ether;
        uint256 balanceBefore = IERC20(SPCXB).balanceOf(buyer);
        vm.deal(buyer, amountIn);

        vm.prank(buyer);
        uint256 amountOut = executor.buySpcxb{value: amountIn}(path, 1, buyer, EXISTING_IPSHARE_CREATOR);

        assertGt(amountOut, 0);
        assertEq(IERC20(SPCXB).balanceOf(buyer) - balanceBefore, amountOut);
        assertEq(feeAddress.balance, amountIn * 20 / 10_000);
        assertEq(address(executor).balance, 0);
    }

    function test_bscReverseDeepRouteReturnsBnbAndPaysFees() public {
        require(block.chainid == 56, "BSC fork required");
        address feeAddress = makeAddr("sellFeeAddress");
        address seller = makeAddr("seller");
        SPCXBSwapExecutor executor = new SPCXBSwapExecutor(SMART_ROUTER, IPSHARE, WBNB, USDT, SPCXB, feeAddress);
        bytes memory path = abi.encodePacked(SPCXB, uint24(2_500), USDT, uint24(100), WBNB);
        uint256 amountIn = 0.01 ether;
        deal(SPCXB, seller, amountIn);
        vm.prank(seller);
        IERC20(SPCXB).approve(address(executor), amountIn);
        uint256 balanceBefore = seller.balance;

        vm.prank(seller);
        uint256 nativeOut = executor.sellSpcxb(path, amountIn, 1, seller, EXISTING_IPSHARE_CREATOR);

        assertGt(nativeOut, 0);
        assertEq(seller.balance - balanceBefore, nativeOut);
        assertGt(feeAddress.balance, 0);
        assertEq(IERC20(SPCXB).balanceOf(seller), 0);
        assertEq(address(executor).balance, 0);
    }
}
