// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/helper/TagAISwapWrapper.sol";
import "../../src/interfaces/IImportHelper.sol";
import "../../src/interfaces/IIPShare.sol";
import "../../src/interfaces/IUniswapV2Router02.sol";
import "../../src/interfaces/IUniswapV3SwapRouter.sol";
import "../../src/interfaces/IWETH.sol";

/// @dev Minimal ImportHelper mock for sellsman fallback.
contract MockImportHelper is IImportHelper {
    mapping(address => address) public importerOf;

    function setImporter(address token, address importer) external {
        importerOf[token] = importer;
    }
}

/// @dev Minimal IPShare mock — only ipshareCreated matters for resolution.
contract MockIPShare {
    mapping(address => bool) public created;

    function setCreated(address subject, bool v) external {
        created[subject] = v;
    }

    function ipshareCreated(address subject) external view returns (bool) {
        return created[subject];
    }
}

/// @dev Captures ETH sent into swapExactETHForTokens (post-fee buy fund); mints tokens to recipient.
contract MockV2Router is IUniswapV2Router02 {
    uint256 public lastValue;
    address public lastTo;
    address[] public lastPath;
    MockERC20 public tokenContract;

    function setToken(MockERC20 t) external { tokenContract = t; }

    function addLiquidityETH(address, uint, uint, uint, address, uint)
        external
        payable
        returns (uint, uint, uint)
    {
        revert("unused");
    }

    function WETH() external pure returns (address) {
        return address(0);
    }

    function swapExactETHForTokens(uint, address[] calldata path, address to, uint)
        external
        payable
        returns (uint[] memory amounts)
    {
        lastValue = msg.value;
        lastTo = to;
        delete lastPath;
        for (uint256 i; i < path.length; ++i) {
            lastPath.push(path[i]);
        }
        // 给 recipient 铸造 token（模拟买入输出）。
        uint256 out = msg.value * 1000;
        tokenContract.mint(to, out);
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }

    function swapExactTokensForETH(uint, uint, address[] calldata, address, uint)
        external
        pure
        returns (uint[] memory)
    {
        revert("unused");
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint,
        uint,
        address[] calldata,
        address,
        uint
    ) external pure {
        revert("unused");
    }

    function getAmountsOut(uint amountIn, address[] calldata path)
        external
        pure
        returns (uint[] memory amounts)
    {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
    }
}

/// @dev Minimal WETH mock for V3 sell unwrap path.
contract MockWETH is IWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    receive() external payable {}
}

/// @dev V3 router mock: transfers WETH to swap recipient.
contract MockV3Router is IUniswapV3SwapRouter {
    MockWETH public weth;
    uint256 public swapWethOut;

    constructor(MockWETH weth_) {
        weth = weth_;
    }

    function setSwapWethOut(uint256 amount) external {
        swapWethOut = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        weth.mint(params.recipient, swapWethOut);
        return swapWethOut;
    }

    function refundETH() external payable {}
}

/// @dev Minimal ERC20 with mint/approve/transfer for sell & buy paths.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev 拒收 ETH 的合约，用于验证手续费失败时静默归集到 feeAddress。
contract RejectEthReceiver {
    // 无 receive / fallback → call{value} 失败
}

