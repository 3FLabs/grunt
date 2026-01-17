// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibErrors} from "./LibErrors.sol";

/// @title LibAddress
/// @notice Library for address validation utilities.
library LibAddress {
  /// @dev Reverts if the address is the zero address.
  /// @param addr The address to check.
  function checkNotZero(address addr) internal pure {
    if (addr == address(0)) revert LibErrors.AddressZero();
  }

  /// @dev Reverts if the address is not a contract.
  /// @param addr The address to check.
  function checkContract(address addr) internal view {
    if (addr.code.length == 0) revert LibErrors.InvalidContract(addr);
  }

  /// @dev Reverts if the two assets do not match.
  /// @param asset1 The first asset.
  /// @param asset2 The second asset.
  function checkAssetsMatch(address asset1, address asset2) internal pure {
    if (asset1 != asset2) revert LibErrors.AssetMismatch(asset1, asset2);
  }
}
