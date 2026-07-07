// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasVault} from "./IMidasVault.sol";

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
}
