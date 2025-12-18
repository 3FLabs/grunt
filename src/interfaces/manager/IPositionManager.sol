// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Enumeration of rebalancing operation types that can be performed on borrow positions.
enum RebalancingOperationType {
  /// @notice Repay debt on a borrow position (requires debt asset).
  REPAY,
  /// @notice Withdraw collateral from a borrow position (receives collateral asset).
  WITHDRAW,
  /// @notice Borrow debt from a borrow position (receives debt asset).
  BORROW,
  /// @notice Supply collateral to a borrow position (requires collateral asset).
  SUPPLY
}

/// @notice Structure representing a single rebalancing operation to execute.
/// @param position The address of the IBorrowPosition contract to operate on
/// @param operationType The type of operation to perform (REPAY, WITHDRAW, BORROW, or SUPPLY)
/// @param amount The amount of assets to use for this operation
struct RebalancingOperation {
  address position;
  RebalancingOperationType operationType;
  uint256 amount;
}

/// @notice Structure containing all data needed for a rebalancing operation.
/// @param collateral The amount of collateral asset to pull from the caller before executing operations
/// @param debt The amount of debt asset to pull from the caller before executing operations
/// @param operations Array of operations to execute in sequence
struct RebalancingData {
  uint256 collateral;
  uint256 debt;
  RebalancingOperation[] operations;
}

/// @title IPositionManager
/// @notice Interface for the PositionManager contract that aggregates multiple borrow positions
///         (IBorrowPosition) into a single unified interface. The PositionManager allows the owner
///         to combine operations across multiple borrowing protocols (e.g., Morpho, Euler, etc.)
///         and manage them as a single position. This enables more complex strategies that leverage
///         multiple lending markets simultaneously while presenting a simplified interface to users.
/// @dev The owner of the PositionManager is responsible for configuring which IBorrowPosition
///      contracts are included in the aggregation. All operations (deposit, withdraw, burn) are
///      executed across the combined positions, with share accounting based on the net value
///      (collateral minus debt) of the aggregated position.
interface IPositionManager {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEW                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the list of all borrow positions managed by this PositionManager.
  /// @return Array of IBorrowPosition contract addresses
  function borrowPositions() external view returns (address[] memory);

  /// @notice Returns the total amount of collateral across all borrow positions.
  /// @dev The collateral is quoted in the borrowed asset terms (as per IBorrowPosition.totalCollateral).
  /// @return The total collateral amount across all positions
  function collateralAmount() external view returns (uint256);

  /// @notice Returns the total amount of debt across all borrow positions.
  /// @dev The debt represents the total borrowed amount across all aggregated positions.
  /// @return The total debt amount across all positions
  function debtAmount() external view returns (uint256);

  /// @notice Returns the fee configuration data for this PositionManager.
  /// @dev Includes the fee recipient address and fee rates for management and performance fees.
  ///      Management fee is expressed in basis points per 365 days (e.g., 200 = 2% per year).
  ///      Performance fee is expressed in basis points (e.g., 2000 = 20%).
  /// @return feeRecipient The address that receives fee payments
  /// @return managementFee The management fee rate in basis points per 365 days
  /// @return performanceFee The performance fee rate in basis points
  function feeData() external view returns (address feeRecipient, uint24 managementFee, uint24 performanceFee);

  /// @notice Returns the amount of pending fee shares that have accrued but not yet claimed.
  /// @dev Fee shares accumulate based on the fee configuration and are typically claimable
  ///      by the fee recipient. This represents shares that would be minted to the fee recipient
  ///      if fees were to be collected at this moment.
  /// @return The amount of pending fee shares
  function pendingFeeShares() external view returns (uint256);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits collateral and borrows debt across the aggregated borrow positions.
  /// @dev This function distributes the collateral and debt operations across all configured
  ///      IBorrowPosition contracts. The share delta is calculated based on the net value change
  ///      (collateral minus debt) after the operation. A positive sharesDelta means shares are
  ///      minted (position value increased), while a negative sharesDelta means shares are burned
  ///      (position value decreased).
  /// @param collateral The total amount of collateral to deposit across all positions
  /// @param debt The total amount of debt to borrow across all positions
  /// @return sharesDelta The change in shares: positive for minting, negative for burning
  function deposit(uint256 collateral, uint256 debt) external returns (int256 sharesDelta);

