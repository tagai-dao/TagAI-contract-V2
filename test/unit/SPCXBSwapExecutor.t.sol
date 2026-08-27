// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SPCXBSwapExecutor, ISPCXBPancakeV3SmartRouter} from "../../src/helper/SPCXBSwapExecutor.sol";

contract SPCXBExecutorTokenMock is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract SPCXBExecutorWrappedNativeMock is SPCXBExecutorTokenMock {
    receive() external payable {}

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
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
    SPCXBExecutorTokenMock public sellToken;
    SPCXBExecutorTokenMock public wrappedNative;

    function setSellTokens(SPCXBExecutorTokenMock sellToken_, SPCXBExecutorTokenMock wrappedNative_) external {
        sellToken = sellToken_;
        wrappedNative = wrappedNative_;
    }

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
        if (msg.value == 0) {
            require(sellToken.transferFrom(msg.sender, address(this), params.amountIn), "transfer failed");
            wrappedNative.mint(params.recipient, output);
        } else {
            require(msg.value == params.amountIn, "value mismatch");
        }
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
    SPCXBExecutorWrappedNativeMock private wbnb;
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
        wbnb = new SPCXBExecutorWrappedNativeMock();
        usdt = new SPCXBExecutorTokenMock();
        spcxb = new SPCXBExecutorTokenMock();
        executor = new SPCXBSwapExecutor(
            address(router), address(ipshare), address(wbnb), address(usdt), address(spcxb), feeAddress
        );
        router.setSellTokens(spcxb, wbnb);
        ipshare.setCreated(creator, true);
        vm.deal(buyer, 10 ether);
        vm.deal(address(wbnb), 10 ether);
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

    function test_sellUsesReverseDeepRouteAndPreservesBothFees() public {
        router.setOutput(1 ether);
        spcxb.mint(buyer, 10 ether);
        vm.prank(buyer);
        spcxb.approve(address(executor), 10 ether);

        vm.prank(buyer);
        uint256 nativeOut = executor.sellSpcxb(_sellPath(100), 10 ether, 0.99 ether, recipient, creator);

        assertEq(nativeOut, 0.996 ether);
        assertEq(recipient.balance, 0.996 ether);
        assertEq(ipshare.captured(creator), 0.002 ether);
        assertEq(feeAddress.balance, 0.002 ether);
        assertEq(spcxb.balanceOf(address(router)), 10 ether);
        assertEq(address(executor).balance, 0);
        assertEq(router.lastPath(), _sellPath(100));
        assertEq(router.lastRecipient(), address(executor));
        assertEq(router.lastAmountIn(), 10 ether);
        assertEq(router.lastAmountOutMinimum(), 1);
    }

    function test_sellRejectsForwardBuyPath() public {
        spcxb.mint(buyer, 1 ether);
        vm.prank(buyer);
        spcxb.approve(address(executor), 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SPCXBSwapExecutor.InvalidRoute.selector);
        executor.sellSpcxb(_path(100), 1 ether, 0, recipient, creator);
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

    function _sellPath(uint24 secondHopFee) private view returns (bytes memory) {
        return abi.encodePacked(address(spcxb), uint24(2_500), address(usdt), secondHopFee, address(wbnb));
    }
}
