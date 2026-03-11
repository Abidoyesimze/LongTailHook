## LongTailHook — Adaptive Liquidity for Long‑Tail & Specialized Markets

LongTailHook is a Uniswap v4‑style hook system designed specifically for **illiquid, long‑tail, and specialized asset markets** (memecoins, new project tokens, niche DeFi, RWAs, etc.).

Instead of treating every pool the same, LongTailHook lets you **tune pricing and fees per market**:

- **Adaptive trade‑size aware curve** (via dynamic LP fees)
- **Liquidity‑aware fee modulation**
- **Velocity‑based anti‑manipulation guard**
- **Per‑pool, per‑asset configuration** for specialized markets

This repository contains:

- `LongTailHook` — a **standalone prototype** with minimal v4‑like types (no external deps needed).
- `LongTailHookV4` — a **fully integrated Uniswap v4 core hook** using official `v4-core` interfaces and types.

---

## 🏆 Uniswap Hook Incubator (UHI) 8 Hookathon — Specialized Markets Track

**LongTailHook is built for UHI8 (January–March 2026): Specialized Markets**

**Focus: Asset-Class Specific Liquidity**

The first Hookathon of 2026 challenges builders to create bespoke liquidity systems tailored to specific assets, trade sizes, and chains. Generic AMMs served DeFi well in its early days, but **the future belongs to specialized markets optimized for their unique use cases**.

### How LongTailHook Addresses UHI8 Goals

LongTailHook embodies the **specialized markets** philosophy by providing:

1. **Asset-Class Specific Configuration**
   - Each pool can be tuned independently for its unique characteristics
   - Memecoins, RWAs, LSTs, niche tokens — each gets optimized parameters
   - No one-size-fits-all approach

2. **Trade-Size Optimization**
   - Different fee structures for retail vs. institutional trades
   - Adaptive curves that respond to market depth and trade patterns
   - Protection mechanisms tailored to each asset's volatility profile

3. **Chain-Specific Adaptations**
   - Velocity-based anti-manipulation tuned for high-MEV vs. low-MEV environments
   - Liquidity thresholds adjusted for L1 vs. L2 characteristics
   - Configurable parameters that adapt to different network conditions

4. **Market Maturity Awareness**
   - Early-stage tokens: Higher protection, steeper curves for large trades
   - Mature specialized assets: Lower barriers, optimized for volume
   - Dynamic adjustment based on real-time liquidity conditions

LongTailHook enables **bespoke liquidity systems** where each market is optimized for its specific asset class, trade patterns, and chain environment — exactly what UHI8's specialized markets track envisions.

---

## Problem & Approach

### **Problem**

Long‑tail and specialized assets (memecoins, new launches, niche tokens) suffer from:

- **Severe slippage** for small trades due to low liquidity.
- **High manipulation risk** from large trades and MEV/sandwich attacks.
- **Poor capital efficiency** because generic AMM curves aren’t tuned for these markets.

### **Approach**

LongTailHook implements **per‑pool logic** that:

- **Flattens the effective curve** for **small trades**  
  → lower marginal fees, smoother price for retail‑sized swaps.

- **Steepens the effective curve** for **large trades**  
  → higher marginal fees for size, protecting LPs and resisting manipulation.

- **Increases fees when liquidity is thin**  
  → compensates LPs and discourages over‑sized trades in fragile pools.

- **Detects rapid, bursty behaviour** and temporarily raises fees  
  → discourages sandwich/MEV patterns and manipulation.

All of this is configurable **per pool**, so you can create **specialized market profiles** for different asset classes and chains.

---

## Repository Layout

