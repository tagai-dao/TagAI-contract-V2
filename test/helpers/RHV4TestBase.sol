// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pump} from "../../src/pump/Pump.sol";
import {NutboxDeployConfig, NutboxDeployConfigLib} from "../../src/pump/NutboxDeployConfig.sol";
import {Token} from "../../src/pump/Token.sol";
import {TagAISwapHook} from "../../src/hook/TagAISwapHook.sol";
import {HourlyTickCalculator} from "../../src/nutbox/calculators/HourlyTickCalculator.sol";
import {Committee} from "../../src/nutbox/Committee.sol";
import {ICommittee} from "../../src/interfaces/ICommittee.sol";
import {IIPShare} from "../../src/interfaces/IIPShare.sol";
import {IPShare} from "../../src/pump/IPShare.sol";
import {HookMiner} from "../../src/utils/HookMiner.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @dev Shared RH / Uniswap v4 test harness (local PoolManager or forked RH mainnet PM).
abstract contract RHV4TestBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // TagAISwapHook permissions: beforeInitialize, before/afterSwap, swap return deltas
    uint160 internal constant HOOK_FLAGS =
        uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    uint256 internal constant NUTBOX_ALLOCATION = 150_000_000 ether;
    uint256 internal constant BONDING_CURVE_TOTAL = 650_000_000 ether;
    uint256 internal constant EXTERNAL_SELLABLE = 800_000_000 ether;
    uint256 internal constant LISTING_ETH_BUDGET = 48 ether / 10;
    uint256 internal constant POOL_ETH_END_TOLERANCE = 0.02 ether;

    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 458583950375716805416895042066315;
    int24 internal constant LISTING_TICK_LOWER = -887220;
    int24 internal constant LISTING_TICK_UPPER = 205740;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    HourlyTickCalculator internal calculator;
    Pump internal pump;
    TagAISwapHook internal hook;

    Committee internal committee;
    address internal communityFactory;
    address internal scf;
    IPShare internal ipshare;

    address internal creator;
    address internal buyer;
    address internal feeRecipient;

    bool internal envReady;

    function setUp() public virtual {
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        feeRecipient = makeAddr("feeRecipient");

        if (!_bootstrapPoolManager()) {
            envReady = false;
            return;
        }

        // fork 会重置 setUp 早期状态；deal 必须在 fork 之后
        vm.deal(creator, 50_000 ether);
        vm.deal(buyer, 50_000 ether);

        _deployNutboxStack();
        _deployPumpAndHook();
        envReady = true;
    }

    modifier onlyReady() {
        if (!envReady) vm.skip(true);
        _;
    }

    /// @dev Local: deploy fresh PoolManager. Fork child: select RH mainnet fork + existing PM.
    function _bootstrapPoolManager() internal virtual returns (bool) {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        return true;
    }

    function _deployNutboxStack() internal virtual {
        committee = new Committee(payable(feeRecipient));
        committee.adminSetCreateCommunityFee(_nutboxCreateCommunityFee());
        committee.adminSetCommunitySettingsFee(_nutboxCommunitySettingsFee());
        committee.adminSetPoolOperationFee(0);

        communityFactory = _deployCommunityFactory(address(committee));
        calculator = new HourlyTickCalculator(communityFactory);
        scf = _deploySocialCurationFactory(communityFactory, makeAddr("claimSigner"));

        committee.adminAddContract(address(calculator));
        committee.adminAddContract(scf);
    }

    function _nutboxCreateCommunityFee() internal pure virtual returns (uint256) {
        return 0;
    }

    function _nutboxCommunitySettingsFee() internal pure virtual returns (uint256) {
        return 0;
    }

    function _deployPumpAndHook() internal virtual {
        ipshare = new IPShare(feeRecipient);
        pump = new Pump(
            address(ipshare),
            feeRecipient,
            NutboxDeployConfig({
                communityFactory: communityFactory,
                calculator: address(calculator),
                socialCurationFactory: scf,
                committee: address(committee),
                poolManager: address(manager)
            })
        );
        pump.adminSetPoolManager(address(manager));

        hook = _deployHookWithValidFlags();

        pump.adminSetHookAddress(address(hook));
        pump.adminSetCalculator(address(calculator));
        pump.adminSetNutbox(communityFactory, address(calculator), scf, address(committee));
    }

    function _deployHookWithValidFlags() internal returns (TagAISwapHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(pump));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(TagAISwapHook).creationCode,
            constructorArgs
        );

        deployed = new TagAISwapHook{salt: salt}(manager, address(pump));
        assertEq(address(deployed), predicted, "CREATE2 hook address mismatch");
        assertEq(uint160(address(deployed)) & ((1 << 14) - 1), HOOK_FLAGS, "invalid hook flags");
    }

    function _deployCommunityFactory(address _committee) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("CommunityFactory.sol:CommunityFactory"),
            abi.encode(_committee)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "CF deploy failed");
        return deployed;
    }

    function _deploySocialCurationFactory(address _communityFactory, address _claimSigner)
        internal
        returns (address)
    {
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("SocialCurationFactory.sol:SocialCurationFactory"),
            abi.encode(_communityFactory, _claimSigner)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "SCF deploy failed");
        return deployed;
    }

    function _ensureCreatorIPShare() internal {
        if (ipshare.ipshareCreated(creator)) return;
        uint256 fee = ipshare.createFee();
        vm.deal(creator, creator.balance + fee);
        vm.prank(creator, creator);
        ipshare.createShare{value: fee}(creator);
    }

    function _createToken(string memory tick) internal returns (Token token) {
        _ensureCreatorIPShare();

        uint256 totalFixedFee = pump.createFee();
        vm.prank(creator, creator);
        address tokenAddr =
            pump.createToken{value: totalFixedFee}(tick, keccak256(abi.encodePacked(tick, block.timestamp)));
        token = Token(payable(tokenAddr));
    }

    function _fillBondingCurveUntilListed(Token token, address actor) internal {
        vm.startPrank(actor, actor);
        vm.warp(block.timestamp + 16);
        vm.deal(actor, 50_000 ether);

        for (uint256 i = 0; i < 1000 && !token.listed(); i++) {
            if (token.bondingCurveSupply() >= BONDING_CURVE_TOTAL) break;

            uint256 ethIn = 5 ether;
            if (i % 5 == 0) ethIn = 50 ether;
            if (actor.balance < ethIn + 1 ether) vm.deal(actor, ethIn + 10_000 ether);

            try token.buyToken{value: ethIn}(0, creator, 8000) {} catch {
                try token.buyToken{value: ethIn * 2}(0, creator, 9000) {} catch {
                    break;
                }
            }
        }
        vm.stopPrank();
    }

    function _createAndListToken(string memory tick) internal virtual returns (Token token) {
        token = _createToken(tick);
        _fillBondingCurveUntilListed(token, buyer);
        assertTrue(token.listed(), "listing failed");
        assertEq(token.bondingCurveSupply(), BONDING_CURVE_TOTAL, "curve not full");
    }

    function _buildPoolKey(address tokenAddr) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(tokenAddr),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _poolEthBalance(PoolKey memory poolKey) internal view returns (uint256) {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPrice,,,) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(LISTING_TICK_UPPER);
        if (sqrtPrice >= sqrtUpper || liquidity == 0) return 0;
        return SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtUpper, liquidity, false);
    }

    function _swapSell(PoolKey memory poolKey, address actor, uint256 tokenIn) internal returns (uint256 ethOut) {
        uint256 balBefore = actor.balance;
        address tokenAddr = Currency.unwrap(poolKey.currency1);

        vm.startPrank(actor);
        IERC20(tokenAddr).approve(address(swapRouter), tokenIn);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(LISTING_TICK_UPPER)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();

        ethOut = actor.balance - balBefore;
    }

    function _sellAllExternal(PoolKey memory poolKey, address actor) internal returns (uint256 totalEthOut) {
        address tokenAddr = Currency.unwrap(poolKey.currency1);
        uint256 chunk = 50_000_000 ether;
        uint256 remaining = IERC20(tokenAddr).balanceOf(actor);

        for (uint256 round = 0; round < 200 && remaining > 1 ether; round++) {
            uint256 sellAmt = remaining > chunk ? chunk : remaining;
            uint256 received = _swapSell(poolKey, actor, sellAmt);
            uint256 afterBal = IERC20(tokenAddr).balanceOf(actor);
            if (afterBal >= remaining) break;
            totalEthOut += received;
            remaining = afterBal;
        }
    }
}
