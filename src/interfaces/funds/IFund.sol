// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

import {Order, State} from "../../libs/Order.sol";

/// @notice Interface for on-chain fund wrappers managing asset deposits and redemptions.
interface IFund {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Create an Order to commit or withdraw.
  /// @param order The order parameters defining the operation.
  /// @return The new state of the order after creation (ACCEPTED or PENDING).
  function create(Order calldata order) external returns (State);

  /// @notice Transfers assets from the sender to the wrapper for an accepted order.
  /// @param order The order parameters identifying the operation.
  /// @return The new state after the transfer (PROCESSING or UNLOCKING).
  /// @return The assets that have been committed by the owner.
  function commit(Order calldata order) external returns (State, uint256);

  /// @notice Recovers input assets after a failed or partial processing.
  /// @param order The order parameters identifying the operation.
  /// @return The new state after recovery (staying in RECOVERING if partial, ENDED if full).
  /// @return The assets that have been recovered by the receiver.
  function recover(Order calldata order) external returns (State, uint256);

  /// @notice Claims output assets or shares after successful processing.
  /// @dev For DEPOSIT operations, transfers shares from the wrapper to order.receiver.
  ///      For REDEEM operations, transfers output assets from the wrapper to order.receiver.
  ///      Only callable when the order is in UNLOCKING state.
  /// @param order The order parameters identifying the completed operation.
  /// @return The new state after unlocking (staying in UNLOCKING if partial, ENDED if full).
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

  /// @notice Estimates the output assets for an order.
  /// @dev The estimation is not guaranteed and may differ from actual results.
  /// @dev The method ignores the possible current state of the order.
  /// @param order The order parameters defining the operation
  /// @return The estimated output for the order.
  function estimate(Order calldata order) external view returns (uint256);

  /// @notice Returns the ERC20 asset in which the wrapper is denominated.
  /// @dev This is the base asset used for accounting and valuation.
  /// @return The address of the main base asset.
  function asset() external view returns (address);

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
