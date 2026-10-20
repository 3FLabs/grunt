// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFacilityCaps
/// @author 3F Protocol
/// @notice Deposit caps consumed by facilities with EXTERNAL deposit caps, implemented by
///         FacilityAbsoluteCaps (shared pools) and FacilityDynamicCaps (time-weighted caps).
///         Multipliers are signed Q12.12 fixed-point values (value = raw / 2^12) and facilities
///         send amounts scaled to 18 decimals (see LibCaps).
/// @dev The 64-bit cap ID is read by each implementation: FacilityAbsoluteCaps splits it into
///      up to four 16-bit pool IDs whose capacities add up, FacilityDynamicCaps uses it as a
///      single key.
interface IFacilityCaps {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a cap is consumed (or released back, for a negative multiplier).
  /// @dev FacilityAbsoluteCaps emits it once per pool it changes, with that pool ID.
  /// @param id The cap ID.
  /// @param amount The deposit amount the consumption was computed from.
  /// @param multiplier The signed Q12.12 multiplier applied to the amount.
  /// @param moved The capacity this cap gave (positive multiplier) or got back (negative).
  /// @param newCap The remaining capacity after the call.
  event CapConsumed(uint64 indexed id, uint256 amount, int24 multiplier, uint256 moved, uint128 newCap);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ERRORS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a consumption would bring a cap below zero.
  /// @param id The cap ID.
  error InsufficientCap(uint64 id);

  /// @notice Thrown when a release would credit back more than the consumption, bringing a cap
  ///         above its hard cap (FacilityAbsoluteCaps).
  /// @param id The cap ID.
  error HardCapExceeded(uint64 id);

  /// @notice Thrown when validating a zero multiplier, which consumes nothing, or
  ///         type(int24).min, which has no int24 negation to release with.
  error InvalidMultiplier();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Reverts if a deposit cap word cannot reference this contract with `id` and
  ///         `multiplier`.
  /// @dev Called by facilities when such a word is set. Reverts with InvalidMultiplier for zero
  ///      and type(int24).min, plus any implementation-specific ID check.
  /// @param id The cap ID.
  /// @param multiplier The signed Q12.12 multiplier.
  function validate(uint64 id, int24 multiplier) external view;

  /// @notice Returns an amount consumable right now: for a positive multiplier the maximum
  ///         depositable amount cap / multiplier, for a negative multiplier the releasable amount
  ///         consumed / |multiplier| on FacilityAbsoluteCaps, which can sit fewer than
  ///         4096 / |multiplier| + 1 units below the maximum since releases round down.
  ///         FacilityAbsoluteCaps sums the capacities (or consumptions) of its pool IDs.
  /// @param id The cap ID.
  /// @param multiplier The signed Q12.12 multiplier.
  /// @return amount The consumable amount, type(uint256).max when the direction is
  ///         unbounded (multiplier == 0, or multiplier < 0 on FacilityDynamicCaps).
  function available(uint64 id, int24 multiplier) external view returns (uint256 amount);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         CONSUMER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Consumes amount * multiplier from a cap.
  /// @dev A positive multiplier decreases the cap and reverts with InsufficientCap if it would go
  ///      below zero. A negative multiplier is the release direction: FacilityAbsoluteCaps
  ///      credits amount * |multiplier| of consumption back and reverts with HardCapExceeded
  ///      above it, FacilityDynamicCaps does nothing. FacilityAbsoluteCaps spreads it over its
  ///      pool IDs, first pool first in both directions, and reverts only if they cannot absorb
  ///      it together. Gated by the consumer role.
  /// @param id The cap ID.
  /// @param amount The deposit amount to consume capacity for.
  /// @param multiplier The signed Q12.12 multiplier applied to the amount.
  function consume(uint64 id, uint256 amount, int24 multiplier) external;
}
