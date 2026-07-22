# Position Manager

The `PositionManager` aggregates multiple `IBorrowPosition` contracts (Morpho Blue positions with individual LLTVs) into a single ERC20-share vault. Depositors put in collateral, receive borrowed debt back, and hold shares in the net value of all positions:

```
totalAssets = Σ collateralQuoted - Σ debt
```

where `collateralQuoted` is each position's collateral valued in debt-asset terms through its oracle.

Two ordered queues drive routing. The **supply queue** holds `(position, maxBorrow)` pairs and decides where deposits land and how much each position may borrow per deposit. The **withdrawal queue** holds position addresses and decides the order in which debt is repaid and collateral withdrawn. Only positions registered as borrow modules (`addBorrowModule`, owner-only) may appear in either queue or in rebalancing operations.

## Shares

Share accounting uses a virtual offset to make first-depositor inflation attacks unprofitable (same idea as ERC4626 virtual shares). The offset is decimal-dependent, `virtualShareOffset = 10^(18 - debtDecimals)`, so shares always have 18 decimals (1e12 for a 6-decimal debt asset, 1 for an 18-decimal one, where the protection is weakest; see [Known Issues](known-issues.md#position-manager)):

```
shares = assets * (totalSupply + virtualShareOffset) / (totalAssets + 1)
assets = shares * (totalAssets + 1) / (totalSupply + virtualShareOffset)
```

Fees are accrued before every operation, then shares are minted or burned based on how the operation changed total assets.

## Deposit

`deposit(collateral, debt)` pulls collateral, distributes it across the supply queue, and sends the borrowed debt back to the caller. For each queue entry the borrow is capped by the market's available liquidity, the entry's `maxBorrow`, and the remaining requested debt; the position then reports how much collateral that borrow needs at the manager's target LTV (`collateralForBorrow`). If the remaining collateral cannot support the borrow, the borrow is reduced to what it supports (`borrowForCollateral`). Leftover collateral not needed for borrowing is supplied to the first queue position; if the requested debt cannot be reached, the deposit reverts with `InsufficientBorrowCapacity`.

Both helper functions account for the position's existing collateral and debt, so a position sitting below target LTV can take on new borrows without fresh collateral.

## Withdraw

`withdraw(collateral, debt)` pulls the debt amount from the caller, repays it through the withdrawal queue, then withdraws the requested collateral through the same queue and sends it back. A position only releases collateral it does not need to stay healthy:

```
availableCollateral = totalCollateral - debt * ORACLE_PRICE_SCALE / (lltv * collateralPrice)
```

## Burn

`burn(shares)` exits proportionally: it computes the caller's share of total collateral (rounded down) and total debt (rounded up), burns the shares, pulls the debt for repayment, and walks the withdrawal queue repaying and withdrawing proportionally from each position.

## Rebalancing

`rebalance(data)` lets the rebalancer role redistribute collateral and debt across positions without touching shares. The call supplies optional collateral/debt to pull from the caller plus a list of `(position, operation, amount)` steps, where the operation is REPAY, WITHDRAW, BORROW, or SUPPLY; excess tokens return to the caller at the end. Example, moving liquidity from position A to B:

```solidity
RebalancingData({
    collateral: 0,
    debt: 1000, // pulled from the caller to fund the repay
    operations: [
        (positionA, REPAY, 1000),
        (positionA, WITHDRAW, 2000),
        (positionB, SUPPLY, 2000),
        (positionB, BORROW, 1000)
    ]
})
```

Rebalancing may not decrease total assets by more than the owner-set max rebalance loss, and reverts while the transfer guard has the manager paused.

The flash-loan rebalancer contracts that drive this entry point are described in [Retargetter](retargetter.md).

## Fees

Both fees are taken by minting shares to the fee recipient, diluting holders. Accrual runs before every deposit, withdraw, burn, and rebalance. Throughout, "collateral" means quoted collateral aggregated over the positions that are *not* in bad debt (debt exceeding their quoted collateral); bad-debt positions are excluded from every fee basis.

### Management fee

The management fee (basis points per year) accrues on aggregate good-debt collateral:

```
managementFeeAssets = currentCollat * managementFee * elapsed / (BPS * SECONDS_PER_YEAR)
```

capped at `totalAssets` so the post-fee base stays non-negative. For an unlevered vault this matches a plain NAV-based fee; for a levered vault the collateral basis is a leverage multiple of the NAV, which fee-setters should account for when choosing the rate. The rate applies to the live basis over the full elapsed period, a deliberate simplification (see [Known Issues](known-issues.md#position-manager)).

### Performance fee

The performance fee (basis points) is charged on the performance of the levered slice only. The basis compares the collateral growth that leverage financed against the debt growth that financed it, anchored at a stored reference snapshot's LTV (`lastDebt / lastCollat`):

```
basis = LTV_ref * Δcollat - Δdebt
      = mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt
performanceFeeAssets = max(0, basis - managementFeeAssets) * performanceFee / BPS
```

with `lastCollat = lastTotalAssets + lastDebt` and `currentCollat = currentTotalAssets + currentDebt`. Anchoring on the reference LTV fixes the unlevered baseline at the start of the period, which is the natural comparison for "extra return from leverage", and fixes the multiplier at reference time, so the basis depends only on the stored reference and the current aggregates, never on the live LTV. The anchoring also biases the basis larger when collateral appreciates faster than debt accrues (the common case), and `mulDivUp` biases it slightly further in the protocol's favor, consistent with rounding elsewhere. `lastCollat` is reconstructed from the two stored fields rather than stored itself, keeping the storage layout append-only.

Both `lastDebt` and `currentDebt` come from each module's `totalBorrowed()`, which returns `toAssetsDown(borrowShares)`: the same rounding Morpho applies internally when converting borrow shares to debt assets. The value is the exact debt the underlying market recognizes in asset terms, not a 1-wei understatement, so `collateral - debt` matches the NAV Morpho itself attributes to the position, and the fee basis inherits Morpho's rounding with no additional bias.

The combined fee assets can never exceed `totalAssets`: the management fee is capped there explicitly, and the performance basis is bounded because `mulDivUp(lastDebt, currentCollat, lastCollat) <= currentCollat` whenever `lastDebt <= lastCollat`, with the performance rate at most 100%. The accrual still guards the boundary defensively: when fee assets would consume the entire asset base, nothing is minted (converting against a zero base would mint an inflated share count that confiscates the pool), while the accrual timestamp and reference still update.

### The reference as a high-water mark

The reference `(lastTotalAssets, lastDebt)` only **advances** when the basis is positive, on bootstrap, or when the vault empties. A positive basis advances the reference whether or not shares are actually minted: with a zero performance rate or no fee recipient set, the advance happens mintlessly, so gains realized before fees are enabled are never retroactively charged once they are. On a negative or zero basis the reference is **held**, so drawdowns and interest-driven debt growth (debt carry) stay inside the basis and the fee only crystallizes once the levered slice has genuinely out-earned its debt again; the reference behaves as a high-water mark. Holding also matters when the collateral oracle reprices only periodically: debt interest accrued while the quote is flat stays in the basis, so the next repricing is charged net of the full inter-repricing debt carry rather than only the last interval's.

Two companion mechanisms keep holding sound:

- **Held management fees.** Management fees keep accruing while the reference is held (they are time-based, so the accrual timestamp always advances). The charged amounts accumulate in `heldManagementFeeAssets` and are deducted from the next performance crystallization, then cleared when the reference finally advances or is reset. Across flows the accumulator is scaled with the position, with one exception: when rescuing out of a full bad-debt episode (previous collateral zero) the scaling is skipped, because the supply ratio is unmoored.
- **Rebasing across flows.** Deposits, withdrawals, and burns change the position without being performance. Each flow rebases the reference proportionally so the carried per-share basis is preserved: exiting shares take their slice of the carried drawdown with them, and entering shares do not inherit it. Rebalances are flows too (supply unchanged, basis preserved, nothing crystallizes). Since accrual runs before every flow, the carry is non-positive outside bad-debt windows.

**Bootstrap sentinel.** `lastDebt == 0` marks an uninitialized reference: the first accrual with the sentinel set skips the performance fee and seeds the reference from the current state. The sentinel is written by full debt repayment, by the carry clamp in the rebase (when the carried basis floors the reference debt at zero), or by an owner reset during a full bad-debt episode; only those paths cause the skip-one-accrual behavior. An all-bad-debt accrual does *not* write it: the aggregates read zero but the pre-episode reference is held, and rebases that would leave the good-debt universe empty early-return for the same reason, precisely so the high-water mark is never reseeded at the trough of an episode. A rescue flow that brings the pool back above water re-anchors the reference at its post-flow state, and gains recovered beyond that point are charged.

**Partial bad-debt windows.** While *some* module is in bad debt, the basis is not measurable: the excluded module's debt is missing from `currentDebt`, which deleverages the visible aggregate and can flip the basis positive in the middle of a drawdown. Accruals therefore hold the reference for the duration. Flows inside such a window, however, must re-anchor against the reduced aggregates, and that re-anchor is not direction-safe: a flow that leaves the visible LTV at or below the frozen reference LTV under-reads the later recovery (LP-favorable; fees resume at a genuine new high), while a flow that raises it above the mark over-reads the recovery and can charge it as gain. The over-reading flows are a deposit with fresh borrowing during the window, a rebalance that borrows, and above all a rescue repayment that pulls the excluded module back above water mid-flow (the re-anchor then adopts the re-entered module's near-100% LTV). `resetPerformanceReference` does *not* correct an over-read, because the reset crystallizes the positive pending basis before moving the reference; instead, set the performance rate to zero right after such a flow, let the first accrual with a positive basis advance the reference mintlessly, then restore the rate. An under-read needs no action.

**Reset.** `resetPerformanceReference()` is the owner's escape hatch for permanent drawdowns: it accrues first (so past gains crystallize before the move, and it can never mint on them twice), then re-anchors the reference at the current state, forgiving the carried basis and the held management-fee deduction. Under bad debt it behaves differently: with every module excluded, the aggregates read zero, so the reset writes the bootstrap sentinel and the next accrual reseeds from whatever it observes; with only some modules excluded, the reset anchors on the reduced good-debt universe, so an excluded module that later recovers re-enters the basis as new gain and is charged (the reset accepted that module's loss). On timing: the reset forgives all carried basis, including debt interest accrued since the last crystallization and the pending management-fee deduction, and the next positive accrual then overcharges by exactly the forgiven amounts; call it as soon as possible after a positive performance-fee charge, when the pending carry and deduction are smallest.

## Transfer Guard

An optional [TransferGuard](transfer-guard.md) can be attached. When set, every share transfer is validated through it, deposits and withdrawals are blocked while the manager's token is paused, and rebalancing reverts with `Paused()`.
