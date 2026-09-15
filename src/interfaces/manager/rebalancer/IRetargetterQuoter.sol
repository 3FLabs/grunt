// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRetargetterQuoter
/// @author 3F Protocol
/// @notice Stateless pure math for sizing retargetting operations and pricing their repayment.
/// @dev Behavioral contract only: the formulas and their step-by-step derivations live in the
///      RetargetterQuoter contract header.
///
///      Units and conventions:
///      - `collateralQuoted` and `debt` are in debt-asset units (PositionManager
///        `collateralAmountQuoted()` / `debtAmount()`)
///      - `targetLtv` is WAD-scaled; yearly rates are WAD-scaled per 365 days
///      - durations are in seconds; rate-times-duration products are `rate * duration / 365 days`
///      - principals round down, owed yield rounds up (lenders are never underpaid by a wei)
interface IRetargetterQuoter {
  /// @notice Computes the retargetting principal for a position, direction auto-detected.
  /// @dev Routes on the current ratio `debt / collateralQuoted`: below target dispatches to
  ///      `ltvUpPrincipal` with the subscription duration, above target to `ltvDownPrincipal`
  ///      with the redemption duration, and exactly at target returns zero. Reverts on zero
  ///      collateral.
  /// @param collateralQuoted The aggregate collateral value in debt-asset units
  /// @param debt The aggregate debt in debt-asset units
  /// @param targetLtv The target loan-to-value ratio (WAD)
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param borrowRate The venue borrow rate on existing debt (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate (WAD per 365 days)
  /// @param subscriptionDuration The expected subscription settlement duration in seconds
  /// @param redemptionDuration The expected redemption settlement duration in seconds
  /// @return principal The bridge-loan principal in debt-asset units (rounded down)
  function retargetPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 subscriptionDuration,
    uint256 redemptionDuration
  ) external pure returns (uint256 principal);

  /// @notice Computes the borrow principal that brings an under-leveraged position to target.
  /// @dev Sized so the position sits exactly at target once the subscription settles and the
  ///      bridge repayment is drawn as new debt, accounting for debt drift, collateral yield
  ///      and bridge yield over the window. Returns 0 when the position is at or above target
  ///      once those accruals are applied. Reverts with `InvalidParameters` only at a full
  ///      target LTV combined with a zero bridge yield estimate.
  /// @param collateralQuoted The aggregate collateral value in debt-asset units
  /// @param debt The aggregate debt in debt-asset units
  /// @param targetLtv The target loan-to-value ratio (WAD)
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param borrowRate The venue borrow rate on existing debt (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate (WAD per 365 days)
  /// @param duration The expected subscription settlement duration in seconds
  /// @return principal The bridge-loan principal in debt-asset units (rounded down)
  function ltvUpPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal);

  /// @notice Computes the borrow principal that brings an over-leveraged position to target.
  /// @dev Sized so the position sits exactly at target once the bridge principal has repaid
  ///      debt and the freed collateral's redemption has covered the bridge repayment,
  ///      accounting for debt drift, collateral yield and bridge yield over the window.
  ///      Returns (0, 0) when the position is at or below target once those accruals are
  ///      applied. Reverts with `InvalidParameters` on economically unreasonable rate inputs
  ///      (a non-positive sizing denominator).
  /// @param collateralQuoted The aggregate collateral value in debt-asset units
  /// @param debt The aggregate debt in debt-asset units
  /// @param targetLtv The target loan-to-value ratio (WAD)
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param borrowRate The venue borrow rate on existing debt (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate (WAD per 365 days)
  /// @param duration The expected redemption settlement duration in seconds
  /// @return principal The bridge-loan principal in debt-asset units (rounded down)
  /// @return collateralToFreeQuoted The collateral value to withdraw and redeem so proceeds
  ///         cover the bridge repayment (rounded up)
  function ltvDownPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal, uint256 collateralToFreeQuoted);

