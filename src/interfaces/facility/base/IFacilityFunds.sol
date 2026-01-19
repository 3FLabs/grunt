// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Order, Mode, Id} from "../../../libs/funds/Order.sol";

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
  event CreatingOrder(uint256 indexed id, Id orderId);

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
