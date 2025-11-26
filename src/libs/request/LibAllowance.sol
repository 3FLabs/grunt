// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MAX_128_BITS} from "../Constants.sol";

/// @title LibAllowance
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
    /// @solidity memory-safe-assembly
    assembly {
      result := sub(allowance, mul(amount, lt(allowance, MAX_128_BITS)))
    }
  }

  /// @dev Normalizes a uint128 allowance to uint256, converting infinite allowance representation.
  ///      Implements the logic: `result = allowance != type(uint128).max ? allowance : type(uint256).max`
  ///      This converts the internal infinite allowance representation (uint128.max) to the ERC20
  ///      standard representation (uint256.max) for compatibility with standard ERC20 interfaces.
  /// @param allowance The uint128 allowance value to normalize
  /// @return result The normalized allowance as uint256 (either the original value or uint256.max)
  function normalize(uint128 allowance) internal pure returns (uint256 result) {
    /// @solidity memory-safe-assembly
    assembly {
      result := or(allowance, sub(0, eq(allowance, MAX_128_BITS)))
    }
  }
}
