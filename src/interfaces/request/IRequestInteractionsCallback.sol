// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IRequestInteractionsCallback
/// @author 3F Protocol
/// @notice Interface for contracts that want to receive callbacks when funds are being pulled.
interface IRequestInteractionsCallback {
  /// @notice Called when the request contract pulls funds with non-null data.
  /// @param amount The amount of underlying assets to transfer
  /// @param data Additional data to be passed to the callback
  function onPullFunds(uint256 amount, bytes calldata data) external;
}
