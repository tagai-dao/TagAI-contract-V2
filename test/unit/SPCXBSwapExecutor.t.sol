// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {SPCXBSwapExecutor, ISPCXBPancakeV3SmartRouter} from "../../src/helper/SPCXBSwapExecutor.sol";

contract SPCXBExecutorTokenMock {
    function marker() external pure returns (bool) {
        return true;
    }
}

contract SPCXBExecutorIPShareMock {
    mapping(address => bool) public ipshareCreated;
    mapping(address => uint256) public captured;
    bool public shouldRevert;

    function setCreated(address subject, bool created) external {
        ipshareCreated[subject] = created;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function valueCapture(address subject) external payable {
        if (shouldRevert) revert("capture failed");
        captured[subject] += msg.value;
    }
}

contract SPCXBExecutorRouterMock {
    bytes public lastPath;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;
    uint256 public output = 5 ether;
    bool public shouldRevert;

    function setOutput(uint256 value) external {
        output = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function exactInput(ISPCXBPancakeV3SmartRouter.ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        if (shouldRevert) revert("swap failed");
        require(msg.value == params.amountIn, "value mismatch");
        lastPath = params.path;
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;
        return output;
    }
}

contract SPCXBSwapExecutorTest is Test {
    SPCXBExecutorIPShareMock private ipshare;
    SPCXBExecutorRouterMock private router;
    SPCXBExecutorTokenMock private wbnb;
    SPCXBExecutorTokenMock private usdt;
    SPCXBExecutorTokenMock private spcxb;
    SPCXBSwapExecutor private executor;

    address private feeAddress = makeAddr("feeAddress");
    address private creator = makeAddr("creator");
    address private buyer = makeAddr("buyer");
    address private recipient = makeAddr("recipient");

    function setUp() public {
        ipshare = new SPCXBExecutorIPShareMock();
        router = new SPCXBExecutorRouterMock();
        wbnb = new SPCXBExecutorTokenMock();
        usdt = new SPCXBExecutorTokenMock();
        spcxb = new SPCXBExecutorTokenMock();
        executor = new SPCXBSwapExecutor(
            address(router), address(ipshare), address(wbnb), address(usdt), address(spcxb), feeAddress
        );
        ipshare.setCreated(creator, true);
        vm.deal(buyer, 10 ether);
    }

    function test_buyPreservesCreatorAndTagAIFeesThenUsesDeepRoute() public {
        bytes memory path = _path(100);
        vm.prank(buyer);
        uint256 amountOut = executor.buySpcxb{value: 1 ether}(path, 4 ether, recipient, creator);

        assertEq(amountOut, 5 ether);
        assertEq(ipshare.captured(creator), 0.002 ether);
        assertEq(feeAddress.balance, 0.002 ether);
        assertEq(address(router).balance, 0.996 ether);
        assertEq(router.lastPath(), path);
        assertEq(router.lastRecipient(), recipient);
        assertEq(router.lastAmountIn(), 0.996 ether);
        assertEq(router.lastAmountOutMinimum(), 4 ether);
    }

    function test_creatorWithoutIPShareReceivesNativeFee() public {
        address nativeCreator = makeAddr("nativeCreator");
        vm.prank(buyer);
        executor.buySpcxb{value: 1 ether}(_path(100), 0, recipient, nativeCreator);

        assertEq(nativeCreator.balance, 0.002 ether);
        assertEq(ipshare.captured(nativeCreator), 0);
    }

    function test_rejectsAnyRouteOutsideWbnbUsdtSpcxb() public {
        bytes memory wrongPath =
            abi.encodePacked(address(wbnb), uint24(100), address(spcxb), uint24(2500), address(usdt));
        vm.prank(buyer);
        vm.expectRevert(SPCXBSwapExecutor.InvalidRoute.selector);
        executor.buySpcxb{value: 1 ether}(wrongPath, 0, recipient, creator);
    }

    function test_rejectsUnsupportedFeeTier() public {
        vm.prank(buyer);
        vm.expectRevert(SPCXBSwapExecutor.InvalidRoute.selector);
        executor.buySpcxb{value: 1 ether}(_path(3_000), 0, recipient, creator);
    }

    function test_swapFailureRollsBackBothFeeTransfers() public {
        router.setShouldRevert(true);
        vm.prank(buyer);
        vm.expectRevert("swap failed");
        executor.buySpcxb{value: 1 ether}(_path(100), 0, recipient, creator);

        assertEq(ipshare.captured(creator), 0);
        assertEq(feeAddress.balance, 0);
    }

    function test_ownerCanUpdateFeeRatios() public {
        executor.setFeeRatios(30, 40);
        (uint256 swapAmount, uint256 creatorFee, uint256 tagaiFee) = executor.previewFees(1 ether);
        assertEq(creatorFee, 0.003 ether);
        assertEq(tagaiFee, 0.004 ether);
        assertEq(swapAmount, 0.993 ether);
    }

    function test_nonOwnerCannotUpdateFeeRatios() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        executor.setFeeRatios(30, 40);
    }

    function _path(uint24 firstHopFee) private view returns (bytes memory) {
        return abi.encodePacked(address(wbnb), firstHopFee, address(usdt), uint24(2_500), address(spcxb));
    }
}
