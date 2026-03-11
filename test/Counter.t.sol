// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LongTailHook} from "../src/LongTailHook.sol";
import {Currency, PoolKey, SwapParams, BeforeSwapDelta, IPoolManagerMinimal} from "../src/ILongTailHookTypes.sol";

/// @notice Simple mock PoolManager to drive liquidity-dependent logic.
contract MockPoolManager is IPoolManagerMinimal {
    uint128 public liquidity;

    function setLiquidity(uint128 _liquidity) external {
        liquidity = _liquidity;
    }

    function getLiquidity(PoolKey calldata) external view override returns (uint128) {
        return liquidity;
    }
}

contract LongTailHookTest is Test {
    MockPoolManager public poolManager;
    LongTailHook public hook;
    PoolKey public poolKey;

    address public admin = address(0xA11CE);
    address public trader = address(0xBEEF);

    function setUp() public {
        poolManager = new MockPoolManager();
        hook = new LongTailHook(IPoolManagerMinimal(address(poolManager)), admin);

        poolKey = PoolKey({
            currency0: Currency({addr: address(0x1)}),
            currency1: Currency({addr: address(0x2)}),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(hook)
        });

        vm.startPrank(admin);
        hook.setPoolConfig(
            poolKey,
            100, // baseFeeBps = 1%
            200, // largeTradeFeeBps = +2%
            150, // lowLiquidityFeeBps = +1.5%
            1e18, // smallTradeSize
            100e18, // largeTradeSize
            1_000e18 // lowLiquidityThreshold
        );
        vm.stopPrank();
    }

    function _doSwap(uint256 size) internal returns (BeforeSwapDelta memory, uint24 feeBps) {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(size),
            sqrtPriceLimitX96: 0
        });

        (bytes4 selector, BeforeSwapDelta memory delta, uint24 fee) =
            hook.beforeSwap(trader, poolKey, params, bytes(""));

        assertEq(selector, hook.beforeSwap.selector, "selector mismatch");
        return (delta, fee);
    }

    function test_SmallTradesHaveLowMarginalFee() public {
        poolManager.setLiquidity(10_000e18);

        (, uint24 feeSmall) = _doSwap(0.5e18);
        (, uint24 feeMedium) = _doSwap(10e18);

        assertLt(feeSmall, feeMedium, "small trades should have lower fee");
    }

    function test_LargeTradesHaveHigherFee() public {
        poolManager.setLiquidity(10_000e18);

        (, uint24 feeMedium) = _doSwap(10e18);
        (, uint24 feeLarge) = _doSwap(200e18);

        assertGt(feeLarge, feeMedium, "large trades should have higher fee");
    }

    function test_LowLiquidityIncreasesFee() public {
        // High liquidity -> base behaviour.
        poolManager.setLiquidity(10_000e18);
        (, uint24 feeHighLiq) = _doSwap(10e18);

        // Low liquidity -> should include lowLiquidityFeeBps.
        poolManager.setLiquidity(10e18);
        (, uint24 feeLowLiq) = _doSwap(10e18);

        assertGt(feeLowLiq, feeHighLiq, "low liquidity should increase fee");
    }

    function test_VelocityRaisesFeesOnBurstActivity() public {
        poolManager.setLiquidity(10_000e18);

        // First trade in fresh window.
        (, uint24 fee1) = _doSwap(1e18);

        // Rapidly perform multiple trades in the same block / timestamp.
        for (uint256 i = 0; i < 10; i++) {
            _doSwap(1e18);
        }

        (, uint24 feeAfterBurst) = _doSwap(1e18);

        assertGt(feeAfterBurst, fee1, "burst of trades should increase fee due to velocity guard");
    }
}

