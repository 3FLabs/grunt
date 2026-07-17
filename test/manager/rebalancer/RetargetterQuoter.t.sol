// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RetargetterQuoter} from "src/manager/rebalancer/RetargetterQuoter.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title RetargetterQuoterTest
/// @notice Unit and fuzz tests for the stateless RetargetterQuoter math. Exact expectations
///         are recomputed in the test from the same integer formulas; hand-derived fixtures
///         anchor the values (including a guard against a plausible mis-derivation of the
///         LTV-down denominator).
contract RetargetterQuoterTest is Test {
  using FixedPointMathLib for uint256;

  RetargetterQuoter internal quoter;

  uint256 internal constant WAD = 1e18;
  uint256 internal constant RATE_YEAR = 365 days;

  uint256 internal constant TICK = 1 days;
  uint256 internal constant THRESHOLD = 10 hours;
  uint256 internal constant HORIZON = 365 days;

  function setUp() public {
    quoter = new RetargetterQuoter();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Mirrors the quoter's rate scaling: `rate * duration / 365 days` (floor).
  function _scaled(uint256 rate, uint256 duration) internal pure returns (uint256) {
    return rate.fullMulDiv(duration, RATE_YEAR);
  }

  /// @dev Mirrors the quoter's grown target term: `targetLtv * K * (1 + Yc)` (floor at each step).
  function _grownTarget(uint256 collateralQuoted, uint256 targetLtv, uint256 collateralYieldRate, uint256 duration)
    internal
    pure
    returns (uint256)
  {
    return collateralQuoted.fullMulDiv(targetLtv, WAD).fullMulDiv(WAD + _scaled(collateralYieldRate, duration), WAD);
  }

  /// @dev Mirrors the quoter's drifted debt term: `D * (1 + Rb)` (floor).
  function _driftedDebt(uint256 debt, uint256 borrowRate, uint256 duration) internal pure returns (uint256) {
    return debt.fullMulDiv(WAD + _scaled(borrowRate, duration), WAD);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      LTV-UP PRINCIPAL                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_ltvUpPrincipal_zeroRateIdealFixture() public view {
    // Ideal zero-rate formula: x = (tau * K - D) / (1 - tau)
    // K = 10_000, D = 5_000, tau = 0.7: x = 2_000 / 0.3 = 6_666.66...
    uint256 principal = quoter.ltvUpPrincipal(10_000e18, 5_000e18, 0.7e18, 0, 0, 0, 0);
    assertEq(principal, uint256(2_000e18) * WAD / 0.3e18, "ideal formula");
    assertEq(principal, 6666666666666666666666, "literal anchor");
    // Sanity: borrowing x and supplying it lands exactly at target (up to flooring):
    // (D + x) / (K + x) == tau
    assertApproxEqRel((5_000e18 + principal) * WAD / (10_000e18 + principal), 0.7e18, 1e6, "lands at target");
  }

  function test_ltvUpPrincipal_extendedRatesFixture() public view {
    // All three rates nonzero over a 30-day subscription window
    uint256 k = 10_000e18;
    uint256 d = 5_000e18;
    uint256 tau = 0.7e18;
    uint256 yr = 0.04e18;
    uint256 rb = 0.05e18;
    uint256 yc = 0.03e18;
    uint256 dt = 30 days;

    uint256 principal = quoter.ltvUpPrincipal(k, d, tau, yr, rb, yc, dt);

    // Exact recomputation from the same integer formulas
    uint256 numerator = _grownTarget(k, tau, yc, dt) - _driftedDebt(d, rb, dt);
    uint256 denominator = WAD - tau + _scaled(yr, dt);
    assertEq(principal, numerator.fullMulDiv(WAD, denominator), "extended formula");
    // Anchor: about 6_583.56 (debt drift shrinks the room, request yield thickens the divisor)
    assertApproxEqRel(principal, 6583.56e18, 1e15, "anchor");
    // The rate-adjusted principal sits below the zero-rate ideal for these inputs
    assertLt(principal, quoter.ltvUpPrincipal(k, d, tau, 0, 0, 0, 0), "below ideal");
  }

  function test_ltvUpPrincipal_returnsZeroAtOrAboveTarget() public view {
    // Exactly at target: numerator is zero, not positive
    assertEq(quoter.ltvUpPrincipal(10_000e18, 7_000e18, 0.7e18, 0, 0, 0, 0), 0, "at target");
    // Above target
    assertEq(quoter.ltvUpPrincipal(10_000e18, 8_000e18, 0.7e18, 0, 0, 0, 0), 0, "above target");
    // Debt drift alone can push an at-target position over: still zero
    assertEq(quoter.ltvUpPrincipal(10_000e18, 7_000e18, 0.7e18, 0, 0.05e18, 0, 30 days), 0, "drifted above");
  }

  function test_ltvUpPrincipal_revertsOnFullTargetWithZeroYield() public {
    // targetLtv == WAD with a zero request yield estimate: denominator 1 - tau + Yr == 0
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.ltvUpPrincipal(10_000e18, 5_000e18, WAD, 0, 0, 0, 0);
  }

  function test_ltvUpPrincipal_fullTargetWithNonzeroYieldDoesNotRevert() public view {
    // Same full target but a nonzero request yield keeps the denominator positive: x = (K - D) / Yr
    uint256 principal = quoter.ltvUpPrincipal(10_000e18, 5_000e18, WAD, 0.1e18, 0, 0, 365 days);
    assertEq(principal, uint256(5_000e18) * WAD / 0.1e18, "denominator is Yr alone");
  }

  function testFuzz_ltvUpPrincipal_monotoneInDebt(
    uint256 collateral,
    uint256 targetLtv,
    uint256 debtLow,
    uint256 debtHigh
  ) public view {
    collateral = bound(collateral, 1e6, 1e30);
    targetLtv = bound(targetLtv, 1, WAD - 1);
    uint256 grownTarget = collateral * targetLtv / WAD;
    debtHigh = bound(debtHigh, 0, grownTarget * 2 + 1);
    debtLow = bound(debtLow, 0, debtHigh);

    uint256 principalLow = quoter.ltvUpPrincipal(collateral, debtLow, targetLtv, 0, 0, 0, 0);
    uint256 principalHigh = quoter.ltvUpPrincipal(collateral, debtHigh, targetLtv, 0, 0, 0, 0);

    // Principal shrinks as debt rises toward the target
    assertGe(principalLow, principalHigh, "monotone in debt");
    if (debtHigh >= grownTarget) {
      // At or above target with zero rates: no room, principal is zero
      assertEq(principalHigh, 0, "zero at or above target");
    } else {
      // Strictly below target: a positive borrow always exists
      assertGt(principalHigh, 0, "positive below target");
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     DIRECTION DISPATCH                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_retargetPrincipal_routesByDirection() public view {
    // Under-leveraged: routes to the LTV-up formula over the subscription duration
    assertEq(
      quoter.retargetPrincipal(10_000e18, 5_000e18, 0.7e18, 0.04e18, 0.05e18, 0.03e18, 30 days, 7 days),
      quoter.ltvUpPrincipal(10_000e18, 5_000e18, 0.7e18, 0.04e18, 0.05e18, 0.03e18, 30 days),
      "up route uses the subscription duration"
    );
    // Over-leveraged: routes to the LTV-down formula over the redemption duration
    (uint256 downPrincipal,) = quoter.ltvDownPrincipal(10_000e18, 8_000e18, 0.7e18, 0.04e18, 0.05e18, 0.03e18, 7 days);
    assertEq(
      quoter.retargetPrincipal(10_000e18, 8_000e18, 0.7e18, 0.04e18, 0.05e18, 0.03e18, 30 days, 7 days),
      downPrincipal,
      "down route uses the redemption duration"
    );
    // Exactly at target: no principal in either direction
    assertEq(
      quoter.retargetPrincipal(10_000e18, 7_000e18, 0.7e18, 0.04e18, 0.05e18, 0.03e18, 30 days, 7 days), 0, "at target"
    );
  }

  function test_retargetPrincipal_revertsOnZeroCollateral() public {
    vm.expectRevert(FixedPointMathLib.DivWadFailed.selector);
    quoter.retargetPrincipal(0, 1e18, 0.7e18, 0, 0, 0, 0, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LTV-DOWN PRINCIPAL                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_ltvDownPrincipal_extendedRatesFixture() public view {
    // Extended-rates fixture: K = 20m, D = 11m, tau = 0.5, rb = 5%/yr, yr = 4%/yr,
    // yc = 0, dt = one month. A plausible mis-derivation drops the tau factor on the
    // request-yield term (denominator 1 + Rb - tau - Yr = 0.5008) and gets ~2_088_000 for
    // the principal; the correct denominator 1 + Rb - tau * (1 + Yr) = 0.5025 gives
    // 1_045_833.33 / 0.5025 = 2_081_260.
    uint256 k = 20_000_000e18;
    uint256 d = 11_000_000e18;
    uint256 tau = 0.5e18;
    uint256 yr = 0.04e18;
    uint256 rb = 0.05e18;
    uint256 dt = 365 days / 12;

    (uint256 principal, uint256 collateralToFreeQuoted) = quoter.ltvDownPrincipal(k, d, tau, yr, rb, 0, dt);

    // Exact recomputation from the same integer formulas
    uint256 numerator = _driftedDebt(d, rb, dt) - _grownTarget(k, tau, 0, dt);
    uint256 denominator = (WAD + _scaled(rb, dt)) - tau.fullMulDiv(WAD + _scaled(yr, dt), WAD);
    uint256 expectedPrincipal = numerator.fullMulDiv(WAD, denominator);
    assertEq(principal, expectedPrincipal, "extended principal formula");
    assertEq(
      collateralToFreeQuoted, expectedPrincipal.fullMulDivUp(WAD + _scaled(yr, dt), WAD), "extended collateral formula"
    );

    // Hand-derived anchors: ~2_081_260 principal and ~2_088_198 collateral to free
    assertApproxEqRel(principal, 2_081_260e18, 1e12, "principal anchor");
    assertApproxEqRel(collateralToFreeQuoted, 2_088_198e18, 1e12, "collateral anchor");
    // The mis-derived ~2_088_000 principal is rejected
    assertLt(principal, 2_082_000e18, "not the mis-derived value");
  }

  function test_ltvDownPrincipal_returnsZeroAtOrBelowTarget() public view {
    // Exactly at target: numerator is zero, not positive
    (uint256 principal, uint256 collateralToFreeQuoted) =
      quoter.ltvDownPrincipal(10_000e18, 7_000e18, 0.7e18, 0, 0, 0, 0);
    assertEq(principal, 0, "at target principal");
    assertEq(collateralToFreeQuoted, 0, "at target collateral");
    // Below target
    (principal, collateralToFreeQuoted) = quoter.ltvDownPrincipal(10_000e18, 5_000e18, 0.7e18, 0, 0, 0, 0);
    assertEq(principal, 0, "below target principal");
    assertEq(collateralToFreeQuoted, 0, "below target collateral");
  }

  function test_ltvDownPrincipal_revertsOnNonPositiveDenominator() public {
    // Zero denominator: tau == WAD with zero rates gives 1 + Rb == tau * (1 + Yr) exactly
    // (numerator positive: D > K so the check is reached)
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.ltvDownPrincipal(1_000e18, 2_000e18, WAD, 0, 0, 0, 0);
    // Negative denominator: huge request yield makes tau * (1 + Yr) exceed 1 + Rb
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.ltvDownPrincipal(1_000e18, 2_000e18, 0.9e18, 0.5e18, 0, 0, 365 days);
  }

  function test_ltvDownPrincipal_collateralToFreeRoundsUp() public view {
    // K = 2, D = 1.5, tau = 0.5, yr = 10%/yr over a full year (Yr = 0.1):
    // principal = 0.5 / 0.45 = 1.111... (floored); collateral = principal * 1.1 does not
    // divide evenly, so the ceiling differs from the floor by one wei.
    (uint256 principal, uint256 collateralToFreeQuoted) =
      quoter.ltvDownPrincipal(2e18, 1.5e18, 0.5e18, 0.1e18, 0, 0, 365 days);

    assertEq(principal, 1111111111111111111, "floored principal");
    uint256 floorValue = principal.fullMulDiv(WAD + 0.1e18, WAD);
    assertEq(collateralToFreeQuoted, floorValue + 1, "rounded up by one wei");
    assertEq(collateralToFreeQuoted, 1222222222222222223, "literal anchor");
  }

  function test_ltvDownPrincipal_collateralEqualsPrincipalWithZeroYields() public view {
    // With yr == 0 and yc == 0 the collateral factor (1 + Yr) / (1 + Yc) is exactly one,
    // so ceiling rounding has nothing to round: collateralToFreeQuoted == principal.
    (uint256 principal, uint256 collateralToFreeQuoted) =
      quoter.ltvDownPrincipal(10_000e18, 8_000e18, 0.7e18, 0, 0.05e18, 0, 30 days);
    assertGt(principal, 0, "down direction sanity");
    assertEq(collateralToFreeQuoted, principal, "one-to-one with zero yields");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       PAID DURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_paidDuration_oneTickMinimum() public view {
    // From the first second the borrower owes one full tick
    assertEq(quoter.paidDuration(0, TICK, THRESHOLD), TICK, "elapsed zero");
    assertEq(quoter.paidDuration(1, TICK, THRESHOLD), TICK, "elapsed one second");
    // The minimum also holds with a zero threshold (paidTicks floor hits exactly zero)
    assertEq(quoter.paidDuration(0, TICK, 0), TICK, "zero threshold");
  }

  function test_paidDuration_promotionBoundaries() public view {
    // Worked example (tick 1 day, threshold 10 hours): one day is owed until
    // 1d10h, two days until 2d10h; promotion to k + 1 ticks happens exactly at
    // elapsed == k * tick + threshold.
    // k = 1: still one tick one second before the boundary
    assertEq(quoter.paidDuration(1 days + 10 hours - 1, TICK, THRESHOLD), 1 days, "below first boundary");
    assertEq(quoter.paidDuration(1 days + 10 hours, TICK, THRESHOLD), 2 days, "at first boundary");
    // k = 2
    assertEq(quoter.paidDuration(2 days + 10 hours - 1, TICK, THRESHOLD), 2 days, "below second boundary");
    assertEq(quoter.paidDuration(2 days + 10 hours, TICK, THRESHOLD), 3 days, "at second boundary");
  }

  function test_paidDuration_mirroredFormulaCounterexample() public view {
    // PR #195 shipped the mirrored formula floor((t + threshold) / tick), which promotes at
    // k * tick + (tick - threshold) and matches the intended behavior only at
    // threshold == tick / 2. With threshold = 10 hours != 12 hours, at t = 1d10h the correct
    // formula already owes 2 ticks while the mirrored one still owes 1.
    uint256 elapsed = 1 days + 10 hours;
    uint256 mirroredTicks = (elapsed + THRESHOLD) / TICK;
    if (mirroredTicks == 0) mirroredTicks = 1;
    uint256 mirroredDuration = mirroredTicks * TICK;

    uint256 duration = quoter.paidDuration(elapsed, TICK, THRESHOLD);
    assertEq(duration, 2 days, "correct formula");
    assertEq(mirroredDuration, 1 days, "mirrored formula");
    assertTrue(duration != mirroredDuration, "formulas diverge at the boundary");
  }

  function test_paidDuration_revertsOnInvalidTickParameters() public {
    // Zero tick duration
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.paidDuration(0, 0, 0);
    // Threshold equal to the tick duration
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.paidDuration(0, TICK, TICK);
    // Threshold above the tick duration
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.paidDuration(0, TICK, TICK + 1);
  }

  function testFuzz_paidDuration_properties(uint256 elapsedLow, uint256 elapsedHigh, uint256 tick, uint256 threshold)
    public
    view
  {
    tick = bound(tick, 1, 30 days);
    threshold = bound(threshold, 0, tick - 1);
    elapsedHigh = bound(elapsedHigh, 0, 1e30);
    elapsedLow = bound(elapsedLow, 0, elapsedHigh);

    uint256 durationLow = quoter.paidDuration(elapsedLow, tick, threshold);
    uint256 durationHigh = quoter.paidDuration(elapsedHigh, tick, threshold);

    // A nonzero whole number of ticks, at least one
    assertEq(durationLow % tick, 0, "whole ticks");
    assertGe(durationLow, tick, "one-tick minimum");
    // Monotonically nondecreasing in elapsed
    assertGe(durationHigh, durationLow, "monotone in elapsed");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REPAYMENT OWED                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_repaymentOwed_workedExample() public view {
    // Worked example: PT 1_000_000, YT 100_000, horizon 365 days, tick 1 day, threshold 10 hours,
    // outstanding 3 days 11 hours: 4 ticks owed (promotion to 4 happened at 3d10h), yield
    // 100_000 * 4 / 365 = 1_095.89 rounds up to 1_096.
    uint256 owed = quoter.repaymentOwed(1_000_000, 100_000, 3 days + 11 hours, TICK, THRESHOLD, HORIZON);
    assertEq(owed, 1_000_000 + 1_096, "worked example");
  }

  function test_repaymentOwed_cappedAtHorizon() public view {
    // Far beyond the horizon the paid duration caps at the horizon: owed == pt + yt exactly
    uint256 owed = quoter.repaymentOwed(1_000_000, 100_000, 400 days, TICK, THRESHOLD, HORIZON);
    assertEq(owed, 1_100_000, "hard cap at pt + yt");
    // Still capped arbitrarily far out
    owed = quoter.repaymentOwed(1_000_000, 100_000, 10 * 365 days, TICK, THRESHOLD, HORIZON);
    assertEq(owed, 1_100_000, "cap holds far out");
  }

  function test_repaymentOwed_zeroSupplies() public view {
    assertEq(quoter.repaymentOwed(0, 0, 0, TICK, THRESHOLD, HORIZON), 0, "nothing consumed");
    assertEq(quoter.repaymentOwed(0, 0, 400 days, TICK, THRESHOLD, HORIZON), 0, "nothing consumed, late");
  }

  function test_repaymentOwed_revertsOnZeroHorizon() public {
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.repaymentOwed(1_000_000, 100_000, 1 days, TICK, THRESHOLD, 0);
  }

  function testFuzz_repaymentOwed_bounds(uint256 ptSupply, uint256 ytSupply, uint256 elapsedLow, uint256 elapsedHigh)
    public
    view
  {
    ptSupply = bound(ptSupply, 0, 1e30);
    ytSupply = bound(ytSupply, 0, 1e30);
    elapsedHigh = bound(elapsedHigh, 0, 1e12);
    elapsedLow = bound(elapsedLow, 0, elapsedHigh);

    uint256 owedLow = quoter.repaymentOwed(ptSupply, ytSupply, elapsedLow, TICK, THRESHOLD, HORIZON);
    uint256 owedHigh = quoter.repaymentOwed(ptSupply, ytSupply, elapsedHigh, TICK, THRESHOLD, HORIZON);

    // The horizon cap makes pt + yt the absolute maximum
    assertLe(owedHigh, ptSupply + ytSupply, "capped at pt + yt");
    // Minimum one tick plus ceiling rounding: any nonzero yield supply owes at least one wei
    if (ytSupply > 0) assertGt(owedLow, ptSupply, "one-tick minimum yield");
    // Monotonically nondecreasing in elapsed
    assertGe(owedHigh, owedLow, "monotone in elapsed");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      REMEDIATION DELTA                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_remediationDelta_positiveDrift() public view {
    // rho = 1.02: surplus of repayment * 0.02, rounded down
    uint256 principal = 1_000_000e18;
    uint256 yr = 0.04e18;
    uint256 dt = 365 days / 12;
    int256 delta = quoter.remediationDelta(principal, yr, dt, 1.02e18);

    uint256 repayment = principal.fullMulDiv(WAD + _scaled(yr, dt), WAD);
    assertEq(delta, int256(repayment.fullMulDiv(0.02e18, WAD)), "surplus formula");
    assertGt(delta, 0, "positive sign");
    // Anchor: about 20_066.67 (1_003_333.33 repayment times 2%)
    assertApproxEqRel(uint256(delta), 20_066.66e18, 1e15, "anchor");

    // Floor rounding demonstrated on a tiny fixture: 101 * 0.5 = 50.5 floors to 50
    assertEq(quoter.remediationDelta(101, 0, 0, 1.5e18), int256(50), "rounds down");
  }

  function test_remediationDelta_negativeDrift() public view {
    // rho = 0.98: shortfall of repayment * 0.02, magnitude rounded up
    uint256 principal = 1_000_000e18;
    uint256 yr = 0.04e18;
    uint256 dt = 365 days / 12;
    int256 delta = quoter.remediationDelta(principal, yr, dt, 0.98e18);

    uint256 repayment = principal.fullMulDiv(WAD + _scaled(yr, dt), WAD);
    assertEq(delta, -int256(repayment.fullMulDivUp(0.02e18, WAD)), "shortfall formula");
    assertLt(delta, 0, "negative sign");

    // Ceiling rounding demonstrated on a tiny fixture: 101 * 0.5 = 50.5 rounds up to 51
    assertEq(quoter.remediationDelta(101, 0, 0, 0.5e18), int256(-51), "magnitude rounds up");
  }

  function test_remediationDelta_zeroDriftIsZero() public view {
    // rho == 1: proceeds match the repayment exactly, no remediation either way
    assertEq(quoter.remediationDelta(1_000_000e18, 0.04e18, 30 days, WAD), int256(0), "zero at unity");
  }

  function test_remediationDelta_revertsOnOverflow() public {
    // Magnitudes in (int256 max, uint256 max] hit the explicit InvalidParameters guard;
    // anything larger reverts inside fullMulDiv (512-bit product over uint256) before the
    // guard is reached, so 2^255 with a unit multiplier is the cleanest reachable case.
    uint256 hugePrincipal = uint256(1) << 255;
    // Surplus branch: repayment == 2^255, magnitude == 2^255 > int256 max
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.remediationDelta(hugePrincipal, 0, 0, 2e18);
    // Shortfall branch: rho == 0 makes the magnitude the full repayment, 2^255 > int256 max
    vm.expectRevert(LibRetargetterErrors.InvalidParameters.selector);
    quoter.remediationDelta(hugePrincipal, 0, 0, 0);
  }

  function testFuzz_remediationDelta_sign(uint256 principal, uint256 yr, uint256 dt, uint256 priceDriftWad)
    public
    view
  {
    principal = bound(principal, 0, 1e30);
    yr = bound(yr, 0, 1e18);
    dt = bound(dt, 0, 366 days);
    priceDriftWad = bound(priceDriftWad, 0, 100e18);

    int256 delta = quoter.remediationDelta(principal, yr, dt, priceDriftWad);

    if (priceDriftWad >= WAD) {
      assertGe(delta, 0, "surplus is nonnegative");
    } else {
      assertLe(delta, 0, "shortfall is nonpositive");
      // With an actual repayment outstanding, ceiling rounding makes any downward drift owe
      if (principal > 0 && priceDriftWad < WAD) assertLt(delta, 0, "strict shortfall");
    }
    if (priceDriftWad == WAD) assertEq(delta, 0, "zero at unity");
  }
}
