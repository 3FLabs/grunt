// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

enum Mode {
  DEPOSIT,
  REDEEM
}

enum State {
  EMPTY,
  ACCEPTED,
  PENDING,
  PROCESSING,
  UNLOCKING,
  RECOVERING,
  ENDED
}

struct Request {
  address owner;
  address receiver;
  uint256 input;
  uint256 output;
  Mode mode;
  bytes32 salt;
}

/// @notice Interface for on-chain fund wrappers managing asset deposits and redemptions.
interface IFund {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         OPERATIONS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Create a Request to commit or withdraw.
  /// @param request The request parameters defining the operation.
  /// @return The new state of the request after creation (ACCEPTED or PENDING).
  function create(Request calldata request) external returns (State);

  /// @notice Transfers assets from the sender to the wrapper for an accepted request.
  /// @param request The request parameters identifying the operation.
  /// @return The new state after the transfer (PROCESSING or UNLOCKING).
  /// @return The assets that have been committed by the owner.
  function commit(Request calldata request) external returns (State, uint256);

  /// @notice Recovers input assets after a failed or partial processing.
  /// @param request The request parameters identifying the operation.
  /// @return The new state after recovery (staying in RECOVERING if partial, ENDED if full).
  /// @return The assets that have been recovered by the receiver.
  function recover(Request calldata request) external returns (State, uint256);

  /// @notice Claims output assets or shares after successful processing.
  /// @dev For DEPOSIT operations, transfers shares from the wrapper to request.receiver.
  ///      For REDEEM operations, transfers output assets from the wrapper to request.receiver.
  ///      Only callable when the request is in UNLOCKING state.
  /// @param request The request parameters identifying the completed operation.
  /// @return The new state after unlocking (staying in UNLOCKING if partial, ENDED if full).
  /// @return The assets that have been unlocked to the receiver.
  function unlock(Request calldata request) external returns (State, uint256);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Gets the current state of a specified request.
  /// @dev Returns EMPTY for requests that don't exist.
  /// @param request The request parameters identifying the operation.
  /// @return The current state of the request in the lifecycle.
  function state(Request calldata request) external view returns (State);

  /// @notice Estimates the output assets for a request.
  /// @dev The estimation is not guaranteed and may differ from actual results.
  /// @dev The method ignores the possible current state of the request.
  /// @param request The request parameters defining the operation
  /// @return The estimated output for the request.
  function estimate(Request calldata request) external view returns (uint256);

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
