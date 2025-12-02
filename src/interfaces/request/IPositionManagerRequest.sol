// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IPositionManagerRequest
/// @notice Interface for the PositionManagerRequest contract that pulls funds from the contract.
interface IPositionManagerRequest {
  /// @notice Transfers underlying assets from the contract to the puller.
  /// @dev This function is used after offers are consumed to transfer the collected funds
  ///      to the borrower. The borrower then repays by transferring assets back to the
  ///      contract before `setRepaid()` is called to enable PT/YT holder withdrawals.
  /// @dev This function should trigger a callback to the puller if data is provided.
  ///      This should only be called by the puller role.
  /// @param amount The amount of underlying assets to transfer
  /// @param data Additional data to be passed to the puller callback
  function pullFunds(uint256 amount, bytes calldata data) external;

  /// @notice Repays the request by transferring the underlying assets back to the contract.
  /// @dev This function is used to repay the request by transferring the underlying assets back to the contract.
  ///      It assumes caller has enough allowance to transfer the underlying assets back to the contract.
  ///      Depending on the request contract implementation, this is optional and may be done via a simple transfer.
  /// @param amount The amount of underlying assets to transfer
  function repay(uint256 amount) external;
}
