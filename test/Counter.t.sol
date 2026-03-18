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

    function _setPoolConfig(
        uint24 baseFeeBps,
        uint24 largeTradeFeeBps,
        uint24 lowLiquidityFeeBps,
        uint128 smallTradeSize,
        uint128 largeTradeSize,
        uint128 lowLiquidityThreshold
    ) internal {
        vm.startPrank(admin);
        hook.setPoolConfig(poolKey, baseFeeBps, largeTradeFeeBps, lowLiquidityFeeBps, smallTradeSize, largeTradeSize, lowLiquidityThreshold);
        vm.stopPrank();
    }

    function _setVelocityConfig(
        uint64 windowSeconds,
        uint32 maxTradesInWindow,
        uint128 maxVolumeInWindow,
        uint24 suspiciousActivityFeeBps
    ) internal {
        vm.startPrank(admin);
        hook.setVelocityConfig(windowSeconds, maxTradesInWindow, maxVolumeInWindow, suspiciousActivityFeeBps);
        vm.stopPrank();
    }

    function _doSwap(uint256 size) internal returns (BeforeSwapDelta memory, uint24 feeBps) {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: int256(size), sqrtPriceLimitX96: 0});

        (bytes4 selector, BeforeSwapDelta memory delta, uint24 fee) =
            hook.beforeSwap(trader, poolKey, params, bytes(""));

        assertEq(selector, hook.beforeSwap.selector, "selector mismatch");
        return (delta, fee);
    }

    function _doSwapSigned(int256 amountSpecified) internal returns (uint24 feeBps) {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});

        (bytes4 selector, , uint24 fee) = hook.beforeSwap(trader, poolKey, params, bytes(""));
        assertEq(selector, hook.beforeSwap.selector, "selector mismatch");
        return fee;
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

    function test_AdaptiveFeeBoundariesAndInterpolation() public {
        // Isolate adaptive fee: disable base, liquidity, and velocity surcharges.
        poolManager.setLiquidity(0);
        _setPoolConfig(0, 200, 0, 100, 200, 0);
        _setVelocityConfig(60, 0, 0, 50);

        // tradeSize <= smallTradeSize => adaptive fee = 0
        uint24 feeAtSmall = _doSwapSigned(100);
        assertEq(feeAtSmall, 0, "adaptive fee should be 0 at small threshold");

        // tradeSize in between => linear interpolation with integer division flooring.
        // range = 200-100 = 100; pos = 150-100 = 50; fraction = 200*50/100 = 100
        uint24 feeMid = _doSwapSigned(150);
        assertEq(feeMid, 100, "adaptive fee should interpolate in mid-band");

        // tradeSize >= largeTradeSize => adaptive fee = largeTradeFeeBps
        uint24 feeAtLarge = _doSwapSigned(200);
        assertEq(feeAtLarge, 200, "adaptive fee should equal largeTradeFee at large threshold");
    }

    function test_LiquidityThresholdEqualityDoesNotAddLowLiquidityFee() public {
        poolManager.setLiquidity(123);
        _setPoolConfig(100, 0, 150, 10, 20, 123);
        _setVelocityConfig(60, 0, 0, 50);

        // tradeSize == smallTradeSize => adaptive fee = 0; liquidity == threshold => not considered "low"
        uint24 fee = _doSwapSigned(10);
        assertEq(fee, 100, "liquidity equality to threshold should not add low-liquidity fee");
    }

    function test_TotalFeeHardCapIsEnforced() public {
        // Force totalFee > cap so we exercise the hard cap path.
        poolManager.setLiquidity(0);
        _setPoolConfig(2000, 2000, 2000, 1, 2, 1); // liquidityFee applies because liquidity < threshold
        _setVelocityConfig(60, 0, 0, 50);

        uint24 fee = _doSwapSigned(2);
        assertEq(fee, 3000, "total fee should be hard-capped");
    }

    function test_VelocityWindowResetIsStrictGreaterThan() public {
        // Disable suspicious fee so we can reason purely about reset semantics.
        poolManager.setLiquidity(10_000e18);
        _setPoolConfig(0, 0, 0, 1, 2, 0);
        _setVelocityConfig(60, 1_000_000, type(uint128).max, 50);

        // Recompute the pool id exactly as the contract does.
        bytes32 id = keccak256(
            abi.encode(poolKey.currency0.addr, poolKey.currency1.addr, poolKey.fee, poolKey.tickSpacing, poolKey.hooks)
        );

        vm.warp(1000);
        _doSwapSigned(1);
        (, uint32 trades1,,) = hook.traderStats(id, trader);
        assertEq(trades1, 1, "tradesInWindow after first swap");

        vm.warp(1060); // exactly windowSeconds after previous swap => no reset (strict `>`)
        _doSwapSigned(1);
        (, uint32 trades2,,) = hook.traderStats(id, trader);
        assertEq(trades2, 2, "tradesInWindow should not reset on equality boundary");

        vm.warp(1120); // again exactly windowSeconds after the last swap => still no reset
        _doSwapSigned(1);
        (, uint32 trades3,,) = hook.traderStats(id, trader);
        assertEq(trades3, 3, "tradesInWindow should keep accumulating on equality boundary");

        vm.warp(1181); // strictly greater than windowSeconds since last trade => reset happens
        _doSwapSigned(1);
        (, uint32 trades4,,) = hook.traderStats(id, trader);
        assertEq(trades4, 1, "tradesInWindow should reset on strict greater than boundary");
    }

    function test_fuzz_amountSpecifiedNeverReverts(int256 amountSpecified) public {
        _setPoolConfig(100, 200, 150, 1e18, 100e18, 0); // liquidity fee disabled
        _setVelocityConfig(60, 0, 0, 50); // velocity fee disabled
        poolManager.setLiquidity(0);

        vm.assume(amountSpecified != 0);
        // Ensure we don't revert on normalization, including int256.min.
        _doSwapSigned(amountSpecified);
    }

    function test_fuzz_adaptiveFeeMonotonicityInBand(uint256 a, uint256 b) public {
        // Isolate adaptive fee: base/liquidity/velocity are all zero.
        _setPoolConfig(0, 200, 0, 100, 200, 0);
        _setVelocityConfig(60, 0, 0, 50);
        poolManager.setLiquidity(0);

        a = bound(a, 101, 199);
        b = bound(b, 101, 199);
        uint256 x = a < b ? a : b;
        uint256 y = a < b ? b : a;

        uint24 feeX = _doSwapSigned(int256(x));
        uint24 feeY = _doSwapSigned(int256(y));
        assertLe(feeX, feeY, "adaptive fee should be non-decreasing within band");
    }

    function test_normalization_handlesInt256Min() public {
        _setPoolConfig(0, 200, 0, 1, 2, 0);
        _setVelocityConfig(60, 0, 0, 50);
        poolManager.setLiquidity(0);

        // This used to revert due to abs overflow on -type(int256).min.
        uint24 fee = _doSwapSigned(type(int256).min);
        assertEq(fee, 200, "int256.min should be treated as a very large trade");
    }
}

