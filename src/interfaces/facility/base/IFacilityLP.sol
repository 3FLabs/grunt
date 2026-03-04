// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

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

  /// @notice Reverts a user's deposit, returning the full deposited amount.
  /// @dev Only callable by the owner or COMPLIANCE_ROLE. Verifies that the intent's deposit asset
  ///      balance is at least equal to the total supply, meaning the intent resolution has not started
  ///      (or the intent still has enough deposit asset balance to fully reimburse the user).
  ///      The user receives back all deposited assets in full but forfeits any proportional claim
  ///      to other assets that may have been added to the intent.
  ///      When `receiver` differs from `from`, only the owner can call this to prevent the
  ///      compliance role from redirecting user funds to an arbitrary address.
  /// @param id The intent ID.
  /// @param from The address whose deposit is being reverted (must hold intent shares).
  /// @param receiver The address to receive the deposit asset.
  function revertDeposit(uint256 id, address from, address receiver) external;

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
