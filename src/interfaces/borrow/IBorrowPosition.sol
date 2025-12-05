// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IBorrowPosition
/// @notice Interface for borrow position contracts that manages a single borrowing position (e.g. Morpho, Euler, etc.)
interface IBorrowPosition {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          OPERATIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Supplies collateral to the borrow position.
  /// @param amount The amount of collateral to supply.
  function supplyCollateral(uint256 amount) external;

  /// @notice Withdraws collateral from the borrow position.
  /// @param amount The amount of collateral to withdraw.
  function withdrawCollateral(uint256 amount) external;

  /// @notice Borrows assets from the borrow position.
  /// @param amount The amount of assets to borrow.
  function borrow(uint256 amount) external;

  /// @notice Repays borrowed assets to the borrow position.
  /// @param amount The amount of assets to repay.
  function repay(uint256 amount) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ASSETS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the address of the asset being borrowed.
  /// @return The address of the borrowed asset.
  function borrowAsset() external view returns (address);

  /// @notice Returns the address of the collateral asset used in this borrow position.
  /// @return The address of the collateral asset.
  function collateralAsset() external view returns (address);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          POSITION                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the total amount of assets borrowed in this position.
  /// @return The total borrowed asset amount
  function totalBorrowed() external view returns (uint256);

  /// @notice Returns the total amount of collateral of this position.
  /// @return The total collateral amount
  function totalCollateral() external view returns (uint256);

  /// @notice Checks if the borrow position is healthy.
  function isHealthy() external view returns (bool);

  /// @notice Returns the maximum amount that can be borrowed from this position.
  /// @return The maximum borrowable amount
  function maxBorrow() external view returns (uint256);
}
