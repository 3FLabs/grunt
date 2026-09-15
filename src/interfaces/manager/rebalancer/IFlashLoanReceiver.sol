// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFlashLoanReceiver
/// @author 3F Protocol
/// @notice Callback interface a flash-loan module invokes on its borrower.
interface IFlashLoanReceiver {
  /// @notice Called by the flash-loan module after the funds have been transferred to the receiver.
  /// @dev The receiver must approve the module for `amount` of the lent token before returning,
  ///      so the module can pull its repayment.
  /// @param amount The amount of tokens that was lent
  /// @param data The payload passed to {IFlashLoanModule.flashLoan}, forwarded verbatim
  function onFlashLoan(uint256 amount, bytes calldata data) external;
}
