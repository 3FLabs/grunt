// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MAX_128_BITS} from "../Constants.sol";

/// @title LibAllowance
/// @author 3F Protocol
/// @notice Library for efficient allowance management with infinite approval support.
/// @dev Provides gas-optimized functions for consuming and normalizing uint128 allowances.
///      Implements infinite allowance semantics where type(uint128).max remains unchanged during consumption.
library LibAllowance {
  /// @dev Consumes (decreases) an allowance by a given amount, with infinite allowance support.
  ///      Implements the logic: `result = allowance < type(uint128).max ? allowance - amount : type(uint128).max`
  ///      If the allowance is type(uint128).max (infinite), it remains unchanged after consumption.
  ///      Otherwise, the amount is subtracted from the allowance. The caller must ensure that
  ///      allowance >= amount when allowance != type(uint128).max to avoid underflow.
  /// @param allowance The current allowance value (uint128)
  /// @param amount The amount to consume from the allowance (uint128)
  /// @return result The new allowance after consumption (uint128)
  function consume(uint128 allowance, uint128 amount) internal pure returns (uint128 result) {
    assembly ("memory-safe") {
      result := sub(allowance, mul(amount, lt(allowance, MAX_128_BITS)))
    }
  }
}
