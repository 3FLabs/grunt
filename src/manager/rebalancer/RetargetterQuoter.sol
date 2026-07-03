// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterQuoter} from "../../interfaces/manager/rebalancer/IRetargetterQuoter.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title RetargetterQuoter
/// @author 3F Protocol
/// @notice Stateless pure math for sizing retargetting operations and pricing their repayment.
/// @dev Deployed once per chain and shared by every Retargetter instance through the factory.
///      See {IRetargetterQuoter} for units and parameter semantics; the derivations behind each
///      function follow.
///
///      Model: a retargetting operation moves a leveraged position toward its target
///      loan-to-value ratio using a bridge loan that spans the collateral's asynchronous
///      settlement window. Throughout, write
///
///        K = collateral value quoted in debt-asset units (collateralQuoted)
///        D = debt in debt-asset units
///        t = target loan-to-value ratio (targetLtv, WAD-scaled)
///        x = the bridge-loan principal being sized
///
///      and, over a settlement window of `duration` seconds, the three dimensionless accruals
///      (each a WAD-per-year rate scaled as `rate * duration / 365 days`, see `_scaledRate`):
///
///        Yr = scaled requestYieldRate, the bridge yield owed on the principal
///        Rb = scaled borrowRate, the venue interest drifting the existing debt
///        Yc = scaled collateralYieldRate, the yield growing the existing collateral value
///
///      Sizing assumes the collateral price holds over the window (settlement price ratio
///      rho = 1). Realized drift is absorbed at settlement by the remediation step (LTV-down)
///      or leaves a bounded deviation from target that a later operation corrects (LTV-up).
///
///      LTV-up sizing (`ltvUpPrincipal`), for under-leveraged positions (D / K < t): borrow x,
///      subscribe it into new collateral, and at settlement borrow the bridge repayment
///      `x * (1 + Yr)` as new position debt to close the loan. At settlement the existing
///      collateral has grown to `K * (1 + Yc)`, the subscription settles at value x (it
///      materializes at settlement, so it accrues no window yield), and the existing debt has
///      drifted to `D * (1 + Rb)`. Requiring the settled position to sit at target,
///
///        D * (1 + Rb) + x * (1 + Yr) = t * (K * (1 + Yc) + x)
///
///      and solving for x yields the implemented formula
///
///        x = (t * K * (1 + Yc) - D * (1 + Rb)) / (1 - t + Yr)
///
///      LTV-down sizing (`ltvDownPrincipal`), for over-leveraged positions (D / K > t): borrow
///      x, repay x of position debt, withdraw collateral of quoted value w and redeem it, and
///      at settlement repay the bridge `x * (1 + Yr)` from the redemption proceeds. The freed
///      collateral accrues its own yield over the window, so covering the repayment exactly
///      requires `w * (1 + Yc) = x * (1 + Yr)`, which is the collateralToFreeQuoted output:
///
///        w = x * (1 + Yr) / (1 + Yc)
///
///      At settlement the remaining collateral is worth `(K - w) * (1 + Yc)`, which expands to
///      `K * (1 + Yc) - x * (1 + Yr)`, and the remaining debt has drifted to
///      `(D - x) * (1 + Rb)`. Requiring the settled position to sit at target,
///
///        (D - x) * (1 + Rb) = t * (K * (1 + Yc) - x * (1 + Yr))
///
///      and solving for x yields the implemented formula
///
///        x = (D * (1 + Rb) - t * K * (1 + Yc)) / (1 + Rb - t * (1 + Yr))
///
///      Settlement drift (`remediationDelta`): the LTV-down repayment `x * (1 + Yr)` is fixed
///      when the operation is sized, while the redemption settles at the realized price. With
///      rho the settlement price ratio, the proceeds are `x * (1 + Yr) * rho`, leaving the cash
///      mismatch
///
///        delta = x * (1 + Yr) * (rho - 1)
///
///      A surplus (rho > 1) folds into the position as a debt repayment; a shortfall (rho < 1)
///      is topped up with an owner-authorized borrow. Either way the position absorbs the drift.
///
///      Repayment pricing (`paidDuration`, `repaymentOwed`): a bridge loan tokenizes its
///      obligation as a principal supply P (ptSupply) plus an approved absolute yield supply Y
///      (ytSupply) accruing linearly over a horizon H. Elapsed time is first quantized to whole
///      ticks with a grace threshold,
///
///        paidTicks = max(1, floor((elapsed + tickDuration - tickThreshold) / tickDuration))
///        paidDuration = paidTicks * tickDuration
///
///      so one full tick is owed from the first second and the count promotes to k + 1 ticks
///      exactly at `elapsed = k * tickDuration + tickThreshold`. The owed amount then prices
///      the yield pro rata over the horizon, capped so a late repayment never draws more than
///      the approved yield:
///
///        owed = P + ceil(Y * min(paidDuration, H) / H) <= P + Y
///
///      Rounding: principals round down, while everything the protocol must pay or set aside
///      rounds up (the owed yield, the collateral to free, the shortfall side of the mismatch),
///      so lenders are never underpaid and remediations never undershoot.
contract RetargetterQuoter is IRetargetterQuoter {
  using FixedPointMathLib for uint256;

  /// @dev WAD precision (1e18 = 100%).
  uint256 internal constant WAD = 1e18;

  /// @dev Rate annualization basis for the WAD-per-year rate inputs.
  uint256 internal constant RATE_YEAR = 365 days;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       PRINCIPAL SIZING                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterQuoter
  function ltvUpPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal) {
    uint256 grownTarget = _grownTarget(collateralQuoted, targetLtv, collateralYieldRate, duration);
    uint256 driftedDebt = _driftedDebt(debt, borrowRate, duration);
    if (grownTarget <= driftedDebt) return 0;
    // Denominator 1 - targetLtv + Yr; zero only at targetLtv == WAD with a zero yield estimate
    uint256 denominator = WAD - targetLtv + _scaledRate(requestYieldRate, duration);
    if (denominator == 0) revert LibRetargetterErrors.InvalidParameters();
    principal = (grownTarget - driftedDebt).fullMulDiv(WAD, denominator);
  }

  /// @inheritdoc IRetargetterQuoter
  function ltvDownPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) external pure returns (uint256 principal, uint256 collateralToFreeQuoted) {
    uint256 driftedDebt = _driftedDebt(debt, borrowRate, duration);
    uint256 grownTarget = _grownTarget(collateralQuoted, targetLtv, collateralYieldRate, duration);
    if (driftedDebt <= grownTarget) return (0, 0);
    principal =
      (driftedDebt - grownTarget).fullMulDiv(WAD, _downDenominator(targetLtv, requestYieldRate, borrowRate, duration));
    // The freed collateral must redeem into the bridge repayment principal * (1 + Yr);
    // its own yield over settlement discounts the amount to withdraw. Rounds up so the
    // redemption proceeds always cover the repayment.
    collateralToFreeQuoted = principal.fullMulDivUp(
      WAD + _scaledRate(requestYieldRate, duration), WAD + _scaledRate(collateralYieldRate, duration)
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REPAYMENT PRICING                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterQuoter
  function paidDuration(uint256 elapsed, uint256 tickDuration, uint256 tickThreshold)
    public
    pure
    returns (uint256 duration)
  {
    if (tickDuration == 0 || tickThreshold >= tickDuration) revert LibRetargetterErrors.InvalidParameters();
    uint256 paidTicks = (elapsed + tickDuration - tickThreshold) / tickDuration;
    if (paidTicks == 0) paidTicks = 1;
    duration = paidTicks * tickDuration;
  }

  /// @inheritdoc IRetargetterQuoter
  function repaymentOwed(
    uint256 ptSupply,
    uint256 ytSupply,
    uint256 elapsed,
    uint256 tickDuration,
    uint256 tickThreshold,
    uint256 horizon
  ) external pure returns (uint256 owedAmount) {
    if (horizon == 0) revert LibRetargetterErrors.InvalidParameters();
    uint256 duration = paidDuration(elapsed, tickDuration, tickThreshold);
    if (duration > horizon) duration = horizon;
    owedAmount = ptSupply + ytSupply.fullMulDivUp(duration, horizon);
  }

  /// @inheritdoc IRetargetterQuoter
  function remediationDelta(uint256 principal, uint256 requestYieldRate, uint256 duration, uint256 priceDriftWad)
    external
    pure
    returns (int256 delta)
  {
    // The fixed bridge repayment the redemption proceeds are measured against
    uint256 repayment = principal.fullMulDiv(WAD + _scaledRate(requestYieldRate, duration), WAD);
    uint256 magnitude;
    if (priceDriftWad >= WAD) {
      // Surplus: proceeds exceed the repayment; rounds down so the fold never overshoots
      magnitude = repayment.fullMulDiv(priceDriftWad - WAD, WAD);
      if (magnitude > uint256(type(int256).max)) revert LibRetargetterErrors.InvalidParameters();
      // Safe: bounded by the check above
      // forge-lint: disable-next-line(unsafe-typecast)
      delta = int256(magnitude);
    } else {
      // Shortfall: rounds up so a remediation sized from this value always covers the gap
      magnitude = repayment.fullMulDivUp(WAD - priceDriftWad, WAD);
      if (magnitude > uint256(type(int256).max)) revert LibRetargetterErrors.InvalidParameters();
      // Safe: bounded by the check above
      // forge-lint: disable-next-line(unsafe-typecast)
      delta = -int256(magnitude);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Scales a WAD-per-year rate to the given duration: `rate * duration / 365 days`.
  function _scaledRate(uint256 rate, uint256 duration) internal pure returns (uint256) {
    return rate.fullMulDiv(duration, RATE_YEAR);
  }

  /// @dev Target collateral value grown by the collateral yield over settlement:
  ///      `targetLtv * K * (1 + Yc)`.
  function _grownTarget(uint256 collateralQuoted, uint256 targetLtv, uint256 collateralYieldRate, uint256 duration)
    internal
    pure
    returns (uint256)
  {
    return collateralQuoted.fullMulDiv(targetLtv, WAD).fullMulDiv(WAD + _scaledRate(collateralYieldRate, duration), WAD);
  }

  /// @dev Existing debt drifted by the borrow rate over settlement: `D * (1 + Rb)`.
  function _driftedDebt(uint256 debt, uint256 borrowRate, uint256 duration) internal pure returns (uint256) {
    return debt.fullMulDiv(WAD + _scaledRate(borrowRate, duration), WAD);
  }

  /// @dev LTV-down denominator `1 + Rb - targetLtv * (1 + Yr)`. The drifted unit term
  ///      dominates the target-scaled request yield for all economically reasonable rates;
  ///      reverts otherwise.
  function _downDenominator(uint256 targetLtv, uint256 requestYieldRate, uint256 borrowRate, uint256 duration)
    internal
    pure
    returns (uint256)
  {
    uint256 driftedUnit = WAD + _scaledRate(borrowRate, duration);
    uint256 scaledTarget = targetLtv.fullMulDiv(WAD + _scaledRate(requestYieldRate, duration), WAD);
    if (driftedUnit <= scaledTarget) revert LibRetargetterErrors.InvalidParameters();
    return driftedUnit - scaledTarget;
  }
}
