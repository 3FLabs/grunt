// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IIdleCreditVault
/// @author 3F Protocol
/// @notice Minimal interface for the Pareto (Idle Finance) Credit Vault strategy contract.
/// @dev Only includes view functions used by ParetoFund for withdrawal state detection.
interface IIdleCreditVault {
  /// @notice Returns the epoch number in which the last withdrawal was requested for an address.
  /// @param account The address to query.
  /// @return The epoch number of the last withdrawal request.
  function lastWithdrawRequest(address account) external view returns (uint256);

  /// @notice Returns the current epoch number.
  /// @return The current epoch number.
  function epochNumber() external view returns (uint256);
}
