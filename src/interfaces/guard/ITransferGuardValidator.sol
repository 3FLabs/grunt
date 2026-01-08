// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title ITransferGuardValidator
/// @notice Interface for third-party address validation contracts.
/// @dev Called by TransferGuard when an address has NONE status.
interface ITransferGuardValidator {
  /// @notice Checks if an address is authorized.
  /// @param account The address to validate
  /// @return True if the address is authorized, false otherwise
  function isAuthorized(address account) external view returns (bool);
}
