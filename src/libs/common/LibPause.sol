// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibChecks} from "./LibChecks.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/// @title LibPause
/// @notice Library for managing pausable state using a uint40 value.
/// @dev The uint40 value represents a pause-until timestamp.
///
///      Pause states:
///      - Value of 0 (NOT_PAUSED): Not paused
///      - Value > 0: Paused until block.timestamp > value
///      - Value of type(uint40).max (PERMANENT_PAUSE): Effectively permanent pause (~35,000 years)
library LibPause {
  using LibChecks for uint256;
  using FixedPointMathLib for uint256;

  /// @notice Value representing a permanent pause state.
  /// @dev Set to type(uint40).max, which corresponds to a timestamp ~35,000 years in the future.
  ///      Use this constant to pause indefinitely.
  uint40 internal constant PERMANENT_PAUSE = type(uint40).max;

  /// @notice Value representing an unpaused state.
  /// @dev Set to 0. Since block.timestamp is always > 0 in practice,
  ///      a value of 0 means not paused.
  uint40 internal constant NOT_PAUSED = 0;

  /// @notice Checks if the pause state indicates paused.
  /// @param self The pause state value (pause-until timestamp).
  /// @return True if paused, false otherwise.
  function paused(uint40 self) internal view returns (bool) {
    return block.timestamp <= self;
  }

  /// @notice Returns a pause state representing a timed pause.
  /// @dev If duration would overflow 40 bits, the result is capped at PERMANENT_PAUSE.
  /// @param duration The duration to pause for (must be non-zero).
  /// @return The pause-until timestamp.
  function pauseFor(uint256 duration) internal view returns (uint40) {
    duration.checkNotZero();
    uint256 pauseUntil = block.timestamp + duration;
    // casting to 'uint40' is safe because pauseUntil is equal or less than PERMANENT_PAUSE
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint40(pauseUntil.min(PERMANENT_PAUSE));
  }
}
