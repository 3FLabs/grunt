// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IFacilityLP
/// @notice Interface for liquidity provider operations.
interface IFacilityLP {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits assets into the intent as a liquidity provider.
  /// @param id The intent ID.
  /// @param amount The amount to deposit.
  function deposit(uint256 id, uint256 amount) external;

  /// @notice Withdraws assets from the intent as a liquidity provider.
  /// @param id The intent ID.
  /// @param amount The amount to withdraw.
  function withdraw(uint256 id, uint256 amount) external;

  /// @notice Claims resolved assets for the intent.
  /// @param id The intent ID.
  function claim(uint256 id) external;
}
