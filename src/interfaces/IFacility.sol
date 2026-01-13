// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EnumerableMapLib} from "lib/solady/src/utils/EnumerableMapLib.sol";

import {Order, Mode} from "../libs/Order.sol";

struct Intent {
  address fund;
  address positionManager;
  address request;
  uint256 depositCap;
  uint40 resolveStart;
  bool resolved;
  EnumerableMapLib.AddressToUint256Map amounts;
  Order order;
}

interface IFacility {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     INTENT MANAGEMENT                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// TODO => Parameters
  function createIntent() external returns (uint256 id);

  /// @notice Closes the intent with the given ID, stopping withdrawals.
  /// @param id The ID of the intent to close.
  function lock(uint256 id) external;

  /// @notice Resolves the intent with the given ID, opening claims to users.
  /// @param id The ID of the intent to resolve.
  function resolve(uint256 id) external;

  /// @notice Sets a new deposit cap for a given intent ID.
  /// @param id The ID of the intent to update.
  /// @param newDepositCap The new deposit cap to set.
  function setDepositCap(uint256 id, uint256 newDepositCap) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// TODO => Parameters
  /// @dev We have only one order per intent.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode) external returns (Order memory order);

  /// @notice Cancels the given intent underlying order.

  /// @param id The ID of the intent whose order to cancel.
  function cancel(uint256 id) external;

  /// @notice Commits the given intent underlying order.
  /// @param id The ID of the intent whose order to commit.
  function commit(uint256 id) external;

  /// @notice Unlock the given intent underlying order.
  /// @param id The ID of the intent whose order to unlock.
  function unlock(uint256 id) external;

  /// @notice Recover the given intent underlying order.
  /// @param id The ID of the intent whose order to recover.
  function recover(uint256 id) external;

  /// TODO => Parameters
  function swap(uint256 id1, address token1, uint256 id2, address token2, uint256 amount1, uint256 amount2) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     REQUEST OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pull funds from the given intent Request.
  /// @param id The ID of the intent to pull from.
  /// @param amount The amount to pull (can be partial).
  function pull(uint256 id, uint256 amount) external;

  /// @notice Repay funds to the given intent Request.
  /// @param id The ID of the intent to repay to.
  /// @param amount The amount to repay (can be partial).
  function repay(uint256 id, uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 POSITION MANAGER OPERATIONS                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits and/or borrows funds for the position manager of the given intent.
  /// @param id The ID of the intent.
  /// @param depositAmount The amount to deposit.
  /// @param borrowAmount The amount to borrow.
  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount) external;

  /// @notice Withdraws and/or repays funds for the position manager of the given intent.
  /// @param id The ID of the intent.
  /// @param withdrawAmount The amount to withdraw.
  /// @param repayAmount The amount to repay.
  function withdrawManager(uint256 id, uint256 withdrawAmount, uint256 repayAmount) external;

  /// @notice Burns shares by repaying debt and withdrawing collateral proportionally for the
  ///         position manager of the given intent.
  /// @param id The ID of the intent.
  /// @param amount The amount of shares to burn.
  function burnManager(uint256 id, uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits a specified amount into the intent with the given ID.
  /// @param id The ID of the intent to deposit into.
  /// @param amount The amount to deposit.
  function deposit(uint256 id, uint256 amount) external;

  /// @notice Withdraws a specified amount from the intent with the given ID.
  /// @dev Withdrawals not allowed if the intent is locked.
  /// @param id The ID of the intent to withdraw from.
  /// @param amount The amount to withdraw.
  function withdraw(uint256 id, uint256 amount) external;

  /// @notice Claims funds from the resolved intent with the given ID.
  /// @param id The ID of the intent to claim from.
  function claim(uint256 id) external;
}