/// @title TagAISwapWrapperSellsman
/// @notice Unit tests for sellsman resolution + buy-side fee split (mocked router).
contract TagAISwapWrapperSellsman is Test {
    TagAISwapWrapper public wrapper;
    MockImportHelper public importHelper;
    MockIPShare public ipshare;
    MockV2Router public router;
    MockWETH public mockWeth;
    MockV3Router public v3Router;
    MockERC20 public sellToken;
    MockERC20 public buyTokenContract;

    address public weth;
    address public feeAddress;
    address public token;
    address public buyer;
    address public seller;
    address public validSellsman;
    address public importer;

    uint16 public constant SELLSMAN_BPS = 100; // 1%
    uint16 public constant TAGAI_BPS = 100; // 1%

    function setUp() public {
        feeAddress = makeAddr("feeAddress");
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        validSellsman = makeAddr("validSellsman");
        importer = makeAddr("importer");

        importHelper = new MockImportHelper();
        ipshare = new MockIPShare();
        router = new MockV2Router();
        mockWeth = new MockWETH();
        weth = address(mockWeth);
        v3Router = new MockV3Router(mockWeth);
        sellToken = new MockERC20();
        buyTokenContract = new MockERC20();
        token = address(buyTokenContract);
        router.setToken(buyTokenContract);

        wrapper = new TagAISwapWrapper(
            address(importHelper),
            address(ipshare),
            weth,
            feeAddress
        );

        // Fee recipients must accept ETH.
        vm.deal(feeAddress, 0);
        vm.deal(validSellsman, 0);
        vm.deal(importer, 0);
        vm.deal(buyer, 100 ether);
    }

    function _path() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = weth;
        path[1] = token;
    }

    function _buy(address sellsmanArg, uint256 value) internal {
        vm.prank(buyer);
        wrapper.buyToken{value: value}(
            sellsmanArg,
            0,
            _path(),
            buyer,
            block.timestamp + 1,
            address(router)
        );
    }

    /// @dev Valid sellsman arg with IPShare → fee goes to that sellsman.
    function test_resolveSellsman_usesValidArg() public {
        ipshare.setCreated(validSellsman, true);

        uint256 value = 1 ether;
        uint256 expectedSellsmanFee = (value * SELLSMAN_BPS) / 10_000;
        uint256 expectedTagaiFee = (value * TAGAI_BPS) / 10_000;

        _buy(validSellsman, value);

        assertEq(validSellsman.balance, expectedSellsmanFee, "sellsman fee");
        assertEq(feeAddress.balance, expectedTagaiFee, "tagai fee");
        assertEq(router.lastValue(), value - expectedSellsmanFee - expectedTagaiFee, "buy fund");
        // token 先进 Wrapper（抽 0.2% Nutbox fee 后转用户）；未登记代币净额=毛额。
        assertEq(router.lastTo(), address(wrapper), "router recipient is wrapper");
        assertEq(buyTokenContract.balanceOf(buyer), (value - expectedSellsmanFee - expectedTagaiFee) * 1000, "buyer gets net tokens");
    }

    /// @dev Zero sellsman + importerOf set → fee goes to importer.
    function test_resolveSellsman_fallsBackToImporter() public {
        importHelper.setImporter(token, importer);

        uint256 value = 1 ether;
        uint256 expectedSellsmanFee = (value * SELLSMAN_BPS) / 10_000;
        uint256 expectedTagaiFee = (value * TAGAI_BPS) / 10_000;

        _buy(address(0), value);

        assertEq(importer.balance, expectedSellsmanFee, "importer as sellsman");
        assertEq(feeAddress.balance, expectedTagaiFee, "tagai fee");
        assertEq(router.lastValue(), value - expectedSellsmanFee - expectedTagaiFee, "buy fund");
    }

    /// @dev Zero sellsman + no importer → fee goes to feeAddress (both legs).
    function test_resolveSellsman_fallsBackToFeeAddress() public {
        uint256 value = 1 ether;
        uint256 expectedSellsmanFee = (value * SELLSMAN_BPS) / 10_000;
        uint256 expectedTagaiFee = (value * TAGAI_BPS) / 10_000;

        _buy(address(0), value);

        // sellsman + tagai both land on feeAddress
        assertEq(feeAddress.balance, expectedSellsmanFee + expectedTagaiFee, "feeAddress gets both");
        assertEq(router.lastValue(), value - expectedSellsmanFee - expectedTagaiFee, "buy fund");
    }

    /// @dev Non-zero sellsman without IPShare is ignored → importer used.
    function test_resolveSellsman_ignoresArgWithoutIPShare() public {
        address fake = makeAddr("fakeSellsman");
        importHelper.setImporter(token, importer);

        uint256 value = 1 ether;
        uint256 expectedSellsmanFee = (value * SELLSMAN_BPS) / 10_000;

        _buy(fake, value);

        assertEq(fake.balance, 0, "invalid sellsman gets nothing");
        assertEq(importer.balance, expectedSellsmanFee, "importer used instead");
    }

    /// @dev Default 1%+1% fee ratios applied against msg.value on buy.
    function test_buyFeeSplit_appliesDefaultRatios() public {
        ipshare.setCreated(validSellsman, true);

        uint256 value = 2 ether;
        _buy(validSellsman, value);

        assertEq(validSellsman.balance, 0.02 ether, "1% sellsman of 2 ETH");
        assertEq(feeAddress.balance, 0.02 ether, "1% tagai of 2 ETH");
        assertEq(router.lastValue(), 1.96 ether, "98% to router");
    }

    /// @dev sellsman 拒收 ETH 时：交易仍成功，sellsman 份额归集到 feeAddress。
    function test_buy_sellsmanReject_redirectsFeeToFeeAddress() public {
        RejectEthReceiver rejector = new RejectEthReceiver();
        ipshare.setCreated(address(rejector), true);

        uint256 value = 1 ether;
        uint256 expectedSellsmanFee = (value * SELLSMAN_BPS) / 10_000;
        uint256 expectedTagaiFee = (value * TAGAI_BPS) / 10_000;

        _buy(address(rejector), value);

        assertEq(address(rejector).balance, 0, "rejector got nothing");
        // sellsman 份额 + tagai 份额都进 feeAddress
        assertEq(
            feeAddress.balance,
            expectedSellsmanFee + expectedTagaiFee,
            "sellsman fee redirected + tagai"
        );
        assertEq(router.lastValue(), value - expectedSellsmanFee - expectedTagaiFee, "buy fund unchanged");
    }

    /// @dev Residual ETH on wrapper must not inflate sell fees on V3 path.
    function test_sellTokenV3_feesIgnoreResidualEth() public {
        ipshare.setCreated(validSellsman, true);

        uint256 residualEth = 0.5 ether;
        uint256 swapEthOut = 1 ether;
        uint256 amountIn = 1000 ether;

        // Donate ETH sitting on the wrapper before the sell.
        vm.deal(address(wrapper), residualEth);

        sellToken.mint(seller, amountIn);
        v3Router.setSwapWethOut(swapEthOut);
        // MockWETH must hold underlying ETH for unwrap.
        vm.deal(address(mockWeth), swapEthOut);

        uint256 expectedSellsmanFee = (swapEthOut * SELLSMAN_BPS) / 10_000;
        uint256 expectedTagaiFee = (swapEthOut * TAGAI_BPS) / 10_000;
        uint256 expectedTo = swapEthOut - expectedSellsmanFee - expectedTagaiFee;

        vm.prank(seller);
        wrapper.sellTokenV3(
            amountIn,
            0,
            address(sellToken),
            seller,
            block.timestamp + 1,
            validSellsman,
            address(v3Router),
            3000
        );

        assertEq(validSellsman.balance, expectedSellsmanFee, "fee on swap output only");
        assertEq(feeAddress.balance, expectedTagaiFee, "tagai fee on swap output only");
        assertEq(seller.balance, expectedTo, "seller receives post-fee swap proceeds");
        assertEq(address(wrapper).balance, residualEth, "residual ETH untouched");
    }
}
