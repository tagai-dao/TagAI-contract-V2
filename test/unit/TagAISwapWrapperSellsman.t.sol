// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/helper/TagAISwapWrapper.sol";
import "../../src/interfaces/IImportHelper.sol";
import "../../src/interfaces/IIPShare.sol";
import "../../src/interfaces/IUniswapV2Router02.sol";

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

/// @dev Captures ETH sent into swapExactETHForTokens (post-fee buy fund).
contract MockV2Router is IUniswapV2Router02 {
    uint256 public lastValue;
    address public lastTo;
    address[] public lastPath;

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
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = 0;
    }

    function swapExactTokensForETH(uint, uint, address[] calldata, address, uint)
        external
        pure
        returns (uint[] memory)
    {
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

/// @title TagAISwapWrapperSellsman
/// @notice Unit tests for sellsman resolution + buy-side fee split (mocked router).
contract TagAISwapWrapperSellsman is Test {
    TagAISwapWrapper public wrapper;
    MockImportHelper public importHelper;
    MockIPShare public ipshare;
    MockV2Router public router;

    address public weth;
    address public feeAddress;
    address public token;
    address public buyer;
    address public validSellsman;
    address public importer;

    uint16 public constant SELLSMAN_BPS = 100; // 1%
    uint16 public constant TAGAI_BPS = 100; // 1%

    function setUp() public {
        weth = makeAddr("weth");
        feeAddress = makeAddr("feeAddress");
        token = makeAddr("token");
        buyer = makeAddr("buyer");
        validSellsman = makeAddr("validSellsman");
        importer = makeAddr("importer");

        importHelper = new MockImportHelper();
        ipshare = new MockIPShare();
        router = new MockV2Router();

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
        assertEq(router.lastTo(), buyer);
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
}