- **Core source**
  - `src/LongTailHook.sol`  
    Standalone prototype hook with a minimal, local v4‑style type layer (`ILongTailHookTypes.sol`).  
    Useful for understanding the logic in isolation and running simple Foundry tests.

  - `src/LongTailHookV4.sol`  
    Full **Uniswap v4 core integrated** hook:
    - Imports official `IPoolManager`, `IHooks`, `PoolKey`, `PoolId`, `BeforeSwapDelta`, `BalanceDelta`, `Currency`, and `StateLibrary` from `lib/v4-core`.
    - Implements the **real `IHooks` interface** (all callbacks).

  - `src/ILongTailHookTypes.sol`  
    Minimal type definitions used only by `LongTailHook` (prototype):
    - `Currency`, `PoolKey`, `SwapParams`, `BeforeSwapDelta`
    - `IPoolManagerMinimal`, `HookFlags`, `IMinimalHook`

- **Scripts**
  - `script/Counter.s.sol`  
    Deployment script for `LongTailHookV4`:
    - Imports `IPoolManager` from `lib/v4-core`.
    - Deploys `LongTailHookV4` with a given PoolManager address.

- **Tests**
  - `test/Counter.t.sol`  
    Reused as `LongTailHookTest`:
    - Contains tests for the **prototype** `LongTailHook`:
      - Adaptive fee by trade size
      - Liquidity‑aware fee behaviour
      - Velocity‑based anti‑manipulation

- **Dependencies**
  - `lib/forge-std` — Foundry standard library.
  - `lib/v4-core` — Uniswap v4 core.
  - `lib/v4-periphery` — Uniswap v4 periphery.

---

## Architecture

### **1. Per‑pool configuration (specialized per market)**

Both `LongTailHook` and `LongTailHookV4` define a **per‑pool configuration struct**:

- **`PoolConfig`** (per pool / `PoolId`):
  - **`baseFee` / `baseFeeBps`**: baseline LP fee for this pool.
  - **`largeTradeFee` / `largeTradeFeeBps`**: extra fee for very large trades, to steepen the effective curve and protect LPs.
  - **`lowLiquidityFee` / `lowLiquidityFeeBps`**: extra fee applied when pool liquidity is below a threshold.
  - **`smallTradeSize`**: threshold below which trades are considered “small” (retail).
  - **`largeTradeSize`**: threshold above which trades are considered “large” (whale / concentrated).
  - **`lowLiquidityThreshold`**: liquidity threshold under which the market is considered thin.
  - **`initialized`**: ensures the pool is explicitly configured before use.

This lets you **tune behaviour per asset‑class & pool**, e.g.:

- Memecoin pool on L2: large `largeTradeFee`, small `smallTradeSize`, relatively low `lowLiquidityThreshold`.
- RWA or LST pool: lower spread between small and large trade fees, higher liquidity threshold.

In `LongTailHookV4`, configs are stored as:

- `mapping(PoolId => PoolConfig) public poolConfig;`

with `PoolId` derived via `PoolIdLibrary.toId(PoolKey)`.

---

### **2. Adaptive fee by trade size (trade‑size aware “curve”)**

Rather than implementing a new mathematical invariant, LongTailHook reshapes the **effective pricing** using **dynamic LP fees**.

- **Trade size calculation**:
  - Use the absolute value of `amountSpecified` from swap parameters.
  - For v4: `IPoolManager.SwapParams.amountSpecified`.

