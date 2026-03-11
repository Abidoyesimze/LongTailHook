// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Uniswap v4-style types and interfaces needed for LongTailHook.
/// @dev These are intentionally simplified so the hook can be compiled and unit tested
///      in isolation, without requiring the full Uniswap v4 core repository.

/// @notice Emulates Uniswap v4's currency abstraction.
struct Currency {
    address addr;
}

/// @notice Pool key identifying a unique pool.
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Parameters passed to a swap.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice Delta returned from beforeSwap indicating virtual adjustments.
struct BeforeSwapDelta {
    int256 amount0;
    int256 amount1;
}

/// @notice Simplified manager interface exposing only what the hook needs for tests.
interface IPoolManagerMinimal {
    function getLiquidity(PoolKey calldata key) external view returns (uint128);
}

/// @notice Hook permission flags (simplified).
library HookFlags {
    uint8 internal constant BEFORE_SWAP = 1 << 0;
    uint8 internal constant AFTER_SWAP = 1 << 1;
}

/// @notice Minimal hook interface with only the callbacks we actually use.
interface IMinimalHook {
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        external
        returns (bytes4, BeforeSwapDelta memory, uint24);
}

