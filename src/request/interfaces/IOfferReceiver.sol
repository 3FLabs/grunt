// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IOfferReceiver
/// @notice Interface for validating and consuming cryptographically signed prime broker offers.
interface IOfferReceiver {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a maker's nonce is updated.
  /// @param maker The address whose nonce was updated
  /// @param newNonce The new nonce value
  event NonceUpdated(address indexed maker, uint256 newNonce);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      NONCE MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the current nonce for a given maker address.
  /// @param owner The maker address to query the nonce for
  /// @return result The current nonce value stored for the maker
  function nonce(address owner) external view returns (uint256 result);

  /// @notice Allows a maker to manually update their nonce to cancel offers (hard cancel).
  /// @param newNonce The new nonce value to set (must be > current nonce)
  function setNonce(uint256 newNonce) external;
}

