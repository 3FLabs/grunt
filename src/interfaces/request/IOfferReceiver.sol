// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Prime Broker Offer structure for lending assets to the protocol.
/// @dev Offers are signed using EIP-712 (for EOAs) or EIP-1271 (for smart contracts).
///      All offers must have nonces starting at 1 or higher (nonce 0 is invalid).
/// @param maker The address of the prime broker providing the funds
/// @param amount The principal amount to lend (in asset terms)
/// @param expectedReturn The absolute return expected (principal + expectedReturn will be repaid)
/// @param nonce Sequential number for offer management and cancellation (must be > stored nonce)
/// @param expiration Unix timestamp after which the offer becomes invalid
/// @param useCallback Whether to call the maker's onRequestConsumed callback before pulling funds
struct Offer {
  address maker;
  uint256 amount;
  uint256 expectedReturn;
  uint256 nonce;
  uint256 expiration;
  bool useCallback;
}

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

  /// @notice Allows a maker to manually update their nonce to cancel pending offers.
  /// @dev This function enables bulk cancellation of offers. When you set a new nonce N,
  ///      ALL offers with nonce <= N become permanently invalid. Offers are only valid
  ///      if their nonce is strictly greater than the stored nonce.
  ///
  ///      **Cancellation Examples:**
  ///      - If stored nonce is 0 and you have pending offers with nonces 1, 2, 3:
  ///        - `setNonce(1)` invalidates only offer 1 (offers 2, 3 remain valid)
  ///        - `setNonce(3)` invalidates offers 1, 2, AND 3
  ///        - `setNonce(100)` invalidates all offers up to nonce 100
  ///
  ///      **Important:** To cancel ALL pending offers, set the nonce to a value >= the highest
  ///      nonce among your pending offers. Future offers must use nonces > the new stored nonce.
  ///
  /// @param newNonce The new nonce value to set (must be strictly > current nonce)
  function setNonce(uint256 newNonce) external;
}

