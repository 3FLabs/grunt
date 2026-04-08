// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFacilityRequests
/// @author 3F Protocol
/// @notice Interface for request operations.
interface IFacilityRequests {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pulls assets for the given intent ID.
  /// @param id The intent ID.
  /// @param amount The amount to pull.
  function pull(uint256 id, uint256 amount) external;

  /// @notice Repays assets for the given intent ID.
  /// @param id The intent ID.
  /// @param amount The amount to repay.
  function repay(uint256 id, uint256 amount) external;
}
