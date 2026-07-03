// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibRetargetterErrors
/// @author 3F Protocol
/// @notice Error definitions for the Retargetter contracts.
library LibRetargetterErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     OPERATION LIFECYCLE                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when starting an operation while another one is active or a
  ///         flash-loan window is open, and when nesting flash loans in the adapter.
  error OperationActive();

  /// @notice Thrown when a step requires an active operation or an open flash-loan window.
  error NoActiveOperation();

  /// @notice Thrown at resolve when the operation's Request has not been repaid.
  error RequestNotRepaid();

  /// @notice Thrown when a bound asset balance is at or above the configured residual
  ///         tolerance at settlement.
  /// @param token The bound asset above tolerance
  /// @param balance The residual balance
  error ResidualBalance(address token, uint256 balance);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         GUARDRAILS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a position manager's assets do not match the bound pair,
  ///         when a fund's tokens do not match it, or when the pair is not distinct.
  error AssetMismatch();

  /// @notice Thrown when binding a fund that is not owner-whitelisted.
  error FundNotWhitelisted();

  /// @notice Thrown when using a flash-loan module that is not owner-whitelisted.
  error ModuleNotWhitelisted();

  /// @notice Thrown when a principal or flash-loan amount exceeds the quoter-computed cap.
  error PrincipalCapExceeded();

  /// @notice Thrown when an offer's yield ratio exceeds the operation's yield cap.
  error YieldTooHigh();

  /// @notice Thrown when consuming an offer or setting a nonzero mint authorization after the
  ///         consumption window has closed (the tick threshold elapsed since the loan clock
  ///         origin, or funds were already pulled).
  error ConsumptionWindowClosed();

  /// @notice Thrown when computing a principal cap on a position with no collateral and no debt.
  error EmptyPosition();

  /// @notice Thrown when a position holds debt against zero quoted collateral.
  /// @param position The bad-debt position (a borrow module or the position manager itself)
  error BadDebtPosition(address position);

  /// @notice Thrown when a rebalance leaves the aggregate LTV above target without improving it.
  /// @param ltvAfter The aggregate LTV after the rebalance (WAD)
  /// @param ltvBefore The aggregate LTV before the rebalance (WAD)
  /// @param target The position manager's target LTV (WAD)
  error AboveTargetLtv(uint256 ltvAfter, uint256 ltvBefore, uint256 target);

  /// @notice Thrown when a rebalance leaves a single position above target without improving it.
  /// @param position The offending borrow module
  error PositionAboveTarget(address position);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ORDERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a stored fund order already exists.
  error OrderActive();

  /// @notice Thrown when a step requires a stored fund order and none exists.
  error NoOrder();

  /// @notice Thrown when a created order's owner or receiver is not the Retargetter.
  error InvalidOrder();

  /// @notice Thrown at settlement while the stored fund order has not reached a final state.
  error OrderPending();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        REBALANCING                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the full-balance sentinel is used on an output leg (BORROW or WITHDRAW).
  error InvalidSentinel();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FLASH LOANS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when onFlashLoan is not called by the expected module with the expected amount.
  error UnauthorizedFlashLoanCallback();

  /// @notice Thrown when the adapter's provider callback is not called by the provider,
  ///         or no flash loan is in flight.
  error UnauthorizedCaller();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         REENTRANCY                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a guarded function is reentered. The signature matches Solady's
  ///         ReentrancyGuardTransient error, so the selector stays the one tooling knows.
  error Reentrancy();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a configuration value is out of bounds or a math input is degenerate.
  error InvalidParameters();
}