  /// @notice Withdraws collateral and repays debt across the aggregated borrow positions.
  /// @dev This function distributes the collateral withdrawal and debt repayment operations
  ///      across all configured IBorrowPosition contracts. The share delta is calculated based
  ///      on the net value change (collateral minus debt) after the operation. A negative
  ///      sharesDelta means shares are burned (position value decreased), while a positive
  ///      sharesDelta means shares are minted (position value increased).
  /// @param collateral The total amount of collateral to withdraw across all positions
  /// @param debt The total amount of debt to repay across all positions
  /// @return sharesDelta The change in shares: negative for burning, positive for minting
  function withdraw(uint256 collateral, uint256 debt) external returns (int256 sharesDelta);

  /// @notice Burns shares by repaying debt and withdrawing collateral proportionally.
  /// @dev This function calculates the proportional amount of debt to repay and collateral
  ///      to withdraw based on the shares being burned, then executes these operations across
  ///      all configured IBorrowPosition contracts. The amounts returned represent the total
  ///      collateral withdrawn and debt repaid across all positions.
  /// @param shares The amount of shares to burn
  /// @return collateral The total amount of collateral withdrawn across all positions
  /// @return debt The total amount of debt repaid across all positions
  function burn(uint256 shares) external returns (uint256 collateral, uint256 debt);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Adds a new borrow position to the aggregated position manager.
  /// @dev The position must implement IBorrowPosition. Only callable by the owner.
  /// @param position The address of the IBorrowPosition contract to add
  function addBorrowPosition(address position) external;

  /// @notice Removes a borrow position from the aggregated position manager.
  /// @dev The position must have zero collateral and zero debt before removal. Only callable by the owner.
  /// @param position The address of the IBorrowPosition contract to remove
  function removeBorrowPosition(address position) external;

  /// @notice Sets the fee configuration data for this PositionManager.
  /// @dev Before updating the fee configuration, this function must accrue and allocate any pending
  ///      fee shares to the current fee recipient. This ensures that the previous fee recipient receives
  ///      all fees that have accrued up to the point of the update. Only callable by the owner.
  /// @param feeRecipient The address that will receive fee payments going forward
  /// @param managementFee The management fee rate in basis points per 365 days (e.g., 200 = 2% per year)
  /// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%)
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external;

  /// @notice Rebalances liquidity across borrow positions without minting or burning shares.
  /// @dev This function allows the owner to redistribute collateral and debt across positions
  ///      to achieve desired LTV ratios. The function executes the following steps:
  ///      1. Pulls `data.collateral` amount of collateral asset from the caller
  ///      2. Pulls `data.debt` amount of debt asset from the caller
  ///      3. Executes all operations in `data.operations` array in sequence:
  ///         - REPAY: Repays debt on the specified position (consumes debt asset)
  ///         - WITHDRAW: Withdraws collateral from the specified position (receives collateral asset)
  ///         - BORROW: Borrows debt from the specified position (receives debt asset)
  ///         - SUPPLY: Supplies collateral to the specified position (consumes collateral asset)
  ///      4. Returns any excess collateral and debt assets back to the caller
  /// @dev Example: To balance a 70% LTV position with a 50% LTV position:
  ///      ```
  ///      RebalancingData({
  ///        collateral: 0,  // No additional collateral needed
  ///        debt: 1000,     // Need 1000 USDC to repay on position A
  ///        operations: [
  ///          RebalancingOperation({position: positionA, operationType: REPAY, amount: 1000}),
  ///          RebalancingOperation({position: positionA, operationType: WITHDRAW, amount: 2000}),
  ///          RebalancingOperation({position: positionB, operationType: SUPPLY, amount: 2000}),
  ///          RebalancingOperation({position: positionB, operationType: BORROW, amount: 1000})
  ///        ]
  ///      })
  ///      ```
  ///      This will: repay 1000 USDC on A, withdraw 2000 collateral from A, supply 2000 collateral to B,
  ///      borrow 1000 USDC from B, and return any excess USDC to the caller.
  /// @dev This function can also be used to increase LTV by supplying more collateral and borrowing
  ///      more debt. In this case, set `data.collateral` and `data.debt` to the amounts to provide,
  ///      and include SUPPLY and BORROW operations in the operations array.
  /// @param data The rebalancing data containing amounts to pull from caller and operations to execute
  /// @return collateralExcess The excess collateral asset amount returned to the caller
  /// @return debtExcess The excess debt asset amount returned to the caller
  function rebalance(RebalancingData calldata data)
    external
    returns (uint256 collateralExcess, uint256 debtExcess);
}
