// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibCommonErrors
/// @author 3F Protocol
/// @notice Common error definitions shared across all modules.
library LibCommonErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GENERAL ERRORS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a required address parameter is the zero address.
  error AddressZero();

  /// @notice Thrown when an address parameter is not a contract (code.length == 0).
  /// @param addr The invalid address.
  error InvalidContract(address addr);

  /// @notice Thrown when an operation is called with a zero amount.
  error AmountZero();

  /// @notice Thrown when there is insufficient balance for a token operation.
  error InsufficientBalance();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     PAUSABLE ERRORS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an operation is attempted while the contract is paused.
  error Paused();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        LTV ERRORS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the provided LTV is invalid (zero or greater than WAD).
  error InvalidLtv();
}
