// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title LibErrors
/// @author 3F Protocol
/// @notice Error definitions for the Request contracts.
library LibErrors {
  /// @notice Thrown when the request has already been repaid, preventing further calls to `setRepaid()`, `pullFunds()`, and `repay()`.
  error AlreadyRepaid();

  /// @notice Thrown when the offer signature verification fails.
  error InvalidSignature();

  /// @notice Thrown when an offer's expiration timestamp has passed.
  error OfferExpired();

  /// @notice Thrown when an offer's nonce is not greater than the stored nonce.
  error InvalidNonce();

  /// @notice Thrown when attempting to set a nonce that is not greater than the current nonce.
  error InvalidNonceUpdate();

  /// @notice Thrown when the caller is not authorized as a token contract.
  error UnauthorizedTokenContract();

  /// @notice Thrown when the spender has insufficient allowance for a transferFrom operation.
  error InsufficientAllowance();

  /// @notice Thrown when attempting to transfer tokens to the same address.
  error TransferToSelf();

  /// @notice Thrown when attempting to withdraw or redeem while withdrawals are locked.
  error CannotWithdraw();

  /// @notice Thrown when attempting to directly mint shares via deposit() or mint().
  error CannotMintShares();

  /// @notice Thrown when the caller is not the authorized controller.
  error Unauthorized();
}
