// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {EIP712} from "lib/solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "lib/solady/src/utils/SignatureCheckerLib.sol";
import {IOfferReceiver, Offer} from "../../interfaces/request/IOfferReceiver.sol";
import {LibRequestErrors} from "../../libs/request/LibRequestErrors.sol";
import {LibChecks} from "../../libs/common/LibChecks.sol";

/// @title OfferReceiver
/// @author 3F Protocol
/// @notice Abstract contract for validating and consuming cryptographically signed bridge facilitator offers.
/// @dev Implements EIP-712 typed data hashing and signature verification (EIP-712/EIP-1271).
///      Security model: nonces are strictly increasing (offer.nonce > stored nonce), the nonce is
///      updated before signature verification to prevent reentrancy replays, and expiration
///      timestamps time-bound offer validity.
abstract contract OfferReceiver is EIP712, IOfferReceiver {
  using SignatureCheckerLib for address;
  using LibChecks for address;
  using LibChecks for uint256;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice EIP-712 typehash for the Offer struct.
  /// @dev Precomputed keccak256 of the Offer type string for gas efficiency.
  ///      Type string: "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)"
  uint256 internal constant _OFFER_TYPEHASH = 0x3ded0c963332962cf2d273c8fb4f3e69f4ef33407ca72484fcebb56263ad0664;

  /// @dev Seed used to derive nonce storage slots for each maker.
  ///      The nonce slot for a `maker` is computed using keccak256:
  /// ```
  ///     mstore(0x0c, _NONCE_SEED)
  ///     mstore(0x00, maker)
  ///     let nonceSlot := keccak256(0x0c, 0x20)
  /// ```
  uint256 private constant _NONCE_SEED = 0xaffed0e0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      NONCE MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IOfferReceiver
  /// @dev Nonces start at 0 by default. Offers must use nonces > stored value (starting at 1).
  ///      The storage slot is computed using keccak256 with the nonce seed for gas-efficient lookups.
  function nonce(address owner) public view returns (uint256 result) {
    assembly ("memory-safe") {
      mstore(0x0c, _NONCE_SEED)
      mstore(0x00, owner)
      result := sload(keccak256(0x0c, 0x20))
    }
  }

  /// @inheritdoc IOfferReceiver
  /// @dev The new nonce must be strictly greater than the current nonce. All offers with
  ///      nonce <= newNonce become permanently invalid; pass the highest pending offer nonce
  ///      (or higher) to bulk-cancel. See docs/request.md#funding.
  /// @custom:reverts InvalidNonceUpdate if newNonce <= current nonce
  function setNonce(uint256 newNonce) external {
    uint256 currentNonce = nonce(msg.sender);
    if (currentNonce >= newNonce) revert LibRequestErrors.InvalidNonceUpdate();
    _setNonce(msg.sender, newNonce);
  }

  /// @dev Computes the storage slot using keccak256 and writes the new nonce value.
  ///      Emits a {NonceUpdated} event after updating storage.
  ///      No validation is performed; the caller must ensure the nonce update is valid.
  /// @param owner The maker address whose nonce to update
  /// @param newNonce The new nonce value to store
  function _setNonce(address owner, uint256 newNonce) internal {
    assembly ("memory-safe") {
      mstore(0x0c, _NONCE_SEED)
      mstore(0x00, owner)
      sstore(keccak256(0x0c, 0x20), newNonce)
    }
    emit NonceUpdated(owner, newNonce);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OFFER VALIDATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Validates an offer and its signature, then consumes the nonce.
  ///      The stored nonce is updated BEFORE signature verification to prevent reentrancy replays;
  ///      this is safe because an invalid signature reverts the whole transaction.
  ///      Does NOT pull funds from the maker; inheriting contracts implement that separately.
  /// @custom:reverts AddressZero if maker is zero address
  /// @custom:reverts AmountZero if amount or expectedReturn is zero
  /// @custom:reverts OfferExpired if block.timestamp > offer.expiration
  /// @custom:reverts InvalidNonce if offer.nonce <= stored nonce for maker
  /// @custom:reverts InvalidSignature if signature verification fails
  function _validateOffer(Offer calldata offer, bytes calldata signature) internal {
    offer.maker.checkNotZero();
    offer.amount.checkNotZero();
    offer.expectedReturn.checkNotZero();

    if (offer.expiration < block.timestamp) revert LibRequestErrors.OfferExpired();

    if (nonce(offer.maker) >= offer.nonce) revert LibRequestErrors.InvalidNonce();

    // Update stored nonce BEFORE signature verification to prevent reentrancy replays
    _setNonce(offer.maker, offer.nonce);

    bytes32 digest = _hashTypedData(keccak256(abi.encode(_OFFER_TYPEHASH, offer)));
    if (!offer.maker.isValidSignatureNowCalldata(digest, signature)) revert LibRequestErrors.InvalidSignature();
  }
}
