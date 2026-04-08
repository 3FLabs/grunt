// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title IBorrowPosition
/// @author 3F Protocol
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

  /// @notice Returns the total amount of collateral deposited in this position.
  /// @return The total collateral amount (in collateral asset units).
  function totalCollateral() external view returns (uint256);

  /// @notice Returns the total amount of collateral of this position (quoted in borrowed asset).
  /// @return The total collateral amount quoted in borrowed asset.
  function totalCollateralQuoted() external view returns (uint256);

  /// @notice Checks if the borrow position is healthy for a given LTV.
  /// @param ltv The loan-to-value to check against.
  /// @return True if the position is healthy, false otherwise.
  function isHealthy(uint256 ltv) external view returns (bool);

  /// @notice Returns the remaining borrow capacity for this position at a given LTV.
  /// @dev Calculates `(collateralValue * ltv) - alreadyBorrowed`, then takes the minimum
  ///      with available market liquidity. Returns 0 if fully utilized or over-utilized.
  /// @param ltv The loan-to-value to consider.
  /// @return The remaining amount that can be borrowed.
  function maxBorrow(uint256 ltv) external view returns (uint256);

  /// @notice Returns the available liquidity in the BorrowPosition market.
  /// @return The amount of assets available for borrowing.
  function availableLiquidity() external view returns (uint256);

  /// @notice Returns the amount of collateral that can be withdrawn without making the position unhealthy.
  /// @dev Available collateral = collateral - (debt / ltv). If debt is 0, all collateral is available.
  ///      The result is in collateral asset units (not quoted).
  /// @param ltv The loan-to-value to use for the calculation.
  /// @return The amount of available collateral in collateral asset units.
  function availableCollateral(uint256 ltv) external view returns (uint256);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            LTV                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the additional collateral needed to borrow `borrowAmount` at the given `ltv`,
  ///         accounting for the position's current collateral and debt.
  /// @dev Returns 0 if the position already has enough excess collateral to cover the requested borrow.
  /// @param borrowAmount The additional borrow amount desired.
  /// @param ltv The loan-to-value ratio to use for the calculation (WAD).
  /// @return The additional collateral required (in collateral asset units). 0 if already sufficient.
  function collateralForBorrow(uint256 borrowAmount, uint256 ltv) external view returns (uint256);

  /// @notice Returns the additional borrow capacity gained by supplying `collateralAmount` at the given `ltv`,
  ///         accounting for the position's current collateral and debt.
  /// @dev Includes any existing excess collateral in the calculation.
  /// @param collateralAmount The additional collateral amount to hypothetically supply.
  /// @param ltv The loan-to-value ratio to use for the calculation (WAD).
  /// @return The additional borrow capacity (in borrow asset units).
  function borrowForCollateral(uint256 collateralAmount, uint256 ltv) external view returns (uint256);

  /// @notice Returns the safe LTV threshold for this borrow position.
  /// @dev The safe LTV is the maximum LTV that must not be reached upon position mutations
  ///      (borrow, withdrawCollateral). It is immutable after initialization.
  /// @return The safe LTV in WAD format (1e18 = 100%).
  function safeLtv() external view returns (uint128);
}
