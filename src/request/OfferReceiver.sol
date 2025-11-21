// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";

/// @notice Prime Broker Offer structure for lending assets to the protocol.
/// @dev Offers are signed using EIP-712 (for EOAs) or EIP-1271 (for smart contracts).
///      All offers must have nonces starting at 1 or higher (nonce 0 is invalid).
/// @param maker The address of the prime broker providing the funds
/// @param amount The principal amount to lend (in asset terms)
/// @param expectedReturn The absolute return expected (principal + expectedReturn will be repaid)
/// @param nonce Sequential number for offer management and cancellation (must be > stored nonce)
/// @param expiration Unix timestamp after which the offer becomes invalid
struct Offer {
  address maker;
  uint256 amount;
  uint256 expectedReturn;
  uint256 nonce;
  uint256 expiration;
}

/// @title OfferReceiver
/// @notice Abstract contract for validating and consuming cryptographically signed prime broker offers.
/// @dev Implements EIP-712 typed data hashing and signature verification (EIP-712/EIP-1271).
///      Manages nonces to prevent replay attacks and enable offer cancellation. Contracts inheriting
///      from this can validate offers before pulling funds from prime brokers.
abstract contract OfferReceiver is EIP712 {
  using SignatureCheckerLib for address;

  /// @notice Error thrown when an offer has invalid parameters (zero maker, amount, or expectedReturn).
  /// @dev Validates that the offer contains valid non-zero values for critical fields.
  error InvalidOffer();

  /// @notice Error thrown when the offer signature verification fails.
  /// @dev Signature is verified using EIP-712 for EOAs or EIP-1271 for smart contracts.
  error InvalidSignature();

  /// @notice Error thrown when an offer's expiration timestamp has passed.
  /// @dev Compares offer.expiration with block.timestamp.
  error OfferExpired();

  /// @notice Error thrown when an offer's nonce is not greater than the stored nonce.
  /// @dev Prevents replay attacks and validates offer freshness. Nonces must be monotonically increasing.
  error InvalidNonce();

  /// @notice Error thrown when attempting to set a nonce that is not greater than the current nonce.
  /// @dev Nonce updates must always increase the value to properly invalidate old offers.
  error InvalidNonceUpdate();

  /// @notice EIP-712 typehash for the Offer struct.
  /// @dev Precomputed keccak256 of the Offer type string for gas efficiency.
  ///      Type string: "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration)"
  uint256 internal constant _OFFER_TYPEHASH = 0x03babd1fc4fa7801a5697c2a66bd17ee1499bad98dbcb9901bdae479682e3229;

  /// @notice Seed used to derive nonce storage slots for each maker.
  /// @dev The nonce slot for a `maker` is computed using keccak256:
  /// ```
  ///     mstore(0x0c, _NONCE_SEED)
  ///     mstore(0x00, maker)
  ///     let nonceSlot := keccak256(0x0c, 0x20)
  /// ```
  ///      Each maker has an independent nonce stored at their derived slot.
  uint256 private constant _NONCE_SEED = 0xaffed0e0;

  /// @notice Returns the current nonce for a given maker address.
  /// @dev Nonces start at 0 by default. Offers must use nonces > stored value (starting at 1).
  ///      The storage slot is computed using keccak256 with the nonce seed for gas-efficient lookups.
  /// @param owner The maker address to query the nonce for
  /// @return result The current nonce value stored for the maker
  function nonce(address owner) public view returns (uint256 result) {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x0c, _NONCE_SEED)
      mstore(0x00, owner)
      let nonceSlot := keccak256(0x0c, 0x20)
      result := sload(nonceSlot)
    }
  }

  /// @notice Allows a maker to manually update their nonce to cancel offers (hard cancel).
  /// @dev The new nonce must be strictly greater than the current nonce. All offers with
  ///      nonce <= newNonce become invalid. This is useful for bulk cancellation of offers.
  ///      For example, if a maker has offers with nonces 1-5 and calls setNonce(3),
  ///      offers 1, 2, and 3 are invalidated, and new offers must use nonce >= 4.
  /// @param newNonce The new nonce value to set (must be > current nonce)
  /// @custom:reverts InvalidNonceUpdate if newNonce <= current nonce
  function setNonce(uint256 newNonce) external {
    uint256 currentNonce = nonce(msg.sender);
    if (currentNonce >= newNonce) revert InvalidNonceUpdate();
    _setNonce(msg.sender, newNonce);
  }

  /// @notice Internal function to update a maker's nonce.
  /// @dev Computes the storage slot using keccak256 and writes the new nonce value.
  ///      No validation is performed; the caller must ensure the nonce update is valid.
  /// @param owner The maker address whose nonce to update
  /// @param newNonce The new nonce value to store
  function _setNonce(address owner, uint256 newNonce) internal {
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x0c, _NONCE_SEED)
      mstore(0x00, owner)
      let nonceSlot := keccak256(0x0c, 0x20)
      sstore(nonceSlot, newNonce)
    }
  }

  /// @notice Validates an offer and its signature, then consumes the nonce.
  /// @dev Performs comprehensive validation in the following order:
  ///      1. Checks offer parameters are non-zero (maker, amount, expectedReturn)
  ///      2. Validates expiration timestamp has not passed
  ///      3. Ensures offer nonce is greater than stored nonce (freshness check)
  ///      4. Verifies signature using EIP-712 (EOA) or EIP-1271 (smart contract)
  ///      5. Updates the stored nonce to the offer's nonce (preventing replay)
  ///      
  ///      Note: This function does NOT pull funds from the maker. That logic must be
  ///      implemented separately by contracts inheriting from OfferReceiver.
  /// @param offer The offer struct containing all offer parameters
  /// @param signature The cryptographic signature (EIP-712 or EIP-1271)
  /// @custom:reverts InvalidOffer if maker is zero or amounts are zero
  /// @custom:reverts OfferExpired if block.timestamp >= offer.expiration
  /// @custom:reverts InvalidNonce if offer.nonce <= stored nonce for maker
  /// @custom:reverts InvalidSignature if signature verification fails
  function _validateOffer(Offer calldata offer, bytes calldata signature) internal {
    // Validate offer parameters are non-zero
    if (offer.maker == address(0) || offer.amount == 0 || offer.expectedReturn == 0) revert InvalidOffer();
    
    // Check offer has not expired
    if (offer.expiration < block.timestamp) revert OfferExpired();
    
    // Ensure offer nonce is fresh (greater than stored nonce)
    // This prevents replay attacks and validates offer hasn't been cancelled
    if (nonce(offer.maker) >= offer.nonce) revert InvalidNonce();

    // Compute EIP-712 typed data hash for signature verification
    bytes32 digest = _hashTypedData(keccak256(abi.encode(_OFFER_TYPEHASH, offer)));
    
    // Verify signature using EIP-712 (EOA) or EIP-1271 (smart contract)
    if (!offer.maker.isValidSignatureNowCalldata(digest, signature)) revert InvalidSignature();

    // Update stored nonce to prevent replay of this offer
    _setNonce(offer.maker, offer.nonce);
  }
}
