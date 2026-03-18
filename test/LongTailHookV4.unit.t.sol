// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LongTailHookV4} from "../src/LongTailHookV4.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

import {MockPoolManagerV4Minimal} from "./mocks/MockPoolManagerV4Minimal.sol";

contract LongTailHookV4UnitTest is Test {
    MockPoolManagerV4Minimal public mockManager;
    LongTailHookV4 public hook;

    address public admin = address(0xA11CE);
    address public sender = address(0xBEEF);

    PoolKey public key;

    function setUp() public {
        mockManager = new MockPoolManagerV4Minimal();
        hook = new LongTailHookV4(IPoolManager(address(mockManager)), admin);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)) // included in PoolId derivation; must match setPoolConfig input
        });
    }

    function _setVelocityDisabled() internal {
        vm.startPrank(admin);
        hook.setVelocityConfig(60, 0, 0, 50);
        vm.stopPrank();
    }

    function _setPoolConfigIsolatedAdaptive(uint24 baseFee, uint24 largeTradeFee, uint128 small, uint128 large)
        internal
    {
        vm.startPrank(admin);
        hook.setPoolConfig(key, baseFee, largeTradeFee, 0, small, large, 0);
        vm.stopPrank();
    }

    function _doBeforeSwapWithAmount(int256 amountSpecified) internal returns (BeforeSwapDelta, uint24) {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});

        // `beforeSwap` is protected by `onlyPoolManager`
        vm.prank(address(mockManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) = hook.beforeSwap(sender, key, params, bytes(""));

        assertEq(selector, hook.beforeSwap.selector, "hook selector mismatch");
        assertEq(
            BeforeSwapDelta.unwrap(delta),
            BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA),
            "hook delta should be zero"
        );
        assertEq(overrideFee, 0, "override fee return value should be zero");
        return (delta, overrideFee);
    }

    function test_beforeSwap_updatesDynamicLPFee_withAdaptiveFee() public {
        _setVelocityDisabled();
        mockManager.setLiquidity(0);

        // baseFee=100, largeTradeFee=200; small=100, large=200.
        // Choose tradeSize=150 => pos=50, range=100 => adaptive=200*50/100=100.
        _setPoolConfigIsolatedAdaptive(100, 200, 100, 200);

        _doBeforeSwapWithAmount(150);

        assertEq(uint256(mockManager.lastUpdatedFee()), 200, "total fee should equal base + interpolated adaptive fee");
    }

    function test_beforeSwap_capsTotalFee() public {
        _setVelocityDisabled();
        mockManager.setLiquidity(0);

        // baseFee + largeTradeFee would be 40_000 but hook caps at 30_000.
        _setPoolConfigIsolatedAdaptive(20_000, 20_000, 1, 2);

        _doBeforeSwapWithAmount(2);

        assertEq(uint256(mockManager.lastUpdatedFee()), 30_000, "total fee should be hard-capped");
    }

    function test_beforeSwap_normalization_handlesInt256Min() public {
        _setVelocityDisabled();
        mockManager.setLiquidity(0);

        _setPoolConfigIsolatedAdaptive(0, 1234, 1, 2);

        _doBeforeSwapWithAmount(type(int256).min);

        assertEq(uint256(mockManager.lastUpdatedFee()), 1234, "int256.min should be treated as a very large trade");
    }
}

