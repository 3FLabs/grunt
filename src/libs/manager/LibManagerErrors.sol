// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibManagerErrors
/// @author 3F Protocol
/// @notice Error definitions for the Manager contracts.
library LibManagerErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      SUPPLY QUEUE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the supply queue runs out of capacity during a deposit.
  error InsufficientBorrowCapacity();

  /// @notice Thrown when attempting to deposit collateral but the supply queue is empty.
  error EmptySupplyQueue();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    COLLATERAL & DEBT                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when attempting to withdraw more collateral than is available.
  error InsufficientAvailableCollateral();

  /// @notice Thrown when attempting to repay more debt than exists across all positions.
  error ExcessDebtRepay();

  /// @notice Thrown when collateral is provided in rebalancing data (must be zero).
  error CollateralNotAllowed();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FEES                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when fee value exceeds the maximum allowed.
  error FeeExceedsMax();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    MODULES & POSITIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a queue contains a position that is not whitelisted.
  error UnauthorizedPosition();

  /// @notice Thrown when a queue contains the same position more than once.
  error DuplicateQueueEntry();

  /// @notice Thrown when attempting to remove a module that is still in a queue.
  error ModuleStillInQueue();

  /// @notice Thrown when a borrow module's collateral asset does not match the position manager's.
  error CollateralAssetMismatch();

  /// @notice Thrown when a borrow module's debt (borrow) asset does not match the position manager's.
  error DebtAssetMismatch();

  /// @notice Thrown when a borrow module's owner is not the position manager.
  error InvalidModuleOwner();

  /// @notice Thrown when a borrow module's safe LTV is lower than the position manager's LTV.
  error ModuleSafeLtvTooLow();

  /// @notice Thrown when attempting to add a borrow module that is already whitelisted.
  error ModuleAlreadyAdded();

  /// @notice Thrown when attempting to remove a borrow module that is not whitelisted.
  error ModuleNotFound();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REBALANCING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when rebalance causes total assets to decrease by more than maxRebalanceLoss.
  error RebalanceLossExceedsMax();

  /// @notice Thrown when maxRebalanceLoss exceeds the allowed upper bound.
  error MaxRebalanceLossExceedsMax();

  /// @notice Thrown when rebalance is called before the cooldown period has elapsed.
  error RebalanceCooldownNotElapsed();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TRANSFERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a transfer is blocked by the transfer guard.
  error TransferBlocked();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      AUTHORIZATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the callback is called by an unauthorized address.
  error UnauthorizedCaller();
}
