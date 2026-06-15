// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";

library URActions {
    uint256 internal constant CL_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant SETTLE_ALL = 0x0c;
    uint256 internal constant TAKE_ALL = 0x0f;
}

struct CLSwapExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

contract UniversalRouterSellForkTest is Test {
    address constant UNIVERSAL_ROUTER = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address constant HOOK = 0xea59195Ef0f784B000450B84bA4164F18E7b0CC1;
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    uint128 constant SELL_AMOUNT = 0.02 ether;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
    }

    function test_fork_universalRouterSell() public {
        if (block.chainid != 56) return;

        address seller = 0x0De93A988D657e1E8897e1a70Ba1b95334297B63;

        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(SPCXB),
            hooks: IHooks(HOOK),
            poolManager: IPoolManager(CL_POOL_MANAGER),
            fee: 4000,
            parameters: 0x00000000000000000000000000000000000000000000000000000000000a0cc1
        });

        CLSwapExactInputSingleParams memory swapParams = CLSwapExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: false,
            amountIn: SELL_AMOUNT,
            amountOutMinimum: 0,
            hookData: bytes("")
        });

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(URActions.CL_SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(URActions.SETTLE_ALL)),
            bytes1(uint8(URActions.TAKE_ALL))
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        params[1] = abi.encode(poolKey.currency1, type(uint256).max);
        params[2] = abi.encode(poolKey.currency0, uint256(0));

        bytes memory infiPayload = abi.encode(actions, params);
        bytes memory commands = abi.encodePacked(bytes1(uint8(0x10)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = infiPayload;

        // Permit2 path
        vm.startPrank(seller);
        deal(SPCXB, seller, SELL_AMOUNT);
        IERC20(SPCXB).approve(PERMIT2, type(uint256).max);
        (bool ok,) = PERMIT2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                SPCXB,
                UNIVERSAL_ROUTER,
                type(uint160).max,
                uint48(block.timestamp + 1 days)
            )
        );
        require(ok, "permit2 approve failed");

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);
        vm.stopPrank();
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}
