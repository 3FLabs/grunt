// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title LibErrors
/// @author 3F Protocol
/// @notice Error definitions for the Manager contracts.
library LibErrors {
  /// @notice Thrown when the supply queue runs out of capacity during a deposit.
  error InsufficientBorrowCapacity();

  /// @notice Thrown when attempting to deposit collateral but the supply queue is empty.
  error EmptySupplyQueue();

  /// @notice Thrown when attempting to withdraw more collateral than is available.
  error InsufficientAvailableCollateral();

  /// @notice Thrown when a zero amount is passed where non-zero is required.
  error ZeroAmount();

  /// @notice Thrown when share calculation results in zero shares.
  error ZeroShares();

  /// @notice Thrown when fee value exceeds the maximum allowed.
  error FeeExceedsMax();

  /// @notice Thrown when a queue contains a position that is not whitelisted.
  error UnauthorizedPosition();

  /// @notice Thrown when attempting to remove a module that is still in a queue.
  error ModuleStillInQueue();

  /// @notice Thrown when rebalance causes total assets to decrease by more than maxRebalanceLoss.
  error RebalanceLossExceedsMax();

  /// @notice Thrown when attempting to repay more debt than exists across all positions.
  error ExcessDebtRepay();

  /// @notice Thrown when attempting to set an invalid LLTV value (zero or greater than WAD).
  error InvalidLltv();

  /// @notice Thrown when a transfer is blocked by the transfer guard.
  error TransferBlocked();

  /// @notice Thrown when an operation is attempted while the contract is paused.
  error Paused();

  /// @notice Thrown when the callback is called by an unauthorized address.
  error UnauthorizedCaller();

  /// @notice Thrown when collateral is provided in rebalancing data (must be zero).
  error CollateralNotAllowed();
}
