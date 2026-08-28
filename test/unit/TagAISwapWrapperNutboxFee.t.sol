// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/helper/TagAISwapWrapper.sol";
import "../../src/interfaces/IImportHelper.sol";
import "../../src/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mock ImportHelper：仅用于通过 registerImportedToken 的 sender 校验。
contract MockImportHelper is IImportHelper {
    mapping(address => address) public importerOf;
    function setImporter(address token, address importer) external { importerOf[token] = importer; }
}

/// @dev Mock IPShare：仅 ipshareCreated 用于 sellsman 解析。
contract MockIPShare {
    mapping(address => bool) public created;
    function ipshareCreated(address s) external view returns (bool) { return created[s]; }
    function setCreated(address s, bool v) external { created[s] = v; }
}

/// @dev Mock Community：rewardCalculator() 返回 mock 计算器（无需实现完整 ICommunity）。
contract MockCommunity {
    address public rewardCalculator;
    address public _communityToken;
    bool public _revertOnInject;
    constructor(address calc, address token) { rewardCalculator = calc; _communityToken = token; }
    function setRevertOnInject(bool v) external { _revertOnInject = v; }
    function getCommunityToken() external view returns (address) { return _communityToken; }
}

/// @dev Mock Calculator：inject 时从调用者 transferFrom token 到 community；可配置 revert。
contract MockCalculator {
    address public _token;
    address public _community;
    uint256 public totalInjected;
    bool public shouldRevert;
    constructor(address token) { _token = token; }
    function setCommunity(address c) external { _community = c; }
    function setShouldRevert(bool v) external { shouldRevert = v; }
    function inject(address, uint256 amount) external {
        if (shouldRevert) revert("inject failed");
        IERC20(_token).transferFrom(msg.sender, _community, amount);
        totalInjected += amount;
    }
}

/// @dev Mock ERC20（标准 transfer/transferFrom/approve）。
contract MockERC20 {
    string public name; string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }
    function transfer(address to, uint256 amt) external returns (bool) { return _move(msg.sender, to, amt); }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        return _move(from, to, amt);
    }
    function approve(address spender, uint256 amt) external returns (bool) { allowance[msg.sender][spender] = amt; return true; }
    function _move(address from, address to, uint256 amt) internal returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

/// @dev Mock V2 Router：买入时按 rate 给 recipient 铸币；卖出时按 rate 给 wrapper 发 ETH。
contract MockV2Router is IUniswapV2Router02 {
    MockERC20 public _token;
    uint256 public _rate; // tokens per ETH (buy) / ETH per token (sell)
    constructor(MockERC20 token, uint256 rate) { _token = token; _rate = rate; }
    function swapExactETHForTokens(uint, address[] calldata, address to, uint)
        external payable returns (uint[] memory amounts) {
        uint256 out = msg.value * _rate;
        _token.mint(to, out);
        amounts = new uint[](2); amounts[0] = msg.value; amounts[1] = out;
    }
    function swapExactTokensForETH(uint amountIn, uint, address[] calldata path, address to, uint)
        external returns (uint[] memory amounts) {
        // 拉入并销毁输入 token，按 rate 给 `to` 发 ETH。
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        amounts = new uint[](2); amounts[0] = amountIn; amounts[1] = amountIn / _rate;
        (bool ok,) = to.call{value: amounts[1]}(""); require(ok, "send eth");
    }
    function addLiquidityETH(address, uint, uint, uint, address, uint) external payable returns (uint, uint, uint) { revert("unused"); }
    function WETH() external pure returns (address) { return address(0); }
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        amounts = new uint[](path.length); amounts[0] = amountIn;
        amounts[1] = amountIn * _rate;
    }
}

