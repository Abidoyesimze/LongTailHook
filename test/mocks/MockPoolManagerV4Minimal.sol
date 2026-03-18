// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

/// @notice Minimal PoolManager mock for `LongTailHookV4.beforeSwap` unit tests.
/// @dev Implements only:
///  - `updateDynamicLPFee(PoolKey,uint24)` (records the latest fee passed by the hook)
///  - `extsload(bytes32)` (returns a fixed liquidity value for `StateLibrary.getLiquidity`)
contract MockPoolManagerV4Minimal {
    uint128 public liquidity;

    uint24 public lastUpdatedFee;
    PoolKey public lastUpdatedKey;

    function setLiquidity(uint128 _liquidity) external {
        liquidity = _liquidity;
    }

    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        lastUpdatedKey = key;
        lastUpdatedFee = newDynamicLPFee;
    }

    function extsload(bytes32 /*slot*/) external view returns (bytes32 value) {
        // `StateLibrary.getLiquidity()` does `uint128(uint256(manager.extsload(slot)))`.
        value = bytes32(uint256(liquidity));
    }
}

