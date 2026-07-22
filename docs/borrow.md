# Borrow

`MorphoBorrowPosition` wraps a single Morpho Blue market position for use under a [PositionManager](position-manager.md). Each position enforces its own LLTV, set at initialization, which must be greater than zero and at most the market's LLTV; the position reverts any borrow or collateral withdrawal that would leave it unhealthy at that custom threshold.

Positions are deployed as beacon proxies through `MorphoBorrowPositionFactory`:

```solidity
address bp = factory.createBorrowPosition(morpho, marketId, positionManager, 0.72e18);
```

The position manager owns the position and is the only caller of `supplyCollateral`, `withdrawCollateral`, `borrow`, and `repay`.

## Views

| Function | Returns |
|----------|---------|
| `totalBorrowed()` | current debt including accrued interest |
| `totalCollateral()` | collateral amount in the position |
| `totalCollateralQuoted()` | collateral valued in debt-asset terms through the market oracle |
| `isHealthy(lltv)` | whether debt stays within `lltv` of the quoted collateral |
| `maxBorrow(lltv)` | maximum borrowable at the given LLTV |
| `availableLiquidity()` | liquidity left in the Morpho market |
| `availableCollateral(lltv)` | collateral withdrawable while staying healthy |
| `collateralForBorrow(amount, ltv)` | extra collateral needed to borrow `amount` at `ltv` |
| `borrowForCollateral(amount, ltv)` | extra borrow capacity gained by supplying `amount` at `ltv` |

Health follows the Morpho convention: `collateral * oraclePrice / ORACLE_PRICE_SCALE * lltv >= totalBorrowed`.

## Pre-Liquidation

Instead of Morpho's native liquidation with its fixed incentive factor, the position exposes a **proportional pre-liquidation**: liquidators repay debt and seize collateral in the same proportion, so the bonus equals `1 - LTV` at liquidation time. The further underwater the position, the smaller the bonus; there is no cap on seized collateral.

For example, at 80% LTV with $100 collateral and $80 debt, repaying half the debt ($40) seizes half the collateral ($50), a 20% premium.

```solidity
function preLiquidate(
    address borrower,      // the MorphoBorrowPosition address
    uint256 seizedAssets,  // collateral to seize (0 to derive from repaidShares)
    uint256 repaidShares,  // debt shares to repay (0 to derive from seizedAssets)
    bytes calldata data    // callback data (empty for none)
) external returns (uint256 seizedAssets, uint256 repaidAssets);
```

Exactly one of `seizedAssets` and `repaidShares` must be non-zero; otherwise the call reverts with `InconsistentInput`. If `data` is non-empty, `onPreLiquidate(repaidAssets, data)` is invoked on the caller after the collateral transfer and before the debt is pulled.

Above the market LLTV the amounts are adjusted so a liquidation always leaves Morpho's own health check satisfied: in seized-assets mode the repaid debt is raised above the proportional amount, in repaid-shares mode the seized collateral is reduced. This caps the liquidator bonus below the pure `1 - LTV` line once the position crosses the market LLTV, which can make partial pre-liquidations unprofitable before full ones (see [Known Issues](known-issues.md#borrow--liquidations)).

`preLiquidate` deliberately takes no reentrancy guard: Morpho settles the seized collateral before the liquidator callback runs, and every state-changing entry point reachable during the callback is role-gated. The corollary is an invariant the deployment must maintain: a liquidator must never hold minter or facilitator roles on the composed contracts without adding a guard.

## Liquidation Offers

`BorrowOffersRegistry` and `LibBorrowOffers` add an offer-based band on top of the proportional mechanism: standing on-chain offers that authorize liquidation at declared prices *before* the position reaches the pre-liquidation threshold, giving the protocol an orderly deleveraging path ahead of forced liquidation.

- **Registry.** One `BorrowOffersRegistry` per deployment holds the offer configuration and roles for every position; positions reference it as an immutable, so every beacon upgrade must pass the same registry address or offer authority silently moves.
- **Offers.** An offer is proposed on-chain with a share-denominated debt amount and a price, and becomes consumable only after a timelock fixed at proposal time (a later timelock change can never retroactively shorten the veto window). The registry enforces a minimum timelock floor, so no offer is ever consumable in the block that proposed it. Live offers sit in a fixed slab (at most 32, bounded by a bitmap) whose walk gas is bounded.
- **Consumption.** During `preLiquidate`, offers are walked in effective-price order. Every fill is re-checked at consumption time against two binding invariants: the fill must be profitable above the configured bonus floor, and it must *strictly lower* the position's LTV (de-risking). Rounding is conservative to the protocol throughout (the liquidator repays up, receives down); when a position-shares clamp binds, seized collateral is rescaled down to the offer's fixed ratio so the liquidator never gets a better price than the proposer authorized.
- **Configuration.** The offer timelock can be changed, but the change itself is delayed by the current effective timelock (re-based on every call, so reductions cannot be accelerated). The bonus floor is capped: because the de-risking check bounds any fill's bonus at `(1 - LTV) / LTV`, a floor near the cap makes the band unusable at high LTV until lowered (the setter is instant).
