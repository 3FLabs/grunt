// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IFacilityPositionManager
/// @notice Interface for position manager operations.
interface IFacilityPositionManager {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits into the position manager for an intent.
  /// @param id The intent ID.
  /// @param depositAmount The amount to deposit.
  /// @param borrowAmount The amount to borrow.
  /// @param useTarget Whether to use the target asset.
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget) external;

  /// @notice Withdraws from the position manager for an intent.
  /// @param id The intent ID.
  /// @param withdrawAmount The amount to withdraw.
  /// @param repayAmount The amount to repay.
  /// @param useTarget Whether to use the target asset.
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount, bool useTarget) external;

  /// @notice Burns position manager shares for an intent.
  /// @param id The intent ID.
  /// @param shares The number of shares to burn.
  /// @param useTarget Whether to use the target asset.
  function burnManager(uint256 id, uint256 shares, bool useTarget) external;
}
