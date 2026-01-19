// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableRoles} from "lib/solady/src/auth/OwnableRoles.sol";

/// @title FacilityRoles
/// @notice Abstract contract defining role constants for the Facility contract.
/// @dev Inherits OwnableRoles from solady for role-based access control.
abstract contract FacilityRoles is OwnableRoles {
  /// @notice Role for addresses authorized to facilitate intent operations.
  uint256 internal constant FACILITATOR_ROLE = _ROLE_0;

  /// @notice Role for addresses authorized to sign swaps as guardians.
  uint256 internal constant GUARDIAN_ROLE = _ROLE_1;
}
