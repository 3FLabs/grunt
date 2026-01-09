// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Interface for a wrapped asset token with wrap/unwrap capabilities.
/// @dev The wrapper holds underlying assets 1:1 and mints/burns wrapper tokens accordingly.
interface IWrappedAsset {
  /// @notice Wraps underlying asset: pulls underlying from `from`, mints wrapper tokens to `to`.
  /// @dev Requires ISSUER_ROLE. The `from` address must have approved this contract to spend underlying.
  /// @param from The address to pull underlying asset from.
  /// @param to The address to mint wrapper tokens to.
  /// @param amount The amount of tokens to wrap.
  function mint(address from, address to, uint256 amount) external;

  /// @notice Unwraps to underlying asset: burns wrapper tokens from `from`, sends underlying to `to`.
  /// @dev If `from != msg.sender`, the caller must have sufficient allowance on the wrapper token.
  /// @param from The address to burn wrapper tokens from.
  /// @param to The address to send underlying asset to.
  /// @param amount The amount of tokens to unwrap.
  function burn(address from, address to, uint256 amount) external;

  /// @notice Returns the address of the underlying asset (the asset being wrapped).
  /// @return The underlying asset address.
  function underlying() external view returns (address);
}
