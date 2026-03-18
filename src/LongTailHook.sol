// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Currency,
    PoolKey,
    SwapParams,
    BeforeSwapDelta,
    IPoolManagerMinimal,
    IMinimalHook,
    HookFlags
} from "./ILongTailHookTypes.sol";

/// @title LongTailHook — Adaptive Curve for Illiquid and Long-Tail Token Markets
/// @notice Demonstrates a Uniswap v4-style hook with:
///         - Adaptive effective pricing for small vs large trades (via dynamic fees)
///         - Liquidity-aware fee modulation
///         - Simple anti-manipulation protections based on trade velocity
contract LongTailHook is IMinimalHook {
    /// @notice Configuration per pool.
    struct PoolConfig {
        // Base fee in basis points (bps).
        uint24 baseFeeBps;
        // Extra fee for very large trades (bps).
        uint24 largeTradeFeeBps;
        // Extra fee when liquidity is low (bps).
        uint24 lowLiquidityFeeBps;
        // Thresholds used in the adaptive logic.
        uint128 smallTradeSize; // below this => "small trade"
        uint128 largeTradeSize; // above this => "large trade"
        uint128 lowLiquidityThreshold; // below this => "low liquidity"
        bool initialized;
    }

    /// @notice Simple per-trader velocity / behaviour tracking.
    struct TraderStats {
        uint64 lastTradeTimestamp;
        uint32 tradesInWindow;
        uint128 volumeInWindow;
        uint64 highFeeUntil;
    }

    /// @notice Global params for the anti-manipulation mechanism.
    struct VelocityConfig {
        uint64 windowSeconds;
        uint32 maxTradesInWindow;
        uint128 maxVolumeInWindow;
        uint24 suspiciousActivityFeeBps;
    }

    /// @notice Emitted whenever a pool config is initialized or updated.
    event PoolConfigUpdated(
        PoolKey indexed key,
        uint24 baseFeeBps,
        uint24 largeTradeFeeBps,
        uint24 lowLiquidityFeeBps,
        uint128 smallTradeSize,
        uint128 largeTradeSize,
        uint128 lowLiquidityThreshold
    );

    /// @notice Emitted when suspicious activity is detected for a trader.
    event SuspiciousActivity(
        address indexed trader, PoolKey indexed key, uint32 tradesInWindow, uint128 volumeInWindow, uint64 highFeeUntil
    );

    /// @notice Manager (in real deployments this would be the Uniswap v4 PoolManager).
    IPoolManagerMinimal public immutable poolManager;

    /// @notice Per-pool configuration.
    mapping(bytes32 => PoolConfig) public poolConfig;

    /// @notice Per-pool, per-trader stats.
    mapping(bytes32 => mapping(address => TraderStats)) public traderStats;

    /// @notice Global velocity configuration.
    VelocityConfig public velocityConfig;

    /// @notice Admin address with permission to configure pools and velocity params.
    address public immutable admin;

    constructor(IPoolManagerMinimal _poolManager, address _admin) {
        poolManager = _poolManager;
        admin = _admin;
        velocityConfig = VelocityConfig({
            windowSeconds: 60,
            maxTradesInWindow: 5,
            maxVolumeInWindow: 1_000e18,
            suspiciousActivityFeeBps: 50 // +0.50% on top when suspicious
        });
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "LongTailHook: not admin");
        _;
    }

    /// @notice Returns the hook permissions for illustrative purposes.
    /// @dev Mimics Uniswap v4 permission flags; here we only use BEFORE_SWAP.
    function getHookPermissions() external pure returns (uint8) {
        return HookFlags.BEFORE_SWAP;
    }

    /// @notice Compute a unique key for mapping storage.
    function _poolId(PoolKey calldata key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key.currency0.addr, key.currency1.addr, key.fee, key.tickSpacing, key.hooks));
    }

    // ========= Admin configuration =========

    /// @notice Configure pricing / liquidity parameters for a given pool.
    function setPoolConfig(
        PoolKey calldata key,
        uint24 baseFeeBps,
        uint24 largeTradeFeeBps,
        uint24 lowLiquidityFeeBps,
        uint128 smallTradeSize,
        uint128 largeTradeSize,
        uint128 lowLiquidityThreshold
    ) external onlyAdmin {
        require(baseFeeBps <= 10_000, "LongTailHook: base fee too high");
        require(largeTradeFeeBps <= 10_000, "LongTailHook: large trade fee too high");
        require(lowLiquidityFeeBps <= 10_000, "LongTailHook: low liq fee too high");
        require(smallTradeSize < largeTradeSize, "LongTailHook: invalid trade size band");

        bytes32 id = _poolId(key);
        poolConfig[id] = PoolConfig({
            baseFeeBps: baseFeeBps,
            largeTradeFeeBps: largeTradeFeeBps,
            lowLiquidityFeeBps: lowLiquidityFeeBps,
            smallTradeSize: smallTradeSize,
            largeTradeSize: largeTradeSize,
            lowLiquidityThreshold: lowLiquidityThreshold,
            initialized: true
        });

        emit PoolConfigUpdated(
            key, baseFeeBps, largeTradeFeeBps, lowLiquidityFeeBps, smallTradeSize, largeTradeSize, lowLiquidityThreshold
        );
    }

    /// @notice Configure global velocity-based anti-manipulation parameters.
    function setVelocityConfig(
        uint64 windowSeconds,
        uint32 maxTradesInWindow,
        uint128 maxVolumeInWindow,
        uint24 suspiciousActivityFeeBps
    ) external onlyAdmin {
        require(windowSeconds > 0, "LongTailHook: window 0");
        require(suspiciousActivityFeeBps <= 1_000, "LongTailHook: suspicious fee too high");

        velocityConfig = VelocityConfig({
            windowSeconds: windowSeconds,
            maxTradesInWindow: maxTradesInWindow,
            maxVolumeInWindow: maxVolumeInWindow,
            suspiciousActivityFeeBps: suspiciousActivityFeeBps
        });
    }

    // ========= Core hook logic =========

    /// @inheritdoc IMinimalHook
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    )
        external
        override
        returns (bytes4, BeforeSwapDelta memory, uint24)
    {
        bytes32 id = _poolId(key);
        PoolConfig memory config = poolConfig[id];
        require(config.initialized, "LongTailHook: pool not configured");

        uint256 tradeSize = _normalizedTradeSize(params.amountSpecified);

        uint24 adaptiveFee = _computeAdaptiveFee(id, config, tradeSize);

        uint24 liquidityFee = _computeLiquidityFee(key, config);

        uint24 velocityFee = _updateTraderAndComputeVelocityFee(id, sender, tradeSize);

        // Total fee in basis points.
        uint24 totalFeeBps = config.baseFeeBps + adaptiveFee + liquidityFee + velocityFee;

        if (totalFeeBps > 3_000) {
            // Hard cap at 30% to avoid pathological behaviour.
            totalFeeBps = 3_000;
        }

        // We do not adjust virtual amounts here (pure fee-based curve),
        // so the BeforeSwapDelta is zero.
        BeforeSwapDelta memory delta = BeforeSwapDelta({amount0: 0, amount1: 0});

        // Selector to indicate successful callback.
        return (IMinimalHook.beforeSwap.selector, delta, totalFeeBps);
    }

    /// @notice Normalize trade size as absolute value of amountSpecified.
    function _normalizedTradeSize(int256 amountSpecified) internal pure returns (uint256) {
        // `-type(int256).min` overflows, so handle it explicitly.
        if (amountSpecified >= 0) return uint256(amountSpecified);
        if (amountSpecified == type(int256).min) return uint256(1) << 255; // abs(-2^255) = 2^255
        return uint256(-amountSpecified);
    }

    /// @notice Adaptive fee component based on trade size.
    /// @dev Implements the qualitative behaviour:
    ///      - Small trades: effectively "flatter" curve (low marginal fee)
    ///      - Large trades: steeper curve (additional fee component)
    function _computeAdaptiveFee(
        bytes32,
        /*id*/
        PoolConfig memory config,
        uint256 tradeSize
    )
        internal
        pure
        returns (uint24)
    {
        if (tradeSize <= config.smallTradeSize) {
            // Extremely small additional fee: effectively flat pricing region.
            return 0;
        }

        if (tradeSize >= config.largeTradeSize) {
            // Apply full large-trade premium.
            return config.largeTradeFeeBps;
        }

        // Between small and large threshold: linearly interpolate.
        uint256 range = uint256(config.largeTradeSize - config.smallTradeSize);
        uint256 pos = tradeSize - config.smallTradeSize;
        uint256 fractionBps = (uint256(config.largeTradeFeeBps) * pos) / range;
        return uint24(fractionBps);
    }

    /// @notice Liquidity-aware fee modulation.
    /// @dev When pool liquidity is low, add extra fee to compensate LPs.
    function _computeLiquidityFee(PoolKey calldata key, PoolConfig memory config) internal view returns (uint24) {
        if (config.lowLiquidityThreshold == 0) return 0;

        uint128 liquidity = poolManager.getLiquidity(key);
        if (liquidity < config.lowLiquidityThreshold) {
            return config.lowLiquidityFeeBps;
        }

        return 0;
    }

    /// @notice Updates trader statistics and returns a velocity-based fee component.
    function _updateTraderAndComputeVelocityFee(bytes32 id, address trader, uint256 tradeSize)
        internal
        returns (uint24)
    {
        VelocityConfig memory vcfg = velocityConfig;
        TraderStats storage stats = traderStats[id][trader];

        uint64 nowTs = uint64(block.timestamp);

        // Reset window if we're outside the configured window.
        if (stats.lastTradeTimestamp == 0 || nowTs - stats.lastTradeTimestamp > vcfg.windowSeconds) {
            stats.tradesInWindow = 0;
            stats.volumeInWindow = 0;
        }

        stats.lastTradeTimestamp = nowTs;
        stats.tradesInWindow += 1;
        stats.volumeInWindow += uint128(tradeSize > type(uint128).max ? type(uint128).max : tradeSize);

        uint24 extraFee = 0;

        bool exceededTrades = stats.tradesInWindow > vcfg.maxTradesInWindow && vcfg.maxTradesInWindow > 0;
        bool exceededVolume = stats.volumeInWindow > vcfg.maxVolumeInWindow && vcfg.maxVolumeInWindow > 0;

        if (exceededTrades || exceededVolume) {
            // Mark trader as suspicious for the duration of the window.
            stats.highFeeUntil = nowTs + vcfg.windowSeconds;
            emit SuspiciousActivity(
                trader,
                // We can't include the PoolKey directly from storage, so just emit key hash via indexed topic.
                // Off-chain, the event topic + pool id can be associated with concrete pools.
                PoolKey({
                    currency0: Currency(address(0)),
                    currency1: Currency(address(0)),
                    fee: 0,
                    tickSpacing: 0,
                    hooks: address(this)
                }),
                stats.tradesInWindow,
                stats.volumeInWindow,
                stats.highFeeUntil
            );
        }

        if (stats.highFeeUntil >= nowTs) {
            extraFee = vcfg.suspiciousActivityFeeBps;
        }

        return extraFee;
    }
}

