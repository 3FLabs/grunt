// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IPositionManagerRequestCallback
/// @notice Interface for contracts that want to receive callbacks when their requests are being consumed.
interface IPositionManagerRequestCallback {
  /// @notice Called when the PositionManagerRequest contract pulls funds from the contract with non-null data.
  /// @param amount The amount of underlying assets to transfer
  /// @param data Additional data to be passed to the callback
  function onPullFunds(uint256 amount, bytes calldata data) external;
}
