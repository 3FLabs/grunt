# Retargetter

The retargetter moves a [PositionManager](position-manager.md)'s leveraged position toward its target loan-to-value ratio when the collateral settles asynchronously: adding leverage means subscribing new collateral through a [fund](funds.md) order, removing it means redeeming collateral, and both take a settlement window to complete. A bridge loan (a [Request](request.md), or a Morpho Blue flash loan for atomic legs) spans that window, and the `RetargetterQuoter` sizes it so the position lands exactly on target at settlement.

`Retargetter` orchestrates the operation; `RetargetterQuoter` is the stateless math, deployed once per chain and shared by every Retargetter instance through the factory. Each Retargetter instance handles one operation at a time for one PositionManager/fund pair; running several concurrent retargettings means deploying several instances (creation through the factory is permissionless, and an instance is inert until roles are granted on the composed contracts).

## Operation Lifecycle

An asynchronous operation (`startRetargetting`) deploys a fresh Request as the bridge loan and then walks through the settlement window:

1. **Funding.** Bridge lenders enter through the request's signed offers (`consume`) or `authorizeMinting`, both gated by the operation's terms: a flat yield-rate cap on each offer (repayment is duration-prorated separately, so the gate does not need to be) and a cumulative principal cap. The loan clock starts at the first commitment. The Request is deployed with the maximum 90-day repayment deadline (treated as effectively infinite; see [Known Issues](known-issues.md#retargetter)) and a zero mint-to-repaid delay.
2. **Consumption window.** Entry closes at the first repayment tick threshold or the first principal pull, whichever comes first, and this binds everyone including the owner: repayment prices every yield token from the loan origin, so capital entering late would be overpaid and would dilute recovery on a default.
3. **Deployment.** The retargetter runs fund orders (subscription or redemption legs) and PositionManager rebalance legs against the operation's fund. Rebalance legs accept a full-balance sentinel resolved from one pre-call snapshot: on input legs it means "use the entire held balance", REPAY amounts are capped at the live module debt (venues reject over-repayment), and sentinels do not compose across legs.
4. **Repayment and settlement.** `repay()` transfers only the shortfall between the owed amount and the request's balance, so position funds can never overpay yield holders, and the open upper bound means donations to the request cannot block repayment. `resolve()` then settles the operation behind three gates: the request is repaid, no fund order is pending, and any residual balance is within the configured tolerance (strictly below `2^exponent`, zero meaning exact).

The synchronous variant (`startSyncRetargetting`) wraps the same rebalancing in a Morpho Blue flash loan and settles atomically within one transaction; the operation storage itself serves as the reentry lock.

## Model and Notation

## Model and Notation

Write, for one retargetting operation:

- `K`: collateral value quoted in debt-asset units (`collateralQuoted`)
- `D`: debt in debt-asset units
- `t`: target loan-to-value ratio (`targetLtv`, WAD-scaled)
- `x`: the bridge-loan principal being sized

Over a settlement window of `duration` seconds, three dimensionless accruals apply. Each is a WAD-per-year rate scaled as `rate * duration / 365 days`:

- `Yr`: scaled `requestYieldRate`, the bridge yield owed on the principal
- `Rb`: scaled `borrowRate`, the venue interest drifting the existing debt
- `Yc`: scaled `collateralYieldRate`, the yield growing the existing collateral value

Sizing assumes the collateral price holds over the window (settlement price ratio `rho = 1`). Realized drift is absorbed at settlement by the remediation step (LTV-down) or leaves a bounded deviation from target that a later operation corrects (LTV-up).

`retargetPrincipal` dispatches on the current ratio `D / K`: under-leveraged positions route to the LTV-up formula over the subscription window, over-leveraged ones to the LTV-down formula over the redemption window, and a position exactly at target needs no principal.

## LTV-Up Sizing

For an under-leveraged position (`D / K < t`): borrow `x`, subscribe it into new collateral, and at settlement borrow the bridge repayment `x * (1 + Yr)` as new position debt to close the loan.

At settlement the existing collateral has grown to `K * (1 + Yc)`, the subscription settles at value `x` (it materializes at settlement, so it accrues no window yield), and the existing debt has drifted to `D * (1 + Rb)`. Requiring the settled position to sit at target:

```
D * (1 + Rb) + x * (1 + Yr) = t * (K * (1 + Yc) + x)
```

Solving for `x` gives the formula `ltvUpPrincipal` implements:

```
x = (t * K * (1 + Yc) - D * (1 + Rb)) / (1 - t + Yr)
```

The denominator is zero only at `targetLtv == WAD` with a zero yield estimate, which the quoter rejects.

## LTV-Down Sizing

For an over-leveraged position (`D / K > t`): borrow `x`, repay `x` of position debt, withdraw collateral of quoted value `w` and redeem it, and at settlement repay the bridge `x * (1 + Yr)` from the redemption proceeds.

The freed collateral accrues its own yield over the window, so covering the repayment exactly requires `w * (1 + Yc) = x * (1 + Yr)`. This is the `collateralToFreeQuoted` output:

```
w = x * (1 + Yr) / (1 + Yc)
```

At settlement the remaining collateral is worth `(K - w) * (1 + Yc) = K * (1 + Yc) - x * (1 + Yr)` and the remaining debt has drifted to `(D - x) * (1 + Rb)`. Requiring the settled position to sit at target:

```
(D - x) * (1 + Rb) = t * (K * (1 + Yc) - x * (1 + Yr))
```

Solving for `x` gives the formula `ltvDownPrincipal` implements:

```
x = (D * (1 + Rb) - t * K * (1 + Yc)) / (1 + Rb - t * (1 + Yr))
```

In the denominator, the drifted unit term `1 + Rb` dominates the target-scaled request yield `t * (1 + Yr)` for all economically reasonable rates; the quoter reverts otherwise.

## Settlement Drift and Remediation

The LTV-down repayment `x * (1 + Yr)` is fixed when the operation is sized, while the redemption settles at the realized price. With `rho` the settlement price ratio, the proceeds are `x * (1 + Yr) * rho`, leaving the cash mismatch `remediationDelta` computes:

```
delta = x * (1 + Yr) * (rho - 1)
```

A surplus (`rho > 1`) folds into the position as a debt repayment; a shortfall (`rho < 1`) is topped up with an owner-authorized borrow. Either way the position absorbs the drift.

## Repayment Pricing

A bridge loan tokenizes its obligation as a principal supply `P` (`ptSupply`) plus an approved absolute yield supply `Y` (`ytSupply`) accruing linearly over a horizon `H`. Elapsed time is first quantized to whole ticks with a grace threshold (`paidDuration`):

```
paidTicks    = max(1, floor((elapsed + tickDuration - tickThreshold) / tickDuration))
paidDuration = paidTicks * tickDuration
```

so one full tick is owed from the first second, and the count promotes to `k + 1` ticks exactly at `elapsed = k * tickDuration + tickThreshold`. The owed amount (`repaymentOwed`) then prices the yield pro rata over the horizon, capped so a late repayment never draws more than the approved yield:

```
owed = P + ceil(Y * min(paidDuration, H) / H) <= P + Y
```

## Rounding

Principals round down, while everything the protocol must pay or set aside rounds up: the owed yield, the collateral to free, and the shortfall side of the settlement mismatch. Lenders are never underpaid and remediations never undershoot.

## MorphoRebalancer

A standalone rebalancer for atomic (non-bridge) rebalancing: it takes a Morpho flash loan, calls `rebalance` on the PositionManager inside the callback, and repays the loan in the same transaction. It needs the rebalancer role on the manager.