  /// @notice Computes the one-trip repayment bound of an LTV-up operation.
  /// @dev The largest principal whose worst permitted repayment (the principal plus the full
  ///      flat yield cap) can still be borrowed at target once the subscription has landed as
  ///      collateral: `P * (1 + yieldCap) <= targetLtv * (K * (1 + Yc) + P) - D * (1 + Rb)`.
  ///      Same accrual terms as `ltvUpPrincipal`, with the bridge yield estimate replaced
  ///      by the flat cap because repayment prices actual YT supply, not the estimate.
  ///      The bound is exact in integers: the collateral growth floors before the target
  ///      applies (matching the settlement LTV check's own arithmetic) and the drifted debt
  ///      rounds up, so the worst repayment of a bound-sized principal is always borrowable
  ///      at target in one settlement trip.
  ///      Returns 0 when the position is at or above target once the accruals are applied.
  ///      Reverts with `InvalidParameters` only at a full target LTV combined with a zero
  ///      yield cap.
  /// @param collateralQuoted The aggregate collateral value in debt-asset units
  /// @param debt The aggregate debt in debt-asset units
  /// @param targetLtv The target loan-to-value ratio (WAD)
  /// @param maxYieldBps The flat yield cap bounding the operation's YT supply (basis points)
  /// @param borrowRate The venue borrow rate on existing debt (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate (WAD per 365 days)
  /// @param duration The expected subscription settlement duration in seconds
  /// @return principal The one-trip repayment bound in debt-asset units (rounded down)
  function ltvUpOneTripPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 maxYieldBps,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal);

  /// @notice Quantizes an elapsed loan duration to whole repayment ticks.
  /// @dev From the first second the borrower owes one full tick; the count promotes to the
  ///      next tick each time the elapsed duration passes a whole number of ticks plus the
  ///      grace threshold.
  /// @param elapsed The seconds elapsed since the loan clock origin
  /// @param tickDuration The repayment granularity in seconds (must be nonzero)
  /// @param tickThreshold The grace before promoting to the next tick (must be < tickDuration)
  /// @return duration The paid duration in seconds (a whole number of ticks, at least one)
  function paidDuration(uint256 elapsed, uint256 tickDuration, uint256 tickThreshold)
    external
    pure
    returns (uint256 duration);

  /// @notice Computes the trustless repayment owed on an outstanding bridge loan.
  /// @dev Prices the approved yield pro rata over the horizon on top of the outstanding
  ///      principal, with the paid duration capped at the horizon so `ptSupply + ytSupply` is
  ///      the absolute maximum: a delayed repayment can never draw more than the approved
  ///      yield. The yield term rounds up so lenders are never underpaid by a wei.
  /// @param ptSupply The outstanding principal token supply (consumed principal)
  /// @param ytSupply The outstanding yield token supply (approved absolute yield)
  /// @param elapsed The seconds elapsed since the loan clock origin
  /// @param tickDuration The repayment granularity in seconds (must be nonzero)
  /// @param tickThreshold The grace before promoting to the next tick (must be < tickDuration)
  /// @param horizon The annualization basis for the yield in seconds (must be nonzero)
  /// @return owedAmount The total repayment owed in asset units
  function repaymentOwed(
    uint256 ptSupply,
    uint256 ytSupply,
    uint256 elapsed,
    uint256 tickDuration,
    uint256 tickThreshold,
    uint256 horizon
  ) external pure returns (uint256 owedAmount);

  /// @notice Computes the settlement-time cash mismatch of an LTV-down operation under price drift.
  /// @dev The bridge repayment is fixed when the operation is sized while the redemption
  ///      settles at the realized price; the delta is that cash mismatch. The freed collateral
  ///      was sized net of its own expected yield, so the drift is measured against the
  ///      expected growth `1 + Yc` rather than unity: a price that moves exactly as forecast
  ///      yields a zero delta. Positive means surplus (fold into position debt), negative
  ///      means shortfall (owner-only borrow top-up). Shortfalls round up so a remediation
  ///      sized from this value always covers the gap.
  /// @param principal The bridge-loan principal in debt-asset units
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate used when sizing (WAD per 365 days)
  /// @param duration The realized settlement duration in seconds
  /// @param priceDriftWad The settlement price ratio `rho = p1 / p0` (WAD)
  /// @return delta The signed cash mismatch in debt-asset units
  function remediationDelta(
    uint256 principal,
    uint256 requestYieldRate,
    uint256 collateralYieldRate,
    uint256 duration,
    uint256 priceDriftWad
  ) external pure returns (int256 delta);
}