- **Adaptive fee logic**:
  - If `tradeSize <= smallTradeSize`:
    - **Extra fee = 0** → “flat” region: small traders experience lower marginal cost.
  - If `tradeSize >= largeTradeSize`:
    - **Extra fee = largeTradeFee`** → “steep” region: big traders pay more.
  - In between:
    - Linearly interpolate between 0 and `largeTradeFee`.

This directly implements the PRD idea:

- **Flattened curve at extremes (small trades)** → lower effective slippage.
- **Steep curve for large trades** → LP protection and manipulation resistance.

In `LongTailHookV4`, the total adaptive + liquidity + velocity fee is applied via:

- `manager.updateDynamicLPFee(key, totalFee);`

which is the **official v4 mechanism** for dynamic pool fees.

---

### **3. Liquidity‑aware fee modulation**

To align incentives with liquidity conditions:

- **When liquidity is deep**:
  - No `lowLiquidityFee` component → fees closer to `baseFee`, encouraging volume.

- **When liquidity is thin**:
  - Add `lowLiquidityFee` on top to compensate LPs and discourage outsized trades.

Implementation in `LongTailHookV4`:

- Uses `StateLibrary.getLiquidity(manager, poolId)` to retrieve current pool liquidity.
- Compares against `lowLiquidityThreshold` from `PoolConfig`.
- Adds `lowLiquidityFee` only when `liquidity < lowLiquidityThreshold`.

This is what makes the hook **asset‑class & pool‑specific**: you can define:

- Higher sensitivity and fees for very illiquid memecoins.
- Lower sensitivity for more robust specialized assets.

---

### **4. Velocity‑based anti‑manipulation guard**

To address **trade bursts, MEV, and sandwich‑like behaviour**, LongTailHook tracks **per‑trader velocity**.

- **`VelocityConfig`** (global):
  - `windowSeconds`: rolling window length.
  - `maxTradesInWindow`: max allowed trades per trader per pool in window.
  - `maxVolumeInWindow`: max allowed traded volume in window.
  - `suspiciousActivityFee`: extra fee applied when trader is deemed suspicious.

- **`TraderStats`** (per `PoolId` + trader):
  - `lastTradeTimestamp`
  - `tradesInWindow`
  - `volumeInWindow`
  - `highFeeUntil` (timestamp until which suspicious fee applies).

Logic:

1. On each swap:
   - If current time is outside `[lastTradeTimestamp + windowSeconds]`, reset counters.
   - Increment `tradesInWindow`.
   - Add trade size to `volumeInWindow`.

2. If `tradesInWindow > maxTradesInWindow` or `volumeInWindow > maxVolumeInWindow`:
   - Mark trader as suspicious: set `highFeeUntil = now + windowSeconds`.
   - Emit `SuspiciousActivity` event.

3. While `block.timestamp <= highFeeUntil`:
   - Add `suspiciousActivityFee` to the total fee.

This creates a **soft rate‑limiting mechanism**:

- Normal users (few trades, modest size) are unaffected.
- Bursty or heavy traders temporarily pay more, making **attack patterns more expensive**.

---

### **5. v4‑core integration (`LongTailHookV4`)**

`LongTailHookV4` is the production‑oriented version that directly integrates with **Uniswap v4 core**.

- **Implements `IHooks` directly**:
  - All callbacks are present; only `beforeSwap` is fully implemented.
  - The others intentionally `revert HookNotImplemented()` to make unsupported hooks explicit.

- **Bound to a specific `IPoolManager`**:
  - Constructor takes `IPoolManager _manager`.
  - `onlyPoolManager` modifier ensures only the PoolManager can call hook functions.

- **Dynamic fee application**:
  - Computes a **single total LP fee** per swap:
    - `totalFee = baseFee + adaptiveFee + liquidityFee + velocityFee`
    - Hard‑capped (e.g. 30%).
  - Calls:
    - `manager.updateDynamicLPFee(key, totalFee);`
  - Returns:
    - `BeforeSwapDeltaLibrary.ZERO_DELTA` (no custom delta)
    - `0` for the per‑swap override (behaviour is via dynamic fee).

This is fully compatible with v4’s **dynamic LP fee** mechanism and leverages the core contract logic for all other AMM behaviour.

---

## Development: Getting Started

### **Prerequisites**

- **Foundry** (Forge, Anvil, Cast).
- Git (for managing submodules / dependencies).

### **Install dependencies**

If you haven’t already:

```bash
forge install uniswap/v4-core uniswap/v4-periphery --commit
```

> Note: This repo already contains `lib/v4-core` and `lib/v4-periphery`. You typically don’t need to rerun `forge install` unless you’re updating versions.

### **Build & Test**

- **Build**:

```bash
forge build
```

- **Run tests**:

```bash
forge test
```

You should see:

- `LongTailHookTest` (in `test/Counter.t.sol`) passing:
  - Small vs medium trade fee behaviour
  - Large trade fee behaviour
  - Low‑ vs high‑liquidity fee behaviour
  - Velocity guard raising fees on burst activity

---

## Using LongTailHookV4 in a Real v4 Deployment

### **1. Deploy the hook**

In `script/Counter.s.sol`:

- Update the `IPoolManager` address to your actual v4 PoolManager deployment.
- Then run:

```bash
forge script script/Counter.s.sol:LongTailHookV4Script \
  --rpc-url <YOUR_RPC_URL> \
  --private-key <YOUR_PRIVATE_KEY> \
  --broadcast
