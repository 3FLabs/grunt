// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC4626} from "../IERC4626.sol";

/// @title ISUSD3
/// @author 3F Protocol
/// @notice Minimal interface for the sUSD3 (staked USD3) subordinate tranche strategy.
/// @dev sUSD3 is a Yearn V3 TokenizedStrategy (ERC4626-compatible) whose asset is USD3.
///      Beyond the standard ERC4626 surface it gates withdrawals behind a cooldown: a holder must
///      `startCooldown(shares)`, wait `cooldownDuration()`, then redeem within the withdrawal window.
///      `maxRedeem`/`availableWithdrawLimit` return 0 until the cooldown matures and while the
///      withdrawal is otherwise blocked (unrealized losses / backing floor).
interface ISUSD3 is IERC4626 {
  /// @notice Starts a withdrawal cooldown for `shares`. Overwrites any previous cooldown.
  /// @param shares The number of sUSD3 shares to place into cooldown.
  function startCooldown(uint256 shares) external;

  /// @notice Cancels the caller's active cooldown, deleting its record.
  function cancelCooldown() external;

  /// @notice Returns the cooldown state for `user`.
  /// @param user The address to query.
  /// @return cooldownEnd Timestamp when the cooldown matures (0 if none).
  /// @return windowEnd Timestamp when the withdrawal window closes.
  /// @return shares Shares currently locked for withdrawal.
  function getCooldownStatus(address user)
    external
    view
    returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);

  /// @notice Raw cooldown record for `user` (packed struct getter).
  /// @param user The address to query.
  /// @return cooldownEnd Timestamp when the cooldown matures.
  /// @return windowEnd Timestamp when the withdrawal window closes.
  /// @return shares Shares currently locked for withdrawal.
  function cooldowns(address user) external view returns (uint64 cooldownEnd, uint64 windowEnd, uint128 shares);

  /// @notice Lock duration applied to new deposits (0 = deposited shares are immediately transferable).
  function lockDuration() external view returns (uint256);

  /// @notice Timestamp until which `account`'s deposited shares are locked from transfer (0 if none).
  /// @dev Set per-account at deposit time to `block.timestamp + lockDuration()`; not affected by later
  ///      changes to `lockDuration()`.
  /// @param account The address to query.
  function lockedUntil(address account) external view returns (uint256);

  /// @notice Cooldown duration required before a withdrawal can be claimed.
  function cooldownDuration() external view returns (uint256);

  /// @notice Maximum assets (USD3) withdrawable by `owner` given cooldown/backing constraints.
  /// @param owner The address to query.
  function availableWithdrawLimit(address owner) external view returns (uint256);

  /// @notice Maximum assets (USD3) depositable by `owner` given the subordination cap.
  /// @param owner The address to query.
  function availableDepositLimit(address owner) external view returns (uint256);
}
