// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterQuoter} from "../../interfaces/manager/rebalancer/IRetargetterQuoter.sol";
import {LibRetargetterErrors} from "../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title RetargetterQuoter
/// @author 3F Protocol
/// @notice Stateless pure math for sizing retargetting operations and pricing their repayment.
/// @dev Deployed once per chain and shared by every Retargetter instance through the factory.
///      A retargetting operation moves a leveraged position toward its target loan-to-value
///      ratio using a bridge loan that spans the collateral's asynchronous settlement window;
///      sizing assumes the collateral price holds over the window (settlement price ratio
///      rho = 1). Rounding: principals round down, everything the protocol must pay or set
///      aside rounds up. See {IRetargetterQuoter} for units and parameter semantics; the
///      model and the derivation of every formula live in
///      docs/retargetter.md#model-and-notation. Notation in the formula comments below:
///      K = collateralQuoted, D = debt, t = targetLtv, x = the principal being sized;
///      Yr, Rb, Yc = requestYieldRate, borrowRate, collateralYieldRate scaled by
///      `duration / 365 days` (see `_scaledRate`).
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
    uint256 collateralYieldRate,
    uint256 subscriptionDuration,
    uint256 redemptionDuration
  ) external pure returns (uint256 principal) {
    uint256 current = debt.divWad(collateralQuoted);
    if (current < targetLtv) {
      principal = ltvUpPrincipal(
        collateralQuoted, debt, targetLtv, requestYieldRate, borrowRate, collateralYieldRate, subscriptionDuration
      );
    } else if (current > targetLtv) {
      (principal,) = ltvDownPrincipal(
        collateralQuoted, debt, targetLtv, requestYieldRate, borrowRate, collateralYieldRate, redemptionDuration
      );
    }
  }

  /// @inheritdoc IRetargetterQuoter
  function ltvUpPrincipal(
    uint256 collateralQuoted,
    uint256 debt,
    uint256 targetLtv,
    uint256 requestYieldRate,
    uint256 borrowRate,
    uint256 collateralYieldRate,
    uint256 duration
  ) public pure returns (uint256 principal) {
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
  ) public pure returns (uint256 principal, uint256 collateralToFreeQuoted) {
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
