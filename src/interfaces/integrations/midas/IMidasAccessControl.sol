// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IMidasAccessControl
/// @author 3F Protocol
/// @notice Interface of the MidasAccessControl contract holding all Midas roles.
interface IMidasAccessControl {
  /// @notice Returns whether `account` has been granted `role`.
  /// @param role The role identifier.
  /// @param account The account to check.
  function hasRole(bytes32 role, address account) external view returns (bool);
}