/// @title TagAISwapWrapperNutboxFee
/// @notice V11 导入代币 token 侧 0.2% Nutbox fee + 10 分钟注入（本地 mock）。
contract TagAISwapWrapperNutboxFee is Test {
    TagAISwapWrapper public wrapper;
    MockImportHelper public importHelper;
    MockIPShare public ipshare;
    MockERC20 public weth;
    MockERC20 public token;
    MockCommunity public community;
    MockCalculator public calculator;
    MockV2Router public router;

    address public feeAddress = makeAddr("feeAddress");
    address public buyer = makeAddr("buyer");
    uint16 public constant NUTBOX_BPS = 20; // 0.2%

    function setUp() public {
        importHelper = new MockImportHelper();
        ipshare = new MockIPShare();
        weth = new MockERC20("WETH", "WETH");
        token = new MockERC20("TKN", "TKN");
        calculator = new MockCalculator(address(token));
        community = new MockCommunity(address(calculator), address(token));
        calculator.setCommunity(address(community));

        router = new MockV2Router(token, 1000); // 1 ETH -> 1000 token

        wrapper = new TagAISwapWrapper(address(importHelper), address(ipshare), address(weth), feeAddress);
        // 隔离 token 侧 Nutbox fee：ETH 侧费率置 0，仅测 0.2% token fee。
        wrapper.adminSetFeeRatios(0, 0, NUTBOX_BPS);

        vm.deal(buyer, 100 ether);
        vm.deal(feeAddress, 0);
    }

    function _register(address tokenAddr, address comm) internal {
        vm.prank(address(importHelper));
        wrapper.registerImportedToken(tokenAddr, comm, buyer);
    }

    function _buyPath() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(weth); // WETH leg
        p[1] = address(token);
    }

    function _sellPath() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(token);
        p[1] = address(weth); // WETH leg
    }

    /// @dev 未登记代币：买卖前后 Wrapper token 余额不累积 Nutbox fee。
    function test_unregistered_noNutboxFee() public {
        uint256 wrapBefore = token.balanceOf(address(wrapper));
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));
        uint256 bought = token.balanceOf(buyer);
        assertEq(bought, 1000 ether, "full gross to buyer");
        assertEq(token.balanceOf(address(wrapper)), wrapBefore, "wrapper holds no fee");

        // 卖出：用户 token 直接进 swap，wrapper 不抽
        uint256 sellAmt = bought / 2;
        vm.startPrank(buyer);
        token.approve(address(wrapper), sellAmt);
        wrapper.sellToken(sellAmt, 0, _sellPath(), buyer, block.timestamp + 1, address(0), address(router));
        vm.stopPrank();
        assertEq(token.balanceOf(address(wrapper)), wrapBefore, "sell: wrapper holds no fee");
    }

    /// @dev 已登记买：用户少收 0.2%，pending 增加。
    function test_registeredBuy_accruesNutboxFee() public {
        _register(address(token), address(community));
        uint256 pendingBefore = wrapper.pendingNutboxInjection(address(token));

        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));

        uint256 gross = 1000 ether;
        uint256 expectedFee = (gross * NUTBOX_BPS) / 10_000;
        assertEq(token.balanceOf(buyer), gross - expectedFee, "buyer gets net");
        assertEq(token.balanceOf(address(wrapper)), expectedFee, "wrapper holds fee");
        assertEq(wrapper.pendingNutboxInjection(address(token)), pendingBefore + expectedFee, "pending accrued");
    }

    /// @dev warp 600s 后下一笔买入把 pending inject 到 calculator。
    function test_settle_afterInterval_injectsToCalculator() public {
        _register(address(token), address(community));
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));
        uint256 oldPending = wrapper.pendingNutboxInjection(address(token));
        assertGt(oldPending, 0);
        assertEq(calculator.totalInjected(), 0, "not yet injected");

        vm.warp(block.timestamp + 600);

        // 下一笔买入触发结算：旧 pending 注入，新买入产生新 pending。
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));

        uint256 newFee = (uint256(1000 ether) * uint256(NUTBOX_BPS)) / 10_000;
        assertEq(calculator.totalInjected(), oldPending, "old pending injected to calculator");
        assertEq(token.balanceOf(address(community)), oldPending, "community received tokens");
        assertEq(wrapper.pendingNutboxInjection(address(token)), newFee, "only new buy fee pending");
    }

    /// @dev inject revert 时 pending 保留、用户兑换仍成功。
    function test_injectFails_pendingRetained_tradeSucceeds() public {
        _register(address(token), address(community));
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));
        uint256 pending = wrapper.pendingNutboxInjection(address(token));

        calculator.setShouldRevert(true);
        vm.warp(block.timestamp + 600);

        // 买入仍成功，pending 保留
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));

        uint256 gross = 1000 ether;
        uint256 newFee = (gross * uint256(NUTBOX_BPS)) / 10_000;
        assertEq(wrapper.pendingNutboxInjection(address(token)), pending + newFee, "pending retained + new");
        assertEq(calculator.totalInjected(), 0, "no inject on failure");
    }

    /// @dev 已登记卖：从卖出 token 扣 0.2%，剩余进 swap。
    function test_registeredSell_chargesNutboxFee() public {
        _register(address(token), address(community));
        // 先买入给用户 token
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));
        uint256 userBal = token.balanceOf(buyer);

        uint256 sellAmt = userBal / 2;
        uint256 expectedFee = (sellAmt * uint256(NUTBOX_BPS)) / 10_000;
        uint256 swapIn = sellAmt - expectedFee;
        uint256 buyFee = (uint256(1000 ether) * uint256(NUTBOX_BPS)) / 10_000;

        uint256 buyerEthBefore = buyer.balance;
        vm.startPrank(buyer);
        token.approve(address(wrapper), sellAmt);
        wrapper.sellToken(sellAmt, 0, _sellPath(), buyer, block.timestamp + 1, address(0), address(router));
        vm.stopPrank();

        // wrapper 累计 fee（买入 fee + 卖出 fee）
        assertEq(token.balanceOf(address(wrapper)) - buyFee, expectedFee, "sell fee accrued");
        assertGt(buyer.balance, buyerEthBefore, "seller received eth");
        // 卖出 fee 进 pending
        assertGt(wrapper.pendingNutboxInjection(address(token)), 0, "sell fee in pending");
    }

    /// @dev flushNutboxInjection 同样受 10 分钟限制。
    function test_flush_respectsInterval() public {
        _register(address(token), address(community));
        vm.prank(buyer);
        wrapper.buyToken{value: 1 ether}(address(0), 0, _buyPath(), buyer, block.timestamp + 1, address(router));
        uint256 pending = wrapper.pendingNutboxInjection(address(token));

        // 未到 10 分钟：flush 不注入
        uint256 remaining = wrapper.flushNutboxInjection(address(token));
        assertEq(remaining, pending, "still pending before interval");
        assertEq(calculator.totalInjected(), 0);

        vm.warp(block.timestamp + 600);
        remaining = wrapper.flushNutboxInjection(address(token));
        assertEq(remaining, 0, "pending cleared after interval");
        assertEq(calculator.totalInjected(), pending, "injected");
    }
}
