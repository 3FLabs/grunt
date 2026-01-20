// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title ITransferGuard
/// @author 3F Protocol
/// @notice Interface for transfer validation and pause functionality.
/// @dev Implementations can enforce blocklists, allowlists, transfer thresholds, or any custom logic.
interface ITransferGuard {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when an address status is updated.
  /// @param account The address whose status was updated
  /// @param status The new status (0=NONE, 1=WHITELIST, 2=BLOCKLIST)
  event AddressStatusSet(address indexed account, uint8 status);

  /// @notice Emitted when a token's configuration is updated.
  /// @param token The token address
  /// @param paused Whether the token is paused
  /// @param whitelist Whether the token uses whitelist mode
  event TokenConfigSet(address indexed token, bool paused, bool whitelist);

  /// @notice Emitted when a token is paused.
  /// @param token The token that was paused
  event TokenPaused(address indexed token);

  /// @notice Emitted when a token is unpaused.
  /// @param token The token that was unpaused
  event TokenUnpaused(address indexed token);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       VIEW FUNCTIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Checks if a transfer is allowed between two addresses.
  /// @dev Called by token contracts before executing transfers, mints, and burns.
  ///      For mints, `from` is address(0). For burns, `to` is address(0).
  /// @param token The token being transferred (allows one guard to serve multiple tokens)
  /// @param from The sender address (address(0) for mints)
  /// @param to The recipient address (address(0) for burns)
  /// @param amount The amount being transferred
  /// @return True if the transfer is allowed, false otherwise
  function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);

  /// @notice Returns whether operations are paused for a specific token.
  /// @dev When paused, all transfers should be blocked and other guarded operations should revert.
  /// @param token The token to check pause status for
  /// @return True if paused, false otherwise
  function paused(address token) external view returns (bool);
}
