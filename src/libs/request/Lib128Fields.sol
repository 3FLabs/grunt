// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MAX_128_BITS} from "../Constants.sol";

/// @title Lib128Fields
/// @author 3F Protocol
/// @notice Library for gas-efficient reading and writing of packed uint128 fields in storage.
/// @dev This library provides low-level storage operations for packing two uint128 values into a single
///      uint256 storage slot, optimizing gas usage by reducing the number of SLOAD and SSTORE operations.
///
///      Storage Layout:
///      - Lower 128 bits (bits 0-127): First field (ptField)
///      - Upper 128 bits (bits 128-255): Second field (ytField)
///
///      Benefits:
///      - Reduces storage costs by 50% when two uint128 values need to be stored together
///      - Enables atomic updates of both fields in a single SSTORE operation
///      - Optimized assembly implementations for maximum gas efficiency
///
///      Common Use Cases:
///      - Storing paired token balances (PT/YT tokens)
///      - Storing paired token supplies
///      - Storing paired token allowances
///      - Any scenario where two uint128 values are logically related and accessed together
///
///      Safety Considerations:
///      - The caller MUST ensure that values fit within uint128 bounds
///      - No overflow checks are performed for maximum gas efficiency
library Lib128Fields {
  /// @dev Reads two packed uint128 fields from a storage slot.
  ///      Uses optimized assembly to read a single storage slot and extract both uint128 values.
  ///      This is more gas-efficient than reading two separate storage slots.
  ///
  ///      Implementation Details:
  ///      1. Reads the full uint256 value from storage using SLOAD
  ///      2. Extracts the lower 128 bits (ptField) using bitwise AND with _128_MASK
  ///      3. Extracts the upper 128 bits (ytField) using right shift by 128 bits
  ///
  /// @param slot The storage slot to read from (can be any uint256 value representing a storage location)
  /// @return ptField The first field stored in the lower 128 bits
  /// @return ytField The second field stored in the upper 128 bits
  function fromSlot(uint256 slot) internal view returns (uint128 ptField, uint128 ytField) {
    assembly ("memory-safe") {
      let val := sload(slot)
      ptField := and(val, MAX_128_BITS)
      ytField := shr(128, val)
    }
  }

  /// @dev Writes two uint128 fields to a storage slot in packed form.
  ///      Uses optimized assembly to pack two uint128 values into a single uint256 and write to storage.
  ///      This is more gas-efficient than writing to two separate storage slots.
  ///
  ///      Implementation Details:
  ///      1. Places ptField in the lower 128 bits (no shifting needed)
  ///      2. Shifts ytField left by 128 bits to place it in the upper 128 bits
  ///      3. Combines both fields using bitwise OR
  ///      4. Writes the packed value to storage using SSTORE
  ///
  ///      Safety Considerations:
  ///      - The caller MUST ensure ptField and ytField are valid uint128 values
  ///      - If either value exceeds uint128.max, the upper bits will be silently truncated
  ///      - No validation is performed for maximum gas efficiency
  ///
  /// @param slot The storage slot to write to (can be any uint256 value representing a storage location)
  /// @param ptField The first field to store in the lower 128 bits (must fit in uint128)
  /// @param ytField The second field to store in the upper 128 bits (must fit in uint128)
  function write(uint256 slot, uint128 ptField, uint128 ytField) internal {
    assembly ("memory-safe") {
      let val := or(ptField, shl(128, ytField))
      sstore(slot, val)
    }
  }
}
