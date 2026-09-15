// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title LibTransientSlot
/// @author 3F Protocol
/// @notice Typed load/store helpers over raw transient storage slots.
/// @dev Attach to slot constants (`using LibTransientSlot for bytes32`) so call sites read as
///      `SLOT.tLoadAddress()` and `SLOT.tStoreAddress(value)`.
library LibTransientSlot {
  /// @dev Reads an address from a transient slot.
  function tLoadAddress(bytes32 slot) internal view returns (address value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  /// @dev Reads a uint256 from a transient slot.
  function tLoadUint(bytes32 slot) internal view returns (uint256 value) {
    assembly ("memory-safe") {
      value := tload(slot)
    }
  }

  /// @dev Writes an address to a transient slot.
  function tStoreAddress(bytes32 slot, address value) internal {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }

  /// @dev Writes a uint256 to a transient slot.
  function tStoreUint(bytes32 slot, uint256 value) internal {
    assembly ("memory-safe") {
      tstore(slot, value)
    }
  }
}
