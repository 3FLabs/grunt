// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

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
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// TODO => Parameters
  /// @dev We have only one order per intent.
  function create(uint256 id, uint256 amount, uint256 minAmountOut) external returns (uint256 orderId);

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
