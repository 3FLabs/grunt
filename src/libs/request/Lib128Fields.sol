// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MAX_128_BITS} from "../Constants.sol";

/// @title Lib128Fields
/// @author 3F Protocol
/// @notice Library for gas-efficient reading and writing of packed uint128 fields in storage.
/// @dev Packs two uint128 values into a single uint256 storage slot: the lower 128 bits hold
///      ptField, the upper 128 bits hold ytField. No overflow checks are performed; the caller
///      must ensure values fit in uint128.
library Lib128Fields {
  /// @dev Single SLOAD; unpacks the lower 128 bits into ptField and the upper 128 bits into ytField.
  function fromSlot(uint256 slot) internal view returns (uint128 ptField, uint128 ytField) {
    assembly ("memory-safe") {
      let val := sload(slot)
      ptField := and(val, MAX_128_BITS)
      ytField := shr(128, val)
    }
  }

  /// @dev Packs ptField (lower 128 bits) and ytField (upper 128 bits) into a single SSTORE.
  ///      No validation is performed; values exceeding uint128 are silently truncated.
  function write(uint256 slot, uint128 ptField, uint128 ytField) internal {
    assembly ("memory-safe") {
      let val := or(ptField, shl(128, ytField))
      sstore(slot, val)
    }
  }
}
