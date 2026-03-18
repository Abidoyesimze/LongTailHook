// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LongTailHookV4} from "../src/LongTailHookV4.sol";

import {Deployers} from "lib/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";

/// @notice Helper deployer so we can find a CREATE2 address whose low bits enable beforeSwap.
contract Create2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(addr != address(0), "create2 failed");
    }
}

contract LongTailHookV4IntegrationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    LongTailHookV4 public hook;
    address public hookAdmin = address(0xA11CE);

    // We keep swaps small to reduce test flakiness/time; fee computation depends only on |amountSpecified|.
    int256 public swapAmount = -150;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LongTailHookV4(_deployHookWithBeforeSwapFlag());

        // Create a dynamic-fee pool bound to our hook.
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function _deployHookWithBeforeSwapFlag() internal returns (address hookAddr) {
        Create2Deployer deployer = new Create2Deployer();

        bytes memory initCode = abi.encodePacked(
            type(LongTailHookV4).creationCode,
            abi.encode(IPoolManager(address(manager)), hookAdmin)
        );
        bytes32 initCodeHash = keccak256(initCode);

        // Find a salt that yields an address with BEFORE_SWAP permission bit set.
        uint160 lowMask = uint160((1 << 14) - 1); // Hooks.ALL_HOOK_MASK
        for (uint256 i = 0; i < 50_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initCodeHash, address(deployer));

            uint160 lowBits = uint160(predicted) & lowMask;

            // Only allow hook to call `beforeSwap` (and optionally parse its returned delta as well).
            // Any other flag combination can make `isValidHookAddress()` fail or trigger callbacks
            // that this hook intentionally reverts.
            if (lowBits == Hooks.BEFORE_SWAP_FLAG || lowBits == (Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
                hookAddr = deployer.deploy(initCode, salt);
                return hookAddr;
            }
        }
        revert("no suitable create2 salt found");
    }

    function _fetchPoolLPFee(PoolKey memory _key) internal view returns (uint256 lpFee) {
        PoolId id = _key.toId();
        (,,, lpFee) = manager.getSlot0(id);
    }

    function _swapWithAmount(int256 amountSpecified) internal {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }

    function test_adaptiveFeeUpdatesDynamicLPFee() public {
        // Disable all but adaptive fee.
        vm.startPrank(hookAdmin);
        hook.setPoolConfig(key, 0, 200, 0, 100, 200, 0);
        hook.setVelocityConfig(60, 0, 0, 50);
        vm.stopPrank();

        // tradeSize = |amountSpecified|
        _swapWithAmount(-100); // <= small => adaptive = 0
        assertEq(_fetchPoolLPFee(key), 0);

        _swapWithAmount(-150); // mid => adaptive = 200 * 50 / 100 = 100
        assertEq(_fetchPoolLPFee(key), 100);

        _swapWithAmount(-200); // >= large => adaptive = 200
        assertEq(_fetchPoolLPFee(key), 200);
    }

    function test_liquidityFeeFollowsThresholdStrictLessThan() public {
        uint128 actualLiquidity = manager.getLiquidity(key.toId());

        // Ensure adaptive and velocity fees are off.
        vm.startPrank(hookAdmin);
        hook.setVelocityConfig(60, 0, 0, 50);
        hook.setPoolConfig(key, 0, 0, 150, 1000, 2000, 0);
        vm.stopPrank();

        // lowLiquidityThreshold > liquidity => apply lowLiquidityFee
        vm.startPrank(hookAdmin);
        hook.setPoolConfig(key, 0, 0, 150, 1000, 2000, actualLiquidity + 1);
        vm.stopPrank();

        _swapWithAmount(-100);
        assertEq(_fetchPoolLPFee(key), 150);

        // lowLiquidityThreshold == liquidity => strict `<` => no liquidity fee
        vm.startPrank(hookAdmin);
        hook.setPoolConfig(key, 0, 0, 150, 1000, 2000, actualLiquidity);
        vm.stopPrank();

        _swapWithAmount(-100);
        assertEq(_fetchPoolLPFee(key), 0);
    }

    function test_velocityGuardAddsAndThenStopsSuspiciousFee() public {
        // Disable adaptive and liquidity fees.
        vm.startPrank(hookAdmin);
        hook.setPoolConfig(key, 0, 0, 0, 1000, 2000, 0);
        // Trigger on second trade within window.
        hook.setVelocityConfig(60, 1, 0, 50);
        vm.stopPrank();

        uint256 t0 = block.timestamp;

        _swapWithAmount(-100); // tradesInWindow = 1 => no surcharge
        assertEq(_fetchPoolLPFee(key), 0);

        _swapWithAmount(-100); // tradesInWindow = 2 => surcharge applies
        assertEq(_fetchPoolLPFee(key), 50);

        // After highFeeUntil, surcharge should stop.
        vm.warp(t0 + 60 + 1);
        _swapWithAmount(-100);
        assertEq(_fetchPoolLPFee(key), 0);
    }
}

