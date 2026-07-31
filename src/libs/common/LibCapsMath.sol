// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibCapsMath
/// @author 3F Protocol
/// @notice Math for signed Q12.12 deposit-cap multipliers (value = raw / 2^12).
/// @dev All rounding favors the cap pool, and quotes compose safely with charges:
///      - `depositable` rounds down while `consumption` rounds up, so
///        `consumption(depositable(cap, m), m) <= cap` always holds;
///      - `releasable` and `release` both round down, so
///        `release(releasable(headroom, m), m) <= headroom` always holds.
///      An amount quoted by either view can therefore always be consumed without reverting.
///      Round trips never create capacity: `release(a, -m) <= consumption(a, m)`, with equality
///      whenever `a * m` is an exact multiple of 2^12 (e.g. integer multipliers).
library LibCapsMath {
  /// @notice Q12.12 fixed-point scale of the multiplier (a raw multiplier of 2^12 means 1x).
  uint256 internal constant MULTIPLIER_ONE = 1 << 12;

  /// @notice Capacity consumed by a deposit of `amount` at a positive `multiplier`.
  /// @dev Rounds up so the pool is never under-consumed. Only call with `multiplier >= 0`.
  function consumption(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    // casting to 'uint256' is safe because the multiplier is non-negative per the precondition
    // forge-lint: disable-next-line(unsafe-typecast)
    return FixedPointMathLib.mulDivUp(amount, uint256(int256(multiplier)), MULTIPLIER_ONE);
  }

  /// @notice Capacity released by an exit of `amount` at a negative `multiplier`.
  /// @dev Rounds down so the pool is never over-credited. Only call with `multiplier < 0`.
  function release(uint256 amount, int24 multiplier) internal pure returns (uint256) {
    // casting to 'uint256' is safe because the multiplier is negative per the precondition,
    // so its int256 negation is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    return FixedPointMathLib.mulDiv(amount, uint256(-int256(multiplier)), MULTIPLIER_ONE);
  }

  /// @notice Maximum amount depositable against a remaining `cap` at `multiplier`,
  ///         i.e. the largest `amount` with `consumption(amount, multiplier) <= cap`.
  /// @dev Rounds down (see the safety invariant above). Unbounded if `multiplier <= 0`.
  function depositable(uint256 cap, int24 multiplier) internal pure returns (uint256) {
    if (multiplier <= 0) return type(uint256).max;
    // casting to 'uint256' is safe because the multiplier is positive past the check above
    // forge-lint: disable-next-line(unsafe-typecast)
    return FixedPointMathLib.mulDiv(cap, MULTIPLIER_ONE, uint256(int256(multiplier)));
  }

  /// @notice Maximum amount releasable against a remaining `headroom` (hard cap minus cap) at a
  ///         negative `multiplier`, i.e. an `amount` with `release(amount, multiplier) <= headroom`.
  /// @dev Rounds down (see the safety invariant above). Only call with `multiplier < 0`.
  function releasable(uint256 headroom, int24 multiplier) internal pure returns (uint256) {
    // casting to 'uint256' is safe because the multiplier is negative per the precondition,
    // so its int256 negation is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    return FixedPointMathLib.mulDiv(headroom, MULTIPLIER_ONE, uint256(-int256(multiplier)));
  }
}
