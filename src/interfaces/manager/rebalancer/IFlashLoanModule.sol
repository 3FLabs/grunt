// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IFlashLoanModule
/// @author 3F Protocol
/// @notice Common flash-loan interface implemented by per-provider adapters.
/// @dev Flash-loan providers expose incompatible ABIs, so the Retargetter only talks to
///      owner-whitelisted modules implementing this interface. Each module adapts one
///      provider (for example Morpho Blue) and calls the borrower back on the
///      provider-agnostic {IFlashLoanReceiver.onFlashLoan}.
interface IFlashLoanModule {
  /// @notice Lends `amount` of `token` to `msg.sender` for the duration of the call.
  /// @dev Transfers the funds to the caller, invokes
  ///      `IFlashLoanReceiver(msg.sender).onFlashLoan(amount, data)`, then pulls `amount`
  ///      back from the caller via allowance. Reverts if repayment fails.
  /// @param token The token to lend
  /// @param amount The amount of tokens to lend
  /// @param data Opaque payload forwarded verbatim to the receiver callback
  function flashLoan(address token, uint256 amount, bytes calldata data) external;
}

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
