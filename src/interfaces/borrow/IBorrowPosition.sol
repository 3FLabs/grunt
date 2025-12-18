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

  /// @notice Returns the total amount of collateral of this position (quoted in borrowed asset).
  /// @return The total collateral amount.
  function totalCollateral() external view returns (uint256);

  /// @notice Checks if the borrow position is healthy for a given LLTV.
  /// @param lltv The loan-to-liquidation value to check against.
  /// @return True if the position is healthy, false otherwise.
  function isHealthy(uint256 lltv) external view returns (bool);

  /// @notice Returns the maximum amount that can be borrowed from this position for a given LLTV
  ///         (taking into account available liquidity).
  /// @param lltv The loan-to-liquidation value to consider.
  /// @return The maximum borrowable amount.
  function maxBorrow(uint256 lltv) external view returns (uint256);

  /// @notice Returns the available liquidity in the BorrowPosition market.
  /// @return The amount of assets available for borrowing.
  function availableLiquidity() external view returns (uint256);
}
