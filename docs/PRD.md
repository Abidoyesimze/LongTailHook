---

# LongTailHook — Adaptive Curve for Illiquid and Long-Tail Token Markets

## Novelty
Long-tail tokens on standard AMMs suffer from **severe slippage** due to low liquidity.  
LongTailHook introduces a **custom pricing curve optimized specifically for low-liquidity assets**, creating a new primitive for trading illiquid tokens.

---

## How It Works

### Custom Adaptive Bonding Curve
The hook implements a **custom bonding curve inside the `beforeSwap` callback** that dynamically adjusts pricing behavior:

- The curve **flattens at the extremes**  
  → reduces slippage for **small trades**

- The curve **steepens sharply for large trades**  
  → protects the pool from **large manipulation trades**

This adaptive curve improves price discovery while protecting liquidity providers.

---

### Dynamic Fee Structure

Fees automatically adjust based on **liquidity conditions**:

- **Low Liquidity**
  - Higher trading fees
  - Compensates LPs for increased risk

- **Deep Liquidity**
  - Lower trading fees
  - Encourages trading volume

This creates a natural incentive balance between **LP risk and market activity**.

---

### Anti-Manipulation Mechanism

The hook tracks **trade velocity and behavioral patterns**:

- Monitors rapid trade bursts
- Detects potential **price manipulation or sandwich patterns**
- Temporarily **raises swap fees during suspicious activity**

This discourages attackers and protects the integrity of the pool.

---

## Target Use Cases

LongTailHook is designed for assets that typically struggle with liquidity:

- **Memecoins**
- **New project tokens**
- **Early-stage DeFi tokens**
- **Niche ecosystem tokens**

---

## Impact

Long-tail tokens represent the **majority of tokens deployed on-chain by count**.

Improving trading conditions for these assets:

- Enhances **price discovery**
- Improves **capital efficiency**
- Expands **market accessibility for new projects**
- Strengthens the overall **DeFi ecosystem**
