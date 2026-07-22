# Position Manager

The `PositionManager` aggregates multiple `IBorrowPosition` contracts (Morpho Blue positions with individual LLTVs) into a single ERC20-share vault. Depositors put in collateral, receive borrowed debt back, and hold shares in the net value of all positions:

```
totalAssets = Σ collateralQuoted - Σ debt
```

where `collateralQuoted` is each position's collateral valued in debt-asset terms through its oracle.

Two ordered queues drive routing. The **supply queue** holds `(position, maxBorrow)` pairs and decides where deposits land and how much each position may borrow per deposit. The **withdrawal queue** holds position addresses and decides the order in which debt is repaid and collateral withdrawn. Only positions registered as borrow modules (`addBorrowModule`, owner-only) may appear in either queue or in rebalancing operations.

## Shares

Share accounting uses a virtual offset to make first-depositor inflation attacks unprofitable (same idea as ERC4626 virtual shares):

```
shares = assets * (totalSupply + 1e6) / (totalAssets + 1)
assets = shares * (totalAssets + 1) / (totalSupply + 1e6)
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

capped at `totalAssets` so the post-fee base stays non-negative. For an unlevered vault this matches a plain NAV-based fee. The rate applies to the live basis over the full elapsed period, a deliberate simplification (see [Known Issues](known-issues.md#position-manager)).

### Performance fee

The performance fee (basis points) is charged on the performance of the levered slice only. The basis compares the collateral growth that leverage financed against the debt growth that financed it, anchored at a stored reference snapshot's LTV (`lastDebt / lastCollat`):

```
basis = LTV_ref * Δcollat - Δdebt
      = mulDivUp(lastDebt, currentCollat, lastCollat) - currentDebt
performanceFeeAssets = max(0, basis - managementFeeAssets) * performanceFee / BPS
```

with `lastCollat = lastTotalAssets + lastDebt` and `currentCollat = currentTotalAssets + currentDebt`. Anchoring on the reference LTV fixes the unlevered baseline at the start of the period, which is the natural comparison for "extra return from leverage"; `mulDivUp` biases the basis slightly in the protocol's favor, consistent with rounding elsewhere. `lastCollat` is reconstructed from the two stored fields rather than stored itself, keeping the storage layout append-only.

### The reference as a high-water mark

The reference `(lastTotalAssets, lastDebt)` only **advances** when a positive basis actually crystallizes into minted fee shares (or on bootstrap, or when the vault empties). On a negative or zero basis the reference is **held**, so drawdowns and interest-driven debt growth (debt carry) stay inside the basis and the fee only crystallizes once the levered slice has genuinely out-earned its debt again; the reference behaves as a high-water mark.

Two companion mechanisms keep holding sound:

- **Held management fees.** Management fees keep accruing while the reference is held (they are time-based, so the accrual timestamp always advances). The charged amounts accumulate in `heldManagementFeeAssets` and are deducted from the next performance crystallization, then cleared when the reference finally advances or is reset. Across flows the accumulator is scaled with the position, with one exception: when rescuing out of a full bad-debt episode (previous collateral zero) the scaling is skipped, because the supply ratio is unmoored.
- **Rebasing across flows.** Deposits, withdrawals, and burns change the position without being performance. Each flow rebases the reference proportionally so the carried per-share basis is preserved: exiting shares take their slice of the carried drawdown with them, and entering shares do not inherit it. Rebalances are flows too (supply unchanged, basis preserved, nothing crystallizes). Since accrual runs before every flow, the carry is non-positive outside bad-debt windows.

**Bootstrap sentinel.** `lastDebt == 0` marks an uninitialized reference: the first accrual (after deployment, after upgrading from a release that predates the fee, or after the vault empties) skips the performance fee and seeds the reference from the current state. An all-bad-debt checkpoint also writes this sentinel, which is why recovery from that state skips one performance accrual (see [Known Issues](known-issues.md#position-manager)).

**Partial bad-debt windows.** While *some* module is in bad debt, the basis is not measurable: the excluded module's debt is missing from `currentDebt`, which deleverages the visible aggregate and can flip the basis positive in the middle of a drawdown. The reference is therefore frozen for the duration, and flows that happen inside such a window can over- or under-read the carried basis. The operational remedy when this matters is to set the performance rate to zero for the window and restore it afterwards.

**Reset.** `resetPerformanceReference()` is the owner's escape hatch for permanent drawdowns: it accrues first (so past gains crystallize before the move, and it can never mint on them twice), then re-anchors the reference at the current state, forgiving the carried basis and the held management-fee deduction. It should be called promptly after a deliberate write-off decision, since it forgives *all* carry accumulated up to that point.

## Transfer Guard

An optional [TransferGuard](transfer-guard.md) can be attached. When set, every share transfer is validated through it, deposits and withdrawals are blocked while the manager's token is paused, and rebalancing reverts with `Paused()`.
