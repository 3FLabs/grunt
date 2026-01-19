// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IHasAsset
/// @notice Base interface for contracts that hold an underlying asset.
interface IHasAsset {
  /// @notice Returns the address of the underlying asset (ERC20).
  /// @return assetAddress The ERC20 token address
  function asset() external view returns (address assetAddress);
}