```

This will deploy `LongTailHookV4` and print its address.

> For full production deployment, you’ll also typically:
> - Use a **hook miner** to find a hook address with the correct permission bits set (according to v4 `Hooks` address encoding).
> - Plug that deterministic address into your deployment flow.

### **2. Configure a pool (specialized per market)**

Once the pool is created (with your hook address included in its `PoolKey`), configure it:

```solidity
hook.setPoolConfig(
    poolKey,
    1000,        // baseFee
    2000,        // largeTradeFee
    1500,        // lowLiquidityFee
    1e18,        // smallTradeSize
    100e18,      // largeTradeSize
    1_000e18     // lowLiquidityThreshold
);
```

Then configure velocity:

```solidity
hook.setVelocityConfig(
    60,          // windowSeconds
    5,           // maxTradesInWindow
    1_000e18,    // maxVolumeInWindow
    50           // suspiciousActivityFee (0.5% extra)
);
```

Interpretation:

- Small trades (≤ `1e18` units) are cheap.
- Large trades (≥ `100e18` units) pay maximum premium.
- When liquidity < `1_000e18`, `lowLiquidityFee` kicks in.
- Traders doing >5 trades or >1,000 tokens in 60s pay extra `suspiciousActivityFee`.

---

## Specialized Market Profiles for UHI8

LongTailHook enables **bespoke liquidity configurations** for different asset classes. Here are example profiles for UHI8's specialized markets track:

### **Memecoin Profile** (High Volatility, Low Liquidity)

Optimized for early-stage memecoins with high volatility and low initial liquidity:

```solidity
hook.setPoolConfig(
    memecoinPoolKey,
    2000,        // baseFee: 0.20% (higher baseline for risk)
    5000,        // largeTradeFee: 0.50% (steep penalty for large trades)
    3000,        // lowLiquidityFee: 0.30% (significant protection when thin)
    0.1e18,      // smallTradeSize: Very small threshold (retail-friendly)
    10e18,       // largeTradeSize: Moderate threshold (protect from whales)
    500e18       // lowLiquidityThreshold: Low threshold (sensitive to liquidity)
);

hook.setVelocityConfig(
    30,          // windowSeconds: Short window (30s) for rapid detection
    3,           // maxTradesInWindow: Very low (3 trades) - aggressive
    50e18,       // maxVolumeInWindow: Low volume threshold
    100          // suspiciousActivityFee: 0.10% extra fee
);
```

**Rationale**: Memecoins need aggressive protection from manipulation, so we use steep fees for large trades, short velocity windows, and low liquidity thresholds.

### **RWA Profile** (Stable, Institutional Focus)

Optimized for Real-World Assets with more stable pricing and institutional trade sizes:

```solidity
hook.setPoolConfig(
    rwaPoolKey,
    500,         // baseFee: 0.05% (lower baseline - mature market)
    1000,        // largeTradeFee: 0.10% (moderate premium)
    800,         // lowLiquidityFee: 0.08% (moderate protection)
    10e18,       // smallTradeSize: Higher threshold (institutional focus)
    1000e18,     // largeTradeSize: Very high threshold (whale trades)
    10_000e18    // lowLiquidityThreshold: High threshold (expect deeper liquidity)
);

