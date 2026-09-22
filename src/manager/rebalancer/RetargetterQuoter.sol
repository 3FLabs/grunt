// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterQuoter} from "../../interfaces/manager/rebalancer/IRetargetterQuoter.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {BPS} from "../../libs/Constants.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title RetargetterQuoter
/// @author 3F Protocol
/// @notice Stateless pure math for sizing retargetting operations and pricing their repayment.
/// @dev Deployed once per chain and shared by every Retargetter instance through the factory.
///      See {IRetargetterQuoter} for units and parameter semantics.
///
///      A retarget uses the current quoted collateral value K, current debt D, target LTV t,
///      and bridge principal x. Over the settlement window, Yr is the prorated Request yield
///      and Rb is the prorated borrow rate. Collateral-price growth is not forecast; realized
///      price movement is handled at settlement.
///
///      LTV-up:
///
///        D * (1 + Rb) + x * (1 + Yr) = t * (K + x)
///        x = (t * K - D * (1 + Rb)) / (1 - t + Yr)
///
///      LTV-down:
///
///        (D - x) * (1 + Rb) = t * (K - x * (1 + Yr))
///        x = (D * (1 + Rb) - t * K) / (1 + Rb - t * (1 + Yr))
///
///      The LTV-down collateral quote is `x * (1 + Yr)`. If its settlement price ratio is
///      rho, the remediation is `x * (1 + Yr) * (rho - 1)`: surplus is folded into debt and
///      shortfall is topped up with an owner-authorized borrow.
///
///      Principals round down. Repayment, collateral released and remediation shortfalls
///      round up so lenders are never underpaid and settlement never undershoots.
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
  function retargetPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256,
    uint256 subscriptionDuration,
    uint256 redemptionDuration
  ) external pure returns (uint256 principal) {
    uint256 current = debt.divWad(collateralQuoted);
    if (current < targetLtv) {
      principal =
        ltvUpPrincipal(collateralQuoted, debt, targetLtv, requestYieldRate, borrowRate, 0, subscriptionDuration);
    } else if (current > targetLtv) {
      (principal,) =
        ltvDownPrincipal(collateralQuoted, debt, targetLtv, requestYieldRate, borrowRate, 0, redemptionDuration);
    }
  }

  /// @inheritdoc IRetargetterQuoter
  function ltvUpPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256,
    uint256 duration
  ) public pure returns (uint256 principal) {
    uint256 targetValue = collateralQuoted.fullMulDiv(targetLtv, WAD);
    uint256 driftedDebt = _driftedDebt(debt, borrowRate, duration);
    if (targetValue <= driftedDebt) return 0;
    // Denominator 1 - targetLtv + Yr; zero only at targetLtv == WAD with a zero yield estimate
    uint256 denominator = WAD - targetLtv + _scaledRate(requestYieldRate, duration);
    if (denominator == 0) revert LibRetargetterErrors.InvalidParameters();
    principal = (targetValue - driftedDebt).fullMulDiv(WAD, denominator);
  }

  /// @inheritdoc IRetargetterQuoter
  function ltvUpOneTripPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 maxYieldBps,
    uint256 borrowRate,
    uint256,
    uint256 duration
  ) public pure returns (uint256 principal) {
    uint256 targetValue = collateralQuoted.fullMulDiv(targetLtv, WAD);
    // The settled venue debt is a liability the borrow capacity must cover before the
    // repayment, so the bound rounds it up where the sizing estimates round down
    uint256 driftedDebt = debt.fullMulDivUp(WAD + _scaledRate(borrowRate, duration), WAD);
    if (targetValue <= driftedDebt) return 0;
    // Denominator 1 + y - targetLtv; zero only at targetLtv == WAD with a zero yield cap
    uint256 denominator = WAD + maxYieldBps * WAD / BPS - targetLtv;
    if (denominator == 0) revert LibRetargetterErrors.InvalidParameters();
    principal = (targetValue - driftedDebt).fullMulDiv(WAD, denominator);
  }

  /// @inheritdoc IRetargetterQuoter
  function ltvDownPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256,
    uint256 duration
  ) public pure returns (uint256 principal, uint256 collateralToFreeQuoted) {
    uint256 driftedDebt = _driftedDebt(debt, borrowRate, duration);
    uint256 targetValue = collateralQuoted.fullMulDiv(targetLtv, WAD);
    if (driftedDebt <= targetValue) return (0, 0);
    principal =
      (driftedDebt - targetValue).fullMulDiv(WAD, _downDenominator(targetLtv, requestYieldRate, borrowRate, duration));
    // Rounds up so the redemption proceeds at the current quote cover repayment.
    collateralToFreeQuoted = principal.fullMulDivUp(WAD + _scaledRate(requestYieldRate, duration), WAD);
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
  function remediationDelta(
    uint256 principal,
    uint256 requestYieldRate,
    uint256,
    uint256 duration,
    uint256 priceDriftWad
  ) external pure returns (int256 delta) {
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

  /// @dev Existing debt drifted by the borrow rate over settlement: `D * (1 + Rb)`, rounded
  ///      down (the one-trip bound recomputes this term rounded up instead).
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
