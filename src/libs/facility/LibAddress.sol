// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {LibFacilityErrors} from "./LibFacilityErrors.sol";

/// @title LibAddress
/// @author 3F Protocol
/// @notice Library for facility-specific address validation utilities.
library LibAddress {
  /// @dev Reverts if the two assets do not match.
  /// @param asset1 The first asset.
  /// @param asset2 The second asset.
  function checkAssetsMatch(address asset1, address asset2) internal pure {
    if (asset1 != asset2) revert LibFacilityErrors.AssetMismatch(asset1, asset2);
  }
}
