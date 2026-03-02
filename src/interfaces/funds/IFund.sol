// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Order, State} from "../../libs/funds/Order.sol";

/// @title IFund
/// @author 3F Protocol
/// @notice Interface for on-chain fund wrappers managing asset deposits and redemptions.
/// @dev Implements a state machine for order lifecycle management:
///
///      State Machine:
///      ┌────────────────────────────────────────────────────────────────────────────┐
///      │                                                                            │
///      │    ┌───────cancel()────────┐                                               │
///      │    │                       │                                               │
///      │    │                       │                                               │
///      │    │               ┌──> ACCEPTED ──commit()──> PROCESSING────────┐         │
///      │    ▼               │       ▲                        │            │         │
///      │  EMPTY ──create()──┤       │                        │            │         │
///      │    ▲               │       │                        ▼            ▼         │
///      │    │               └──> PENDING                 UNLOCKING    RECOVERING    │
///      │    │                       │                        │            │         │
///      │    │                       │                        │            │         │
///      │    └────────cancel()───────┘                     unlock()     recover()    │
///      │                                                     │            │         │
///      │                                                     │            │         │
///      │                                                     └──────┐─────┘         │
///      │                                                            │               │
///      │                                                            ▼               │
///      │                                                          ENDED             │
///      └────────────────────────────────────────────────────────────────────────────┘
///
///      Order Modes:
///      - DEPOSIT: asset → share (commit assets, unlock shares)
///      - REDEEM:  share → asset (commit shares, unlock assets)
///
///      Comments:
///      - create() returns ACCEPTED (ready for commit) or PENDING (e.g. queued/rate-limited/KYC)
///      - PENDING orders transition to ACCEPTED when ready
///      - ACCEPTED and PENDING orders can be canceled back to EMPTY via cancel()
///      - ACCEPTED orders go to PROCESSING via commit()
///      - PROCESSING splits to UNLOCKING (success) or RECOVERING (failure)
///      - Partial unlock/recover: After claiming partial funds, state goes back to PROCESSING
///        until remaining assets/shares become available for another unlock/recover cycle
///      - create() and commit() NEVER reach ENDED - they advance the order forward (or revert)
///      - Only unlock() and recover() finalize orders by reaching ENDED
///      - Callers can batch state transitions when possible (e.g., create + commit if ACCEPTED)
interface IFund {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Create an Order to commit or withdraw.
  /// @dev Only callable when state() returns EMPTY.
  /// @param order The order parameters defining the operation.
  /// @return The new state of the order after creation (ACCEPTED or PENDING).
  function create(Order calldata order) external returns (State);

  /// @notice Cancels an uncommitted order.
  /// @dev Only callable when state() returns ACCEPTED or PENDING.
  /// @param order The order parameters identifying the operation.
  /// @return The new state of the order after cancellation (EMPTY).
  function cancel(Order calldata order) external returns (State);

  /// @notice Transfers assets from the sender to the wrapper for an accepted order.
  /// @dev Only callable when state() returns ACCEPTED.
  /// @param order The order parameters identifying the operation.
  /// @return The new state after the transfer (PROCESSING or UNLOCKING).
  /// @return The assets that have been committed by the owner.
  function commit(Order calldata order) external returns (State, uint256);

  /// @notice Recovers input assets after failed processing.
  /// @dev Only callable when state() returns RECOVERING.
  /// @param order The order parameters identifying the operation.
  /// @return The new state after recovery (going back to PROCESSING if partial, ENDED if full).
  /// @return The assets that have been recovered by the receiver.
  function recover(Order calldata order) external returns (State, uint256);

  /// @notice Claims output assets or shares after successful processing.
  /// @dev Only callable when state() returns UNLOCKING.
  ///      DEPOSIT: transfers shares to order.receiver
  ///      REDEEM: transfers output assets to order.receiver
  /// @param order The order parameters identifying the completed operation.
  /// @return The new state after unlocking (going back to PROCESSING if partial, ENDED if full).
  /// @return The assets that have been unlocked to the receiver.
  function unlock(Order calldata order) external returns (State, uint256);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Gets the current state of a specified order.
  /// @dev Returns EMPTY for orders that don't exist.
  /// @param order The order parameters identifying the operation.
  /// @return The current state of the order in the lifecycle.
  function state(Order calldata order) external view returns (State);

  /// @notice Returns the ERC20 asset in which the wrapper is denominated.
  /// @dev This is the base asset used for accounting and valuation.
  /// @return The address of the main base asset.
  function asset() external view returns (address);

  /// @notice Returns the share token of the fund.
  /// @dev Could be address(this) or a separate ERC20 representing shares.
  /// @return The address of the share token.
  function share() external view returns (address);

  /// @notice Returns the total amount of the wrapper's base asset under management.
  /// @return The total amount of assets denominated in the asset() token.
  function totalAssets() external view returns (uint256);

  /// @notice Returns the maximum deposit amount for an account.
  /// @param account The address for which deposit limits are being calculated.
  /// @return The maximum amount that can be deposited by the account.
  function maxDeposit(address account) external view returns (uint256);

  /// @notice Returns the maximum redeemable shares for an account.
  /// @param account The address for which redemption limits are being calculated.
  /// @return The maximum amount that can be redeemed by the account.
  function maxRedeem(address account) external view returns (uint256);
}
