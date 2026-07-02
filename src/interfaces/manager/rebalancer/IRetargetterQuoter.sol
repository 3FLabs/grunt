// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRetargetterQuoter
/// @author 3F Protocol
/// @notice Stateless pure math for sizing retargetting operations and pricing their repayment.
/// @dev Single on-chain home of the LTV rebalancing formulas from "Netting Mathematics for
///      Intent Resolution on Asynchronous-Settlement Leveraged Assets" (May 2026), Section 5.
///
///      Units and conventions:
///      - `collateralQuoted` and `debt` are in debt-asset units (PositionManager
///        `collateralAmountQuoted()` / `debtAmount()`)
///      - `targetLtv` is WAD-scaled; yearly rates are WAD-scaled per 365 days
///      - durations are in seconds; rate-times-duration products are `rate * duration / 365 days`
///      - principals round down, owed yield rounds up (lenders are never underpaid by a wei)
interface IRetargetterQuoter {
  /// @notice Computes the borrow principal that brings an under-leveraged position to target.
  /// @dev [PDF eq 36 extended with collateral yield]
  ///      `x = (targetLtv * K * (1 + Yc) - D * (1 + Rb)) / (1 - targetLtv + Yr)` where
  ///      `Yr = requestYieldRate * duration / 365 days` (the bridge yield over settlement),
  ///      `Rb = borrowRate * duration / 365 days` (existing debt drift), and
  ///      `Yc = collateralYieldRate * duration / 365 days` (collateral appreciation).
  ///      Returns 0 when the numerator is not positive (position at or above target).
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
  /// @dev [PDF eq 38 extended with collateral yield]
  ///      `x = (D * (1 + Rb) - targetLtv * K * (1 + Yc)) / (1 + Rb - targetLtv * (1 + Yr))`.
  ///      Returns (0, 0) when the numerator is not positive (position at or below target).
  ///      Reverts with `InvalidParameters` on a non-positive denominator (economically
  ///      unreasonable rate inputs).
  /// @param collateralQuoted The aggregate collateral value in debt-asset units
  /// @param debt The aggregate debt in debt-asset units
  /// @param targetLtv The target loan-to-value ratio (WAD)
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param borrowRate The venue borrow rate on existing debt (WAD per 365 days)
  /// @param collateralYieldRate The collateral yield rate (WAD per 365 days)
  /// @param duration The expected redemption settlement duration in seconds
  /// @return principal The bridge-loan principal in debt-asset units (rounded down)
  /// @return collateralToFreeQuoted The collateral value to withdraw and redeem so proceeds
  ///         cover the bridge repayment, `x * (1 + Yr) / (1 + Yc)` (rounded up)
  function ltvDownPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal, uint256 collateralToFreeQuoted);

  /// @notice Quantizes an elapsed loan duration to whole repayment ticks.
  /// @dev `paidTicks = max(1, floor((elapsed + tickDuration - tickThreshold) / tickDuration))`,
  ///      `paidDuration = paidTicks * tickDuration`. From the first second the borrower owes one
  ///      full tick; the duration promotes to `k + 1` ticks exactly at
  ///      `elapsed = k * tickDuration + tickThreshold`.
  /// @param elapsed The seconds elapsed since the loan clock origin
  /// @param tickDuration The repayment granularity in seconds (must be nonzero)
  /// @param tickThreshold The grace before promoting to the next tick (must be < tickDuration)
  /// @return duration The paid duration in seconds (a whole number of ticks, at least one)
  function paidDuration(uint256 elapsed, uint256 tickDuration, uint256 tickThreshold)
    external
    pure
    returns (uint256 duration);

  /// @notice Computes the trustless repayment owed on an outstanding bridge loan.
  /// @dev `owed = ptSupply + ceil(ytSupply * min(paidDuration(elapsed), horizon) / horizon)`.
  ///      The `min` cap makes `ptSupply + ytSupply` the absolute maximum: a delayed repayment can
  ///      never draw more than the approved yield. The yield term rounds up so lenders are never
  ///      underpaid by a wei.
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
  /// @dev [PDF eq 39] `delta = principal * (1 + Yr) * (rho - 1)` where `rho` is the price ratio
  ///      over the settlement window. Positive means surplus (fold into position debt), negative
  ///      means shortfall (owner-only borrow top-up). Shortfalls round up so a remediation sized
  ///      from this value always covers the gap.
  /// @param principal The bridge-loan principal in debt-asset units
  /// @param requestYieldRate The bridge-loan yield rate (WAD per 365 days)
  /// @param duration The realized settlement duration in seconds
  /// @param priceDriftWad The settlement price ratio `rho = p1 / p0` (WAD)
  /// @return delta The signed cash mismatch in debt-asset units
  function remediationDelta(uint256 principal, uint256 requestYieldRate, uint256 duration, uint256 priceDriftWad)
    external
    pure
    returns (int256 delta);
}
