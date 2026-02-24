// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPositionManagerAdmin, SupplyQueueEntry, WithdrawalStrategy} from "./base/IPositionManagerAdmin.sol";
import {IPositionManagerRebalancing} from "./base/IPositionManagerRebalancing.sol";
import {IPositionManagerLP} from "./base/IPositionManagerLP.sol";

/// @title IPositionManager
/// @author 3F Protocol
/// @notice Interface for the PositionManager contract that aggregates multiple borrow positions
///         (IBorrowPosition) into a single unified interface. The PositionManager allows the owner
///         to combine operations across multiple borrowing protocols (e.g., Morpho, Euler, etc.)
///         and manage them as a single position. This enables more complex strategies that leverage
///         multiple lending markets simultaneously while presenting a simplified interface to users.
interface IPositionManager is IPositionManagerAdmin, IPositionManagerRebalancing, IPositionManagerLP {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the supply queue used for deposits.
  /// @return Array of SupplyQueueEntry structs (position address + max borrow)
  function supplyQueue() external view returns (SupplyQueueEntry[] memory);

  /// @notice Returns the withdrawal queue used for withdrawals.
  /// @return Array of position addresses in withdrawal order
  function withdrawalQueue() external view returns (address[] memory);

  /// @notice Returns all whitelisted borrow modules.
  /// @return Array of borrow module addresses
  function borrowModules() external view returns (address[] memory);

  /// @notice Checks if an address is a whitelisted borrow module.
  /// @param module The address to check
  /// @return True if the address is a whitelisted borrow module
  function isBorrowModule(address module) external view returns (bool);

  /// @notice Returns the collateral and debt asset addresses.
  /// @return collateralAsset The address of the collateral asset token
  /// @return debtAsset The address of the debt asset token
  function assets() external view returns (address collateralAsset, address debtAsset);

  /// @notice Returns the total amount of collateral across all borrow positions.
  /// @dev The collateral is in raw collateral asset units.
  /// @return The total collateral amount across all positions
  function collateralAmount() external view returns (uint256);

  /// @notice Returns the total amount of collateral quoted in debt asset terms.
  /// @dev Uses each position's oracle to convert collateral to debt asset value.
  /// @return The total collateral value in debt asset terms
  function collateralAmountQuoted() external view returns (uint256);

  /// @notice Returns the total amount of debt across all borrow positions.
  /// @dev The debt represents the total borrowed amount across all aggregated positions.
  /// @return The total debt amount across all positions
  function debtAmount() external view returns (uint256);

  /// @notice Returns the total assets (collateral value - debt) of the position manager.
  /// @dev This is the net value that determines share pricing.
  /// @return The total assets value in debt asset terms
  function totalAssets() external view returns (uint256);

  /// @notice Returns the fee configuration and accounting state.
  /// @return feeRecipient The address that receives fee payments
  /// @return managementFee The management fee rate in basis points per 365 days
  /// @return performanceFee The performance fee rate in basis points
  /// @return lastTotalAssets The last total assets snapshot for performance fee calculation
  /// @return lastFeeAccrualTimestamp The timestamp of the last fee accrual
  function feeData()
    external
    view
    returns (
      address feeRecipient,
      uint24 managementFee,
      uint24 performanceFee,
      uint256 lastTotalAssets,
      uint256 lastFeeAccrualTimestamp
    );

  /// @notice Returns the configuration parameters.
  /// @return ltv The LTV used for available collateral calculations (WAD precision)
  /// @return maxRebalanceLoss The maximum allowed loss during rebalance in basis points
  /// @return transferGuard The address of the transfer guard contract (address(0) if disabled)
  /// @return rebalanceCooldown The minimum seconds between consecutive rebalance calls (0 = disabled)
  /// @return lastRebalanceTimestamp The timestamp of the last rebalance call (0 if never rebalanced)
  function config()
    external
    view
    returns (
      uint256 ltv,
      uint16 maxRebalanceLoss,
      address transferGuard,
      uint40 rebalanceCooldown,
      uint40 lastRebalanceTimestamp
    );
}
