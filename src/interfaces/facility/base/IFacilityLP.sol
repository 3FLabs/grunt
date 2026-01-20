// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IFacilityLP
/// @author 3F Protocol
/// @notice Interface for liquidity provider operations.
interface IFacilityLP {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     LIQUIDITY PROVIDERS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits assets into the intent as a liquidity provider.
  /// @param id The intent ID.
  /// @param amount The amount to deposit.
  function deposit(uint256 id, uint256 amount) external;

  /// @notice Withdraws assets from the intent as a liquidity provider.
  /// @dev If `from` is not `msg.sender`, the caller must be an operator for `from`.
  /// @param id The intent ID.
  /// @param from The address to burn LP tokens from.
  /// @param receiver The address to receive the withdrawn assets.
  /// @param amount The amount to withdraw.
  function withdraw(uint256 id, address from, address receiver, uint256 amount) external;

  /// @notice Claims resolved assets for the intent.
  /// @dev If `from` is not `msg.sender`, the caller must be an operator for `from`.
  ///      Returns the tokens and amounts distributed for verification and integration purposes.
  /// @param id The intent ID.
  /// @param from The address to burn LP tokens from.
  /// @param receiver The address to receive the claimed assets.
  /// @param shares The amount of shares to burn.
  /// @return tokens The array of token addresses that were distributed.
  /// @return amounts The array of amounts distributed for each token (same order as tokens).
  function claim(uint256 id, address from, address receiver, uint256 shares)
    external
    returns (address[] memory tokens, uint256[] memory amounts);
}
