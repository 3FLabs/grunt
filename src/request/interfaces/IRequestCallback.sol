// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Offer} from "../OfferReceiver.sol";

/// @title IRequestCallback
/// @notice Interface for contracts that want to receive callbacks when their requests are being consumed.
/// @dev Implement this interface to receive a *pre-transfer* callback when an offer is about to fulfill a request.
///      At the time this function is called, the principal and yield tokens have NOT yet been pulled;
///      the callback is intended to prepare funds so they can be pulled immediately afterwards, e.g.:
///      - Unwinding or withdrawing from DeFi positions
///      - Moving funds from internal accounting to a hot wallet
///      - Setting ERC20 allowances for the OfferReceiver to pull the required amounts
///      - Emitting events for off-chain tracking
///
///      Security Considerations:
///      - The callback is triggered by the OfferReceiver contract during request consumption
///      - Implementers should validate that msg.sender is the expected OfferReceiver contract
///      - Avoid performing state changes that could be exploited via reentrancy
interface IRequestCallback {
  /// @notice Called when a request is being consumed by an offer, *before* tokens are pulled.
  /// @dev This function is invoked by the OfferReceiver contract during processing of an offer
  ///      that fulfills a request. The callback provides all relevant details and the exact
  ///      amounts that will be pulled immediately after this call if it does not revert.
  ///
  ///      Implementation Notes:
  ///      - This is the right place to prepare funds to be pulled (e.g. withdraw from DeFi, set allowances)
  ///      - This function MUST NOT revert if you want the request consumption to succeed
  ///      - Reverting will cause the entire offer consumption transaction to fail
  ///      - Keep gas usage reasonable to avoid out-of-gas errors
  ///
  /// @param offer The offer struct containing all details of the fulfilled offer
  /// @param signature The EIP-712 signature that authorized the offer
  /// @param principal The amount of principal tokens (PT) that will be pulled after the callback
  /// @param yield The amount of yield tokens (YT) that will be pulled after the callback
  function onRequestConsumed(Offer calldata offer, bytes calldata signature, uint256 principal, uint256 yield) external;
}
