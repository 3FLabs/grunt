// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

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

/// @title IPositionManagerRebalancing
/// @author 3F Protocol
/// @notice Interface for rebalancing operations of the PositionManager contract.
/// @dev Allows redistribution of collateral and debt across borrow positions without minting/burning shares.
interface IPositionManagerRebalancing {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted after a successful rebalance with input and excess data.
  /// @param receiver The address that received excess collateral and debt.
  /// @param collateralSent The collateral asset amount pulled from the caller.
  /// @param debtSent The debt asset amount pulled from the caller.
  /// @param collateralExcess The excess collateral asset returned to the receiver.
  /// @param debtExcess The excess debt asset returned to the receiver.
  event Rebalanced(
    address indexed receiver, uint256 collateralSent, uint256 debtSent, uint256 collateralExcess, uint256 debtExcess
  );

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REBALANCING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Rebalances liquidity across borrow positions without minting or burning shares.
  /// @dev Only callable by accounts with the rebalancer role. Pulls `data.collateral` and
  ///      `data.debt` from the caller, executes `data.operations` in sequence (see
  ///      {RebalancingOperationType}), returns any excess assets to the receiver, and verifies
  ///      totalAssets did not decrease by more than maxRebalanceLoss.
  /// @param data The rebalancing data containing amounts to pull from caller and operations to execute
  /// @param receiver The address to receive any excess collateral and debt assets
  /// @return collateralExcess The excess collateral asset amount returned to the receiver
  /// @return debtExcess The excess debt asset amount returned to the receiver
  function rebalance(RebalancingData calldata data, address receiver)
    external
    returns (uint256 collateralExcess, uint256 debtExcess);
}
