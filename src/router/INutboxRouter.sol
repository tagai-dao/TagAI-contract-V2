// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INutboxRouter {
    enum SourceType {
        V2_PAIR,
        V3_POOL,
        UNISWAP_V4,
        PANCAKE_V4_CL
    }

    struct UniswapV4Source {
        address poolManager;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PancakeV4CLSource {
        address currency0;
        address currency1;
        address hooks;
        address poolManager;
        uint24 fee;
        bytes32 parameters;
    }

    /// @dev Constructor-only bootstrap entry. Runtime administration continues to use addPricePool().
    struct InitialPricePool {
        address token0;
        address token1;
        SourceType sourceType;
        bytes sourceData;
    }

    /// @dev Constructor-only bootstrap entry. Pool IDs must reference entries initialized first.
    struct InitialRoute {
        address tokenIn;
        address tokenOut;
        bytes32[] poolIds;
    }

    function wrappedNative() external view returns (address);

    function pancakeV3Router() external view returns (address);

    function pancakeV3Factory() external view returns (address);

    function v2RouterForFactory(address factory) external view returns (address);

    function allowedV2Factory(address factory) external view returns (bool);

    function allowedV3Factory(address factory) external view returns (bool);

    function allowedUniswapV4Manager(address manager) external view returns (bool);

    function allowedPancakeV4CLManager(address manager) external view returns (bool);

    function hasPricePool(bytes32 poolId) external view returns (bool);

    /// @notice Returns the stable registry ID for a normalized token pair.
    /// @dev Token order does not matter and native coin is normalized to `wrappedNative`.
    function pricePoolId(address tokenA, address tokenB) external view returns (bytes32 poolId);

    function pricePool(bytes32 poolId)
        external
        view
        returns (
            bool enabled,
            uint32 routeReferences,
            address token0,
            address token1,
            SourceType sourceType,
            bytes memory sourceData
        );

    /// @notice Registers the first official pool for a token pair.
    /// @dev Reverts if that normalized pair already has an official pool.
    function addPricePool(SourceType sourceType, bytes calldata sourceData) external returns (bytes32 poolId);

    /// @notice Replaces a token pair's current official pool without changing its stable ID or any route.
    function replacePricePool(SourceType sourceType, bytes calldata sourceData) external returns (bytes32 poolId);

    function removePricePool(bytes32 poolId) external;

    function hasRoute(address tokenIn, address tokenOut) external view returns (bool);

    function routePoolCount(address tokenIn, address tokenOut) external view returns (uint256);

    function routePoolAt(address tokenIn, address tokenOut, uint256 index) external view returns (bytes32 poolId);

    function addRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external;

    function replaceRoute(address tokenIn, address tokenOut, bytes32[] calldata poolIds) external;

    function removeRoute(address tokenIn, address tokenOut) external;

    function validateRoute(address tokenIn, address tokenOut) external view;

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);

    function quoteNative(address token, uint256 tokenAmount) external view returns (uint256 nativeAmount);

    /**
     * @notice Swaps an exact input amount over the platform's current route.
     * @dev The caller cannot provide or pin a path. The latest owner-managed route is resolved
     *      when the transaction executes. A route may mix supported V2, V3 and V4 pools, and
     *      `tokenIn` or `tokenOut` may be address(0) for native coin.
     */
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}
