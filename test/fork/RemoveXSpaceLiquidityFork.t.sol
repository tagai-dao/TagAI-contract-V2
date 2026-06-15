// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {XSpaceStoreHook} from "../../src/hook/XSpaceStoreHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

contract RemoveXSpaceLiquidityForkTest is Test {
    address constant LP = 0x0De93A988D657e1E8897e1a70Ba1b95334297B63;
    address constant ROUTER = 0x02679B15DBFD5BE9B2918156AeB2A626F0895a8C;
    address constant HOOK = 0xea59195Ef0f784B000450B84bA4164F18E7b0CC1;
    address constant TOKEN = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    uint128 constant LIQ = 707518339380156491;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
    }

    function test_fork_removeLpViaExistingRouter() public {
        if (block.chainid != 56) return;

        PoolKey memory poolKey = _buildPoolKey();
        (, int24 tick,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(poolKey.toId());

        uint256 bnbBefore = LP.balance;
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(LP);

        vm.prank(LP);
        (BalanceDelta delta,) = CLPoolManagerRouter(payable(ROUTER)).modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: 12810,
                tickUpper: 13080,
                liquidityDelta: -int256(uint256(LIQ)),
                salt: bytes32(0)
            }),
            bytes("")
        );

        console2.log("tick before remove", tick);
        console2.log("bnb received", LP.balance - bnbBefore);
        console2.log("token received", IERC20(TOKEN).balanceOf(LP) - tokenBefore);
        console2.log("delta0", uint256(uint128(delta.amount0())));
        console2.log("delta1", uint256(uint128(delta.amount1())));
    }

    function _buildPoolKey() internal view returns (PoolKey memory key) {
        XSpaceStoreHook hookContract = XSpaceStoreHook(payable(HOOK));
        uint16 hookBitmap = hookContract.getHooksRegistrationBitmap();
        bytes32 parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hookBitmap)), hookContract.TICK_SPACING());

        key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(TOKEN),
            hooks: IHooks(HOOK),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: hookContract.RECOMMENDED_LP_FEE_PIPS(),
            parameters: parameters
        });
    }
}
