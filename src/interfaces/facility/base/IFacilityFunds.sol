// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Order, Mode} from "../../../libs/funds/Order.sol";

/// @title IFacilityFunds
/// @author 3F Protocol
/// @notice Interface for fund operations.
interface IFacilityFunds {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a fund order is being created.
  /// @param id The intent ID.
  /// @param orderId The order ID.
  event CreatingOrder(uint256 indexed id, bytes32 orderId);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the current fund order for an intent, if any.
  /// @param id The intent ID.
  /// @return order The current order for the intent.
  /// @return orderId The order ID.
  function getOrder(uint256 id) external view returns (Order memory order, bytes32 orderId);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Creates a fund order for an intent.
  /// @param id The intent ID.
  /// @param amount The amount to include in the order.
  /// @param minAmountOut The minimum amount expected from the order.
  /// @param mode The order mode to execute.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode) external returns (Order memory order);

  /// @notice Cancels the current fund order for an intent.
  /// @param id The intent ID.
  function cancel(uint256 id) external;

  /// @notice Commits the current fund order for an intent.
  /// @param id The intent ID.
  function commit(uint256 id) external;

  /// @notice Unlocks the current fund order for an intent.
  /// @param id The intent ID.
  function unlock(uint256 id) external;

  /// @notice Recovers assets from the current fund order for an intent.
  /// @param id The intent ID.
  function recover(uint256 id) external;
}
