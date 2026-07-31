// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFacilityCaps
/// @author 3F Protocol
/// @notice Shared deposit-cap pool consumed by facilities with DYNAMIC deposit caps.
///         Multipliers are signed Q12.12 fixed-point values (value = raw / 2^12).
interface IFacilityCaps {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a cap is consumed (or released back, for a negative multiplier).
  /// @param id The cap ID.
  /// @param amount The deposit amount the consumption was computed from.
  /// @param multiplier The signed Q12.12 multiplier applied to the amount.
  /// @param newCap The remaining shared capacity after the call.
  event CapConsumed(uint32 indexed id, uint256 amount, int24 multiplier, uint128 newCap);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a consumption would bring a cap below zero.
  /// @param id The cap ID.
  error InsufficientCap(uint32 id);

  /// @notice Thrown when a release would bring a cap above its hard cap.
  /// @param id The cap ID.
  error HardCapExceeded(uint32 id);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the maximum amount consumable right now: for a positive multiplier the
  ///         depositable amount cap / multiplier, for a negative multiplier the releasable amount
  ///         (hardCap - cap) / |multiplier|.
  /// @param id The cap ID.
  /// @param multiplier The signed Q12.12 multiplier.
  /// @return amount The maximum consumable amount (type(uint256).max if multiplier == 0).
  function available(uint32 id, int24 multiplier) external view returns (uint256 amount);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSUMER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes amount * multiplier from a cap.
  /// @dev A positive multiplier decreases the cap and reverts with InsufficientCap if it would go
  ///      below zero. A negative multiplier increases the cap by amount * |multiplier| and reverts
  ///      with HardCapExceeded if it would go above the hard cap. Gated by the consumer role.
  /// @param id The cap ID.
  /// @param amount The deposit amount to consume capacity for.
  /// @param multiplier The signed Q12.12 multiplier applied to the amount.
  function consume(uint32 id, uint256 amount, int24 multiplier) external;
}
