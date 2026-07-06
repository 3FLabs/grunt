// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasVault, MidasRequestStatus} from "./IMidasVault.sol";

/// @title IMidasRedemptionVault
/// @author 3F Protocol
/// @notice Interface of the Midas RedemptionVault and its variants (WithAave, WithSwapper, WithBUIDL).
/// @dev All variants share the same external API; they only differ in how instant redemptions
///      source liquidity. All amounts are base-18, regardless of `tokenOut` native decimals.
interface IMidasRedemptionVault is IMidasVault {
  /// @notice Burns mToken from the caller and pays out `tokenOut` in the same transaction.
  /// @param tokenOut The payment token to receive.
  /// @param amountMTokenIn The base-18 mToken amount to redeem (fee inclusive).
  /// @param minReceiveAmount The minimum base-18 `tokenOut` amount to receive (slippage guard).
  function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;

  /// @notice Same as `redeemInstant` but pays `tokenOut` to `recipient`.
  function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount, address recipient) external;

  /// @notice Escrows mToken now and requests a redemption, settled later by a vault admin.
  /// @dev `tokenOut` is pushed directly to the requester when the admin approves the request.
  ///      A rejected request is NOT refunded on-chain (the mToken stays escrowed in the vault).
  /// @param tokenOut The payment token to receive.
  /// @param amountMTokenIn The base-18 mToken amount to redeem (fee inclusive).
  /// @return requestId The id of the created redemption request.
  function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256 requestId);

  /// @notice Same as `redeemRequest` but `tokenOut` is paid to `recipient` on approval.
  function redeemRequest(address tokenOut, uint256 amountMTokenIn, address recipient)
    external
    returns (uint256 requestId);

  /// @notice Requests a fiat (off-chain) redemption.
  function redeemFiatRequest(uint256 amountMTokenIn) external returns (uint256 requestId);

  /// @notice Returns the redemption request stored for `requestId`.
  /// @return sender The `tokenOut` recipient of the request.
  /// @return tokenOut The payment token to be received.
  /// @return status The request status (PENDING, PROCESSED or CANCELED).
  /// @return amountMToken The base-18 mToken amount escrowed (net of fees).
  /// @return mTokenRate The base-18 mToken/USD rate snapshotted at request time.
  /// @return tokenOutRate The base-18 tokenOut/USD rate snapshotted at request time.
  function redeemRequests(uint256 requestId)
    external
    view
    returns (
      address sender,
      address tokenOut,
      MidasRequestStatus status,
      uint256 amountMToken,
      uint256 mTokenRate,
      uint256 tokenOutRate
    );
}
