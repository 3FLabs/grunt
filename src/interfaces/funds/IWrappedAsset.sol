// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

/// @notice Interface for a wrapped asset token with minting and burning capabilities.
/// @dev Not inheriting from IERC20 to avoid dependencies issues.
interface IWrappedAsset {
  /// @notice Mints `amount` tokens to the `to` address.
  /// @param to The address to mint tokens to.
  /// @param amount The amount of tokens to mint.
  function mint(address to, uint256 amount) external;

  /// @notice Burns `amount` tokens from the `from` address.
  /// @param from The address to burn tokens from.
  /// @param amount The amount of tokens to burn.
  function burn(address from, uint256 amount) external;
}
