// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Official Uniswap v4 core types & interfaces (via local remapping)
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

/// @title LongTailHookV4 — Adaptive Curve Hook integrated with Uniswap v4 core
/// @notice Production-oriented version of LongTailHook using the official v4-core
///         interfaces and types. Designed for specialized, long‑tail markets.
contract LongTailHookV4 is IHooks {
    using PoolIdLibrary for PoolKey;

    /// @notice Configuration per pool.
    struct PoolConfig {
        // Base LP fee in hundredths of a bip (v4 standard).
        uint24 baseFee;
        // Extra fee for very large trades.
        uint24 largeTradeFee;
        // Extra fee when liquidity is low.
        uint24 lowLiquidityFee;
        // Trade size bands (in raw token units of the specified asset).
        uint128 smallTradeSize;
        uint128 largeTradeSize;
        // Below this pool liquidity, the market is considered "thin".
        uint128 lowLiquidityThreshold;
        bool initialized;
    }

    /// @notice Simple per-trader velocity / behaviour tracking.
    struct TraderStats {
        uint64 lastTradeTimestamp;
        uint32 tradesInWindow;
        uint128 volumeInWindow;
        uint64 highFeeUntil;
    }

    /// @notice Global parameters for velocity-based anti‑manipulation.
    struct VelocityConfig {
        uint64 windowSeconds;
        uint32 maxTradesInWindow;
        uint128 maxVolumeInWindow;
        uint24 suspiciousActivityFee;
    }

    /// @notice Emitted whenever a pool config is initialized or updated.
    event PoolConfigUpdated(
        PoolId indexed id,
        uint24 baseFee,
        uint24 largeTradeFee,
        uint24 lowLiquidityFee,
        uint128 smallTradeSize,
        uint128 largeTradeSize,
        uint128 lowLiquidityThreshold
    );

    /// @notice Emitted when suspicious activity is detected for a trader.
    event SuspiciousActivity(
        PoolId indexed id, address indexed trader, uint32 tradesInWindow, uint128 volumeInWindow, uint64 highFeeUntil
    );

    /// @notice PoolManager instance this hook is bound to.
    IPoolManager public immutable manager;

    /// @notice Per-pool configuration keyed by official PoolId.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Per-pool, per-trader stats for the velocity guard.
    mapping(PoolId => mapping(address => TraderStats)) public traderStats;

    /// @notice Global velocity configuration.
    VelocityConfig public velocityConfig;

    /// @notice Admin address allowed to manage configuration.
    address public immutable admin;

    constructor(IPoolManager _manager, address _admin) {
        manager = _manager;
        admin = _admin;
        velocityConfig = VelocityConfig({
            windowSeconds: 60,
            maxTradesInWindow: 5,
            maxVolumeInWindow: 1_000e18,
            suspiciousActivityFee: 50 // +0.50% when suspicious
        });
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "LongTailHookV4: not admin");
        _;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager), "LongTailHookV4: not PoolManager");
        _;
    }

    // ========= Admin configuration =========

    /// @notice Configure pricing / liquidity parameters for a given pool.
    function setPoolConfig(
        PoolKey calldata key,
        uint24 baseFee,
        uint24 largeTradeFee,
        uint24 lowLiquidityFee,
        uint128 smallTradeSize,
        uint128 largeTradeSize,
        uint128 lowLiquidityThreshold
    ) external onlyAdmin {
        require(baseFee <= 1_000_000, "LongTailHookV4: base fee too high");
        require(largeTradeFee <= 1_000_000, "LongTailHookV4: large fee too high");
        require(lowLiquidityFee <= 1_000_000, "LongTailHookV4: low liq fee too high");
        require(smallTradeSize < largeTradeSize, "LongTailHookV4: invalid size band");

        PoolId id = key.toId();
        poolConfig[id] = PoolConfig({
            baseFee: baseFee,
            largeTradeFee: largeTradeFee,
            lowLiquidityFee: lowLiquidityFee,
            smallTradeSize: smallTradeSize,
            largeTradeSize: largeTradeSize,
            lowLiquidityThreshold: lowLiquidityThreshold,
            initialized: true
        });

        emit PoolConfigUpdated(
            id, baseFee, largeTradeFee, lowLiquidityFee, smallTradeSize, largeTradeSize, lowLiquidityThreshold
        );
    }

    /// @notice Configure global velocity-based anti-manipulation parameters.
    function setVelocityConfig(
        uint64 windowSeconds,
        uint32 maxTradesInWindow,
        uint128 maxVolumeInWindow,
        uint24 suspiciousActivityFee
    ) external onlyAdmin {
        require(windowSeconds > 0, "LongTailHookV4: window 0");
        require(suspiciousActivityFee <= 10_000, "LongTailHookV4: suspicious fee too high");

        velocityConfig = VelocityConfig({
            windowSeconds: windowSeconds,
            maxTradesInWindow: maxTradesInWindow,
            maxVolumeInWindow: maxVolumeInWindow,
            suspiciousActivityFee: suspiciousActivityFee
        });
    }

    // ========= Core hook: dynamic, specialized fee logic =========

    /// @inheritdoc IHooks
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /*hookData*/
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory config = poolConfig[id];
        require(config.initialized, "LongTailHookV4: pool not configured");

        uint256 tradeSize = _normalizedTradeSize(params.amountSpecified);

        uint24 adaptiveFee = _computeAdaptiveFee(config, tradeSize);
        uint24 liquidityFee = _computeLiquidityFee(key, id, config);
        uint24 velocityFee = _updateTraderAndComputeVelocityFee(id, sender, tradeSize);

        uint24 totalFee = config.baseFee + adaptiveFee + liquidityFee + velocityFee;
        if (totalFee > 30_000) {
            // Hard cap at 30% to avoid pathological behaviour.
            totalFee = 30_000;
        }

        // Write the specialized LP fee into the pool via the official dynamic fee mechanism.
        manager.updateDynamicLPFee(key, totalFee);

        // We do not return a BeforeSwapDelta (no custom curve override), and we do not use
        // the per-swap LP fee override channel; all behaviour is via updateDynamicLPFee.
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ========= Internal helpers =========

    function _normalizedTradeSize(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified >= 0 ? uint256(amountSpecified) : uint256(-amountSpecified);
    }

    /// @notice Adaptive fee based on trade size bands.
    function _computeAdaptiveFee(PoolConfig memory config, uint256 tradeSize) internal pure returns (uint24) {
        if (tradeSize <= config.smallTradeSize) {
            // Very small trades: keep the curve flat, no extra fee.
            return 0;
        }

        if (tradeSize >= config.largeTradeSize) {
            // Large trades: full premium to steepen the curve.
            return config.largeTradeFee;
        }

        // Linear interpolation between 0 and largeTradeFee.
        uint256 range = uint256(config.largeTradeSize - config.smallTradeSize);
        uint256 pos = tradeSize - config.smallTradeSize;
        uint256 fraction = (uint256(config.largeTradeFee) * pos) / range;
        return uint24(fraction);
    }

    /// @notice Liquidity-aware fee via StateLibrary + PoolId.
    function _computeLiquidityFee(PoolKey calldata key, PoolId id, PoolConfig memory config)
        internal
        view
        returns (uint24)
    {
        if (config.lowLiquidityThreshold == 0) return 0;

        uint128 liq = StateLibrary.getLiquidity(manager, id);
        if (liq < config.lowLiquidityThreshold) {
            return config.lowLiquidityFee;
        }

        return 0;
    }

    /// @notice Velocity-based anti-manipulation surcharge.
    function _updateTraderAndComputeVelocityFee(PoolId id, address trader, uint256 tradeSize)
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

        bool exceededTrades = vcfg.maxTradesInWindow > 0 && stats.tradesInWindow > vcfg.maxTradesInWindow;
        bool exceededVolume = vcfg.maxVolumeInWindow > 0 && stats.volumeInWindow > vcfg.maxVolumeInWindow;

        if (exceededTrades || exceededVolume) {
            stats.highFeeUntil = nowTs + vcfg.windowSeconds;
            emit SuspiciousActivity(id, trader, stats.tradesInWindow, stats.volumeInWindow, stats.highFeeUntil);
        }

        if (stats.highFeeUntil >= nowTs) {
            return vcfg.suspiciousActivityFee;
        }

        return 0;
    }

    // ========= Required IHooks functions (unused callbacks revert) =========

    error HookNotImplemented();

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

