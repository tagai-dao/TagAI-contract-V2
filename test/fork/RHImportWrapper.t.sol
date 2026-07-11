// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ImportHelper} from "../../src/helper/ImportHelper.sol";
import {TagAISwapWrapper} from "../../src/helper/TagAISwapWrapper.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {CommunityFactory} from "../../src/nutbox/CommunityFactory.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {SocialCurationFactory} from "../../src/nutbox/dapps/social-curation/SocialCurationFactory.sol";
import {SocialCuration} from "../../src/nutbox/dapps/social-curation/SocialCuration.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {ICommunity} from "../../src/interfaces/ICommunity.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @dev Minimal Uniswap V3 pool surface (RH pool may omit public `fee()`; resolve via factory).
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function liquidity() external view returns (uint128);
}

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Minimal NPM surface for create-pool + full-range mint on RH.
interface INonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/**
 * @title RHImportWrapper
 * @notice RH mainnet fork E2E: ImportHelper → Nutbox inject/claim + TagAISwapWrapper V2/V3/V4.
 *
 * Run:
 *   FOUNDRY_PROFILE=rh_fork \
 *   RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *   FOUNDRY_ETH_RPC_URL= \
 *   forge test --match-contract RHImportWrapper -vvv
 */
contract RHImportWrapper is Test {
    // ─── RH mainnet constants (from task brief) ───────────────────────────────
    address internal constant TOKEN = 0xc6911796042b15d7Fa4F6CDe69e245DdCd3d9c31;
    address internal constant V2_PAIR = 0xd95e8e2Cd04c207625C6F23c974d365a5F3A91D3;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant V4_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @dev Uniswap V2 Router02 on RH (robinhood-chain-quickstart / docs).
    address internal constant V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    /// @dev Uniswap V3 SwapRouter02 on RH (no-deadline ExactInputSingleParams).
    address internal constant V3_SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    /// @dev Live V3 pool token (not imported in this suite — fee sellsman falls back to feeAddress).
    address internal constant LIVE_V3_TOKEN = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address internal constant LIVE_V3_POOL = 0xA70fc67C9F69da90B63a0e4C05D229954574E313;
    /// @dev factory.getPool(LIVE_V3_TOKEN, WETH, 10000) == LIVE_V3_POOL
    uint24 internal constant LIVE_V3_FEE = 10_000;

    uint24 internal constant V3_FEE = 3000;
    int24 internal constant V3_TICK_SPACING = 60;
    // Avoid colliding with any pre-existing ETH/TOKEN pool on RH (fee=3000 already initialized).
    uint24 internal constant V4_FEE = 12345;
    int24 internal constant V4_TICK_SPACING = 60;

    bytes32 internal constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 chainId,address pool,uint256 orderId,uint256 amount,address to,uint256 deadline)"
    );

    Committee internal committee;
    CommunityFactory internal communityFactory;
    HourlyTickCalculator internal calculator;
    SocialCurationFactory internal scf;
    IPShare internal ipshare;
    ImportHelper internal importHelper;
    TagAISwapWrapper internal wrapper;
    PoolModifyLiquidityTest internal v4LiquidityRouter;

    address internal feeRecipient;
    address internal tester;
    uint256 internal claimSignerKey;
    address internal claimSigner;

    bool internal envReady;
    uint8 internal tokenDecimals;
    uint256 internal tokenUnit; // 10 ** decimals

    modifier onlyRhFork() {
        if (!envReady) vm.skip(true);
        _;
    }

    function setUp() public {
        feeRecipient = makeAddr("feeRecipient");
        tester = makeAddr("tester");
        claimSignerKey = uint256(keccak256("rh-import-claim-signer"));
        claimSigner = vm.addr(claimSignerKey);

        if (!_bootstrapFork()) {
            envReady = false;
            return;
        }

        _deployNutboxAndHelpers();

        tokenDecimals = IERC20Metadata(TOKEN).decimals();
        tokenUnit = 10 ** uint256(tokenDecimals);

        vm.deal(tester, 100 ether);
        // Foundry deal works for standard ERC20 storage layouts; amount scaled by decimals.
        deal(TOKEN, tester, 1_000_000 * tokenUnit);

        envReady = true;
    }

    /// @dev Fork RH mainnet; skip cleanly when RPC/PM unavailable.
    function _bootstrapFork() internal returns (bool) {
        if (V4_PM.code.length > 0 && V2_PAIR.code.length > 0) {
            return _infraPresent();
        }

        string memory rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try this._createForkExternal(rpc) {
            // ok
        } catch {
            return false;
        }

        return _infraPresent();
    }

    function _createForkExternal(string calldata rpc) external {
        vm.createSelectFork(rpc);
    }

    function _infraPresent() internal view returns (bool) {
        return V4_PM.code.length > 0 && TOKEN.code.length > 0 && V2_PAIR.code.length > 0
            && V2_ROUTER.code.length > 0 && V3_NPM.code.length > 0 && V3_SWAP_ROUTER02.code.length > 0
            && WETH.code.length > 0;
    }

    function _deployNutboxAndHelpers() internal {
        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(0);
        committee.adminSetCommunitySettingsFee(0);
        committee.adminSetPoolOperationFee(0);

        communityFactory = new CommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(address(communityFactory));
        scf = new SocialCurationFactory(address(communityFactory), claimSigner);

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(address(scf));

        ipshare = new IPShare(feeRecipient);
        ipshare.adminStartTrade();

        importHelper = new ImportHelper(
            address(communityFactory), address(scf), address(committee), address(ipshare)
        );
        wrapper = new TagAISwapWrapper(address(importHelper), address(ipshare), WETH, feeRecipient);

        v4LiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(V4_PM));
    }

    // ─── Test 1: Import → inject → warp → EIP-712 claim ───────────────────────

    function test_import_inject_claim() public onlyRhFork {
        uint256 fees = _importFees(tester);
        vm.deal(tester, tester.balance + fees);

        vm.prank(tester, tester);
        (address community, address pool) =
            importHelper.createCommunityAndPool{value: fees}(TOKEN, address(calculator), bytes(""));

        assertEq(importHelper.importerOf(TOKEN), tester, "importerOf");
        assertTrue(IIPShare(address(ipshare)).ipshareCreated(tester), "ipshare");
        assertTrue(community != address(0) && pool != address(0), "community/pool");

        // Inject: approve calculator; tokens land in community.
        uint256 injectAmount = 168_000 * tokenUnit;
        vm.startPrank(tester);
        IERC20(TOKEN).approve(address(calculator), injectAmount);
        calculator.inject(community, injectAmount);
        vm.stopPrank();

        assertEq(calculator.totalInjected(community), injectAmount, "totalInjected");
        assertEq(IERC20(TOKEN).balanceOf(community), injectAmount, "community bal");

        // HourlyTick needs ≥1h; plan uses 2h.
        vm.warp(block.timestamp + 2 hours);

        uint256 claimAmount = injectAmount / 168; // ~1 hour of vesting
        assertGt(claimAmount, 0, "claimAmount");

        uint256 balBefore = IERC20(TOKEN).balanceOf(tester);
        uint256 deadline = block.timestamp + 1 days;
        uint256 orderId = 1;
        bytes memory sig = _signClaim(pool, orderId, claimAmount, tester, deadline);

        vm.prank(tester);
        SocialCuration(payable(pool)).claim(orderId, claimAmount, deadline, sig);

        assertEq(IERC20(TOKEN).balanceOf(tester), balBefore + claimAmount, "claimed");
        assertEq(SocialCuration(payable(pool)).totalClaimed(), claimAmount, "totalClaimed");
    }

    // ─── Test 2: Wrapper V2 against live pair ─────────────────────────────────

    function test_wrapper_v2_buy_sell() public onlyRhFork {
        _ensureImported(tester);

        address[] memory buyPath = new address[](2);
        buyPath[0] = WETH;
        buyPath[1] = TOKEN;

        uint256 ethIn = 0.05 ether;
        uint256 feeBefore = feeRecipient.balance;
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(tester);

        vm.prank(tester);
        wrapper.buyToken{value: ethIn}(
            address(0), 0, buyPath, tester, block.timestamp + 1 hours, V2_ROUTER
        );

        uint256 tokensBought = IERC20(TOKEN).balanceOf(tester) - tokenBefore;
        assertGt(tokensBought, 0, "v2 buy tokens");
        // 1% tagai + 1% sellsman (→ importer=tester, so only tagai leaves tester's eth notionally;
        // feeRecipient still receives tagaiRatio share).
        assertGt(feeRecipient.balance, feeBefore, "v2 buy tagai fee");

        uint256 sellAmt = tokensBought / 2;
        assertGt(sellAmt, 0, "v2 sellAmt");

        address[] memory sellPath = new address[](2);
        sellPath[0] = TOKEN;
        sellPath[1] = WETH;

        uint256 ethBefore = tester.balance;
        feeBefore = feeRecipient.balance;

        vm.startPrank(tester);
        IERC20(TOKEN).approve(address(wrapper), sellAmt);
        wrapper.sellToken(sellAmt, 0, sellPath, tester, block.timestamp + 1 hours, address(0), V2_ROUTER);
        vm.stopPrank();

        assertGt(tester.balance, ethBefore, "v2 sell eth");
        assertGt(feeRecipient.balance, feeBefore, "v2 sell tagai fee");
    }

    // ─── Test 3: Create V3 pool in fork, then wrapper buy/sell ────────────────

    function test_wrapper_v3_buy_sell() public onlyRhFork {
        _ensureImported(tester);
        _createV3PoolWithLiquidity(tester);

        uint256 ethIn = 0.05 ether;
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(tester);
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(tester);
        wrapper.buyTokenV3{value: ethIn}(
            address(0), 0, TOKEN, tester, block.timestamp + 1 hours, V3_SWAP_ROUTER02, V3_FEE
        );

        uint256 tokensBought = IERC20(TOKEN).balanceOf(tester) - tokenBefore;
        assertGt(tokensBought, 0, "v3 buy tokens");
        assertGt(feeRecipient.balance, feeBefore, "v3 buy fee");

        uint256 sellAmt = tokensBought / 2;
        uint256 ethBefore = tester.balance;
        feeBefore = feeRecipient.balance;

        vm.startPrank(tester);
        IERC20(TOKEN).approve(address(wrapper), sellAmt);
        wrapper.sellTokenV3(
            sellAmt, 0, TOKEN, tester, block.timestamp + 1 hours, address(0), V3_SWAP_ROUTER02, V3_FEE
        );
        vm.stopPrank();

        assertGt(tester.balance, ethBefore, "v3 sell eth");
        assertGt(feeRecipient.balance, feeBefore, "v3 sell fee");
    }

    // ─── Test 3b: Wrapper V3 against live RH pool (no ImportHelper) ───────────

    function test_wrapper_v3_live_pool_buy_sell() public onlyRhFork {
        // Sanity: live pool is TOKEN/WETH at the expected fee tier.
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(LIVE_V3_POOL);
        assertEq(pool.factory(), V3_FACTORY, "live v3 factory");
        assertTrue(
            (pool.token0() == LIVE_V3_TOKEN && pool.token1() == WETH)
                || (pool.token0() == WETH && pool.token1() == LIVE_V3_TOKEN),
            "live v3 pair"
        );
        assertEq(
            IUniswapV3FactoryMinimal(V3_FACTORY).getPool(LIVE_V3_TOKEN, WETH, LIVE_V3_FEE),
            LIVE_V3_POOL,
            "live v3 fee tier"
        );
        assertGt(pool.liquidity(), 0, "live v3 liquidity");

        // Intentionally skip import: sellsman=0 → feeAddress receives both fee legs.
        uint256 ethIn = 0.05 ether;
        uint256 tokenBefore = IERC20(LIVE_V3_TOKEN).balanceOf(tester);
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(tester);
        wrapper.buyTokenV3{value: ethIn}(
            address(0),
            0,
            LIVE_V3_TOKEN,
            tester,
            block.timestamp + 1 hours,
            V3_SWAP_ROUTER02,
            LIVE_V3_FEE
        );

        uint256 tokensBought = IERC20(LIVE_V3_TOKEN).balanceOf(tester) - tokenBefore;
        assertGt(tokensBought, 0, "live v3 buy tokens");
        // Without importer, both sellsman + tagai fees land on feeRecipient.
        assertGt(feeRecipient.balance, feeBefore, "live v3 buy fee");

        uint256 sellAmt = tokensBought / 2;
        assertGt(sellAmt, 0, "live v3 sellAmt");

        uint256 ethBefore = tester.balance;
        feeBefore = feeRecipient.balance;

        vm.startPrank(tester);
        IERC20(LIVE_V3_TOKEN).approve(address(wrapper), sellAmt);
        wrapper.sellTokenV3(
            sellAmt,
            0,
            LIVE_V3_TOKEN,
            tester,
            block.timestamp + 1 hours,
            address(0),
            V3_SWAP_ROUTER02,
            LIVE_V3_FEE
        );
        vm.stopPrank();

        assertGt(tester.balance, ethBefore, "live v3 sell eth");
        assertGt(feeRecipient.balance, feeBefore, "live v3 sell fee");
    }

    // ─── Test 4: Create V4 pool (zero hooks), then wrapper buy/sell ───────────

    function test_wrapper_v4_buy_sell() public onlyRhFork {
        _ensureImported(tester);

        PoolKey memory poolKey = _createV4PoolWithLiquidity(tester);

        uint256 ethIn = 0.05 ether;
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(tester);
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(tester);
        wrapper.buyTokenV4{value: ethIn}(
            address(0), 0, poolKey, tester, IPoolManager(V4_PM), 0
        );

        uint256 tokensBought = IERC20(TOKEN).balanceOf(tester) - tokenBefore;
        assertGt(tokensBought, 0, "v4 buy tokens");
        assertGt(feeRecipient.balance, feeBefore, "v4 buy fee");

        uint256 sellAmt = tokensBought / 2;
        uint256 ethBefore = tester.balance;
        feeBefore = feeRecipient.balance;

        vm.startPrank(tester);
        IERC20(TOKEN).approve(address(wrapper), sellAmt);
        wrapper.sellTokenV4(sellAmt, 0, poolKey, tester, address(0), IPoolManager(V4_PM), 0);
        vm.stopPrank();

        assertGt(tester.balance, ethBefore, "v4 sell eth");
        assertGt(feeRecipient.balance, feeBefore, "v4 sell fee");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _importFees(address who) internal returns (uint256) {
        uint256 ipFee = ipshare.ipshareCreated(who) ? 0 : ipshare.createFee();
        return ipFee + committee.getCreateCommunityFee() + committee.getCommunitySettingsFee();
    }

    function _ensureImported(address who) internal {
        if (importHelper.importerOf(TOKEN) != address(0)) return;
        uint256 fees = _importFees(who);
        vm.deal(who, who.balance + fees);
        vm.prank(who, who);
        importHelper.createCommunityAndPool{value: fees}(TOKEN, address(calculator), bytes(""));
        assertEq(importHelper.importerOf(TOKEN), who);
    }

    function _signClaim(address pool, uint256 orderId, uint256 amount, address to, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, block.chainid, pool, orderId, amount, to, deadline)
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Nutbox SocialCuration")),
                keccak256(bytes("1")),
                block.chainid,
                pool
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimSignerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createV3PoolWithLiquidity(address lp) internal {
        address token0 = WETH < TOKEN ? WETH : TOKEN;
        address token1 = WETH < TOKEN ? TOKEN : WETH;

        // ~1:1 starting price is fine; we seed both sides.
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        vm.startPrank(lp);
        INonfungiblePositionManager(V3_NPM).createAndInitializePoolIfNecessary(
            token0, token1, V3_FEE, sqrtPriceX96
        );

        uint256 ethLiq = 5 ether;
        uint256 tokenLiq = 5_000 * tokenUnit;
        IWETH(WETH).deposit{value: ethLiq}();
        IERC20(WETH).approve(V3_NPM, ethLiq);
        IERC20(TOKEN).approve(V3_NPM, tokenLiq);

        int24 tickLower = (TickMath.MIN_TICK / V3_TICK_SPACING) * V3_TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / V3_TICK_SPACING) * V3_TICK_SPACING;

        uint256 amount0 = token0 == WETH ? ethLiq : tokenLiq;
        uint256 amount1 = token1 == WETH ? ethLiq : tokenLiq;

        INonfungiblePositionManager(V3_NPM).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: V3_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
    }

    function _createV4PoolWithLiquidity(address lp) internal returns (PoolKey memory poolKey) {
        // Native ETH as currency0 (address(0) < TOKEN); zero hooks per design.
        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(TOKEN),
            fee: V4_FEE,
            tickSpacing: V4_TICK_SPACING,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        IPoolManager(V4_PM).initialize(poolKey, sqrtPriceX96);

        int24 tickLower = (TickMath.MIN_TICK / V4_TICK_SPACING) * V4_TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / V4_TICK_SPACING) * V4_TICK_SPACING;

        // Seed enough liquidity for small wrapper swaps.
        uint128 liquidity = 1e18;
        uint256 tokenApprove = 100_000 * tokenUnit;

        vm.startPrank(lp);
        IERC20(TOKEN).approve(address(v4LiquidityRouter), tokenApprove);
        v4LiquidityRouter.modifyLiquidity{value: 10 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopPrank();
    }
}