hook.setVelocityConfig(
    300,         // windowSeconds: Longer window (5 min) - less aggressive
    10,          // maxTradesInWindow: Higher limit
    10_000e18,   // maxVolumeInWindow: High volume threshold
    25           // suspiciousActivityFee: 0.025% extra fee (lower)
);
```

**Rationale**: RWAs are more stable, so we use gentler curves, higher thresholds, and longer velocity windows suitable for institutional trading patterns.

### **LST Profile** (Liquid Staking Tokens, High Volume)

Optimized for Liquid Staking Tokens that need high volume and tight spreads:

```solidity
hook.setPoolConfig(
    lstPoolKey,
    300,         // baseFee: 0.03% (very low - encourage volume)
    600,         // largeTradeFee: 0.06% (minimal premium)
    500,         // lowLiquidityFee: 0.05% (light protection)
    50e18,       // smallTradeSize: High threshold (institutional)
    5000e18,     // largeTradeSize: Very high threshold
    50_000e18    // lowLiquidityThreshold: Very high (expect deep liquidity)
);

hook.setVelocityConfig(
    60,          // windowSeconds: Standard window
    20,          // maxTradesInWindow: High limit (allow high frequency)
    100_000e18,  // maxVolumeInWindow: Very high threshold
    20           // suspiciousActivityFee: 0.02% extra fee (minimal)
);
```

**Rationale**: LSTs need maximum volume and tight spreads, so fees are minimized and velocity limits are relaxed for high-frequency trading.

### **Early-Stage DeFi Token Profile** (Moderate Risk)

Balanced profile for new DeFi project tokens:

```solidity
hook.setPoolConfig(
    defiTokenPoolKey,
    1000,        // baseFee: 0.10% (moderate baseline)
    2500,        // largeTradeFee: 0.25% (moderate protection)
    1500,        // lowLiquidityFee: 0.15% (balanced protection)
    1e18,        // smallTradeSize: Standard threshold
    100e18,      // largeTradeSize: Standard threshold
    5_000e18     // lowLiquidityThreshold: Moderate threshold
);

hook.setVelocityConfig(
    60,          // windowSeconds: Standard window
    5,           // maxTradesInWindow: Moderate limit
    5_000e18,    // maxVolumeInWindow: Moderate threshold
    50           // suspiciousActivityFee: 0.05% extra fee
);
```

**Rationale**: Balanced approach suitable for tokens with moderate volatility and growing liquidity.

### **Chain-Specific Considerations**

- **High-MEV Chains (Ethereum Mainnet)**: Use shorter velocity windows (30s) and lower trade/volume thresholds
- **Low-MEV Chains (L2s, Appchains)**: Use longer velocity windows (60-300s) and higher thresholds
- **New Chains**: Start with conservative memecoin-like profiles, then adjust as liquidity matures

---

## Notes / Next Steps

- **Profile Helper Functions**:  
  Consider adding convenience functions like `setMemecoinProfile(poolKey)`, `setRWAProfile(poolKey)`, etc. that wrap `setPoolConfig` and `setVelocityConfig` with the above defaults.

- **Front‑end integration**:  
  Expose view helpers (e.g. `quoteEffectiveFeeBps(poolKey, tradeSize)`) to let UIs preview how fees change with trade size and liquidity.

- **Security & audits**:  
  Before use in production, have the contracts reviewed and consider fuzz/property‑based testing using the v4‑core test harness.

LongTailHook is built to be a **specialized liquidity primitive** for markets where generic AMMs struggle — especially long‑tail tokens and asset‑class‑specific venues. It’s ready to be extended, profiled, and deployed into real Uniswap v4 ecosystems.

