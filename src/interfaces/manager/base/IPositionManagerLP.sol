// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {WithdrawalStrategy} from "./IPositionManagerAdmin.sol";

/// @title IPositionManagerLP
/// @author 3F Protocol
/// @notice Interface for liquidity provider operations of the PositionManager contract.
/// @dev Handles deposit, withdraw, and burn operations for share management.
interface IPositionManagerLP {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when fees are accrued and minted to the fee recipient.
  /// @param feeRecipient The address receiving the fee shares
  /// @param shares The amount of shares minted as fees
  event FeesAccrued(address indexed feeRecipient, uint256 shares);

  /// @notice Emitted when a deposit is made.
  /// @param caller The address that initiated the deposit
  /// @param collateral The amount of collateral deposited
  /// @param debt The amount of debt borrowed
  /// @param shares The amount of shares minted (positive) or burned (negative)
  event Deposit(address indexed caller, uint256 collateral, uint256 debt, int256 shares);

  /// @notice Emitted when a withdrawal is made.
  /// @param caller The address that initiated the withdrawal
  /// @param collateral The amount of collateral withdrawn
  /// @param debt The amount of debt repaid
  /// @param shares The amount of shares burned (negative) or minted (positive)
  event Withdraw(address indexed caller, uint256 collateral, uint256 debt, int256 shares);

  /// @notice Emitted when shares are burned.
  /// @param caller The address that burned shares
  /// @param shares The amount of shares burned
  /// @param collateral The amount of collateral received
  /// @param debt The amount of debt repaid
  event Burn(address indexed caller, uint256 shares, uint256 collateral, uint256 debt);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        OPERATIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits collateral and borrows debt across the aggregated borrow positions.
  /// @dev Iterates through the supply queue, borrowing up to maxBorrow per entry and available
  ///      liquidity. Collateral is deposited proportionally to the amount borrowed.
  ///      - If debt is 0, all collateral goes to the first queue entry
  ///      - If borrow capacity is exhausted, reverts with InsufficientBorrowCapacity
  ///      - Accrues fees before the operation
  ///      - Mints or burns shares based on the net value change (with virtual offset for security)
  /// @param collateral The total amount of collateral to deposit (pulled from caller)
  /// @param debt The total amount of debt to borrow (sent to caller)
  /// @return shares Positive if shares minted, negative if shares burned
  function deposit(uint256 collateral, uint256 debt) external returns (int256 shares);

  /// @notice Withdraws collateral and repays debt across the aggregated borrow positions.
  /// @dev Processes through the withdrawal queue using the specified strategy:
  ///      - SEQUENTIAL: drains positions one-by-one (repay debt → withdraw collateral per position)
  ///      - PROPORTIONAL: distributes repayment and withdrawal proportionally across all positions
  ///      Reverts with InsufficientAvailableCollateral if attempting to withdraw locked collateral.
  ///      Accrues fees before the operation. Burns shares based on the net value change.
  /// @param collateral The total amount of collateral to withdraw (sent to caller)
  /// @param debt The total amount of debt to repay (pulled from caller)
  /// @param strategy The withdrawal strategy to use (SEQUENTIAL or PROPORTIONAL)
  /// @return shares Positive if shares minted, negative if shares burned
  function withdraw(uint256 collateral, uint256 debt, WithdrawalStrategy strategy) external returns (int256 shares);

  /// @notice Burns shares by repaying debt and withdrawing collateral.
  /// @dev This function calculates the proportional amount of debt to repay and collateral
  ///      to withdraw based on the shares being burned, then executes these operations across
  ///      the withdrawal queue using the specified strategy:
  ///      - SEQUENTIAL: drains positions one-by-one
  ///      - PROPORTIONAL: distributes proportionally across all positions
  ///      Caller receives collateral, caller provides debt repayment.
  /// @param shares The amount of shares to burn
  /// @param strategy The withdrawal strategy to use (SEQUENTIAL or PROPORTIONAL)
  /// @return collateral The total amount of collateral withdrawn
  /// @return debt The total amount of debt that needs to be repaid (pulled from caller)
  function burn(uint256 shares, WithdrawalStrategy strategy) external returns (uint256 collateral, uint256 debt);
}
