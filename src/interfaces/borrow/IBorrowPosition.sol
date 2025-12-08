// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.19;

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
  /// @return The total borrowed asset amount.
  function totalBorrowed() external view returns (uint256);

  /// @notice Returns the total amount of collateral of this position.
  /// @return The total collateral amount.
  function totalCollateral() external view returns (uint256);

  /// @notice Checks if the borrow position is healthy (not liquidatable).
  /// @return True if the position is healthy, false otherwise.
  function isHealthy() external view returns (bool);

  /// @notice Checks if the borrow position is within the target LLTV.
  /// @return True if the position's health is above the target LLTV, false otherwise.
  function inTarget() external view returns (bool);

  /// @notice Returns the maximum amount that can be borrowed from this position (before liquidation).
  /// @return The maximum borrowable amount.
  function maxBorrow() external view returns (uint256);

  /// @notice Returns the maximum borrow before reaching the target LLTV.
  /// @return The maximum borrowable amount to reach target LLTV.
  function maxBorrowTarget() external view returns (uint256);

  /// @notice Returns the target LLTV for this borrow position.
  /// @return The target LLTV as a wad (1e18 scale).
  function targetLltv() external view returns (uint256);
}
