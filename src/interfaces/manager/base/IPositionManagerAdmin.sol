// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @notice Structure representing a position in the supply queue with its borrow cap.
/// @param position The address of the IBorrowPosition contract
/// @param maxBorrow The maximum amount that can be borrowed from this position in a single deposit
struct SupplyQueueEntry {
  address position;
  uint96 maxBorrow;
}

/// @notice Strategy for processing withdrawals across the withdrawal queue.
/// @dev SEQUENTIAL: drains positions one-by-one through the queue (repay debt then withdraw collateral per position).
///      PROPORTIONAL: distributes repayment and withdrawal proportionally across all positions based on their share of totals.
enum WithdrawalStrategy {
  SEQUENTIAL,
  PROPORTIONAL
}

/// @title IPositionManagerAdmin
/// @author 3F Protocol
/// @notice Interface for administrative functions of the PositionManager contract.
/// @dev Handles borrow module management, queue configuration, LTV, fees, and transfer guard settings.
interface IPositionManagerAdmin {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the supply queue is updated.
  /// @param queue The new supply queue entries
  event SupplyQueueSet(SupplyQueueEntry[] queue);

  /// @notice Emitted when the withdrawal queue is updated.
  /// @param queue The new withdrawal queue (position addresses)
  event WithdrawalQueueSet(address[] queue);

  /// @notice Emitted when the LTV is updated.
  /// @param ltv The new LTV value
  event LTVSet(uint256 ltv);

  /// @notice Emitted when fee data is updated.
  /// @param feeRecipient The address receiving fees
  /// @param managementFee The management fee rate
  /// @param performanceFee The performance fee rate
  event FeeDataSet(address feeRecipient, uint24 managementFee, uint24 performanceFee);

  /// @notice Emitted when the performance reference is force-advanced to the current state.
  /// @param lastTotalAssets The new reference NAV
  /// @param lastDebt The new reference debt
  event PerformanceReferenceReset(uint256 lastTotalAssets, uint256 lastDebt);

  /// @notice Emitted when a borrow module is added to the whitelist.
  /// @param module The address of the borrow module added
  event BorrowModuleAdded(address indexed module);

  /// @notice Emitted when a borrow module is removed from the whitelist.
  /// @param module The address of the borrow module removed
  event BorrowModuleRemoved(address indexed module);

  /// @notice Emitted when the rebalance configuration is updated.
  /// @param maxRebalanceLoss The new max rebalance loss value in basis points
  /// @param rebalanceCooldown The new cooldown period in seconds (0 = disabled)
  event RebalanceConfigSet(uint16 maxRebalanceLoss, uint40 rebalanceCooldown);

  /// @notice Emitted when the transfer guard is updated.
  /// @param transferGuard The new transfer guard address (address(0) to disable)
  event TransferGuardSet(address indexed transferGuard);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Adds a borrow module to the whitelist.
  /// @dev Only callable by the owner. Whitelisted modules can be used in supply/withdrawal queues.
  /// @param module The address of the borrow module to add
  function addBorrowModule(address module) external;

  /// @notice Removes a borrow module from the whitelist and transfers its ownership to the caller.
  /// @dev Only callable by the owner.
  /// @param module The address of the borrow module to remove
  function removeBorrowModule(address module) external;

  /// @notice Sets the supply queue used for deposits.
  /// @dev Only callable by accounts with the curator role. The queue determines deposit priority and borrow caps.
  ///      All positions in the queue must be whitelisted borrow modules.
  /// @param queue Array of SupplyQueueEntry structs
  function setSupplyQueue(SupplyQueueEntry[] calldata queue) external;

  /// @notice Sets the withdrawal queue used for withdrawals.
  /// @dev Only callable by accounts with the curator role. The queue determines withdrawal/repayment priority.
  ///      All positions in the queue must be whitelisted borrow modules.
  /// @param queue Array of position addresses
  function setWithdrawalQueue(address[] calldata queue) external;

  /// @notice Sets the LTV used for available collateral calculations.
  /// @dev Only callable by the owner. Should be <= the minimum LTV of all positions.
  /// @param ltv_ The new LTV value (WAD precision, 1e18 = 100%)
  function setLtv(uint256 ltv_) external;

  /// @notice Sets the fee configuration data for this PositionManager.
  /// @dev Before updating the fee configuration, this function must accrue and allocate any pending
  ///      fee shares to the current fee recipient. This ensures that the previous fee recipient receives
  ///      all fees that have accrued up to the point of the update. Only callable by the owner.
  /// @param feeRecipient The address that will receive fee payments going forward
  /// @param managementFee The management fee rate in basis points per 365 days (e.g., 200 = 2% per year),
  ///        charged on the aggregate collateral of non-bad-debt positions (not on NAV).
  /// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%), charged on the
  ///        levered-slice basis `LTV_prev * currentCollat - currentDebt`, less the management fees
  ///        charged since the reference last advanced. See `FeeData` in `LibStorage` for the full derivation.
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external;

  /// @notice Force-advances the performance reference (high-water mark) to the current state.
  /// @dev Only callable by the owner. Escape hatch for a permanent drawdown or a realized
  ///      liquidation loss: the held reference would otherwise suppress performance fees until the
  ///      pool recovers past the old mark, which may never happen. Fees accrue first, so a positive
  ///      pending basis crystallizes to the current recipient at the configured rate; the reset
  ///      itself never charges past gains, it forgives the carried negative basis and future gains
  ///      are charged from the current state onward.
  ///
  ///      The reset starts a fresh fee period: the held management fee accumulator (management
  ///      fees charged and not yet netted against a crystallized basis, normally deducted from
  ///      the next positive basis) is cleared as well.
  ///
  ///      Timing: the reset writes off ALL carried basis, including the debt interest accrued
  ///      since the last crystallization (not just the loss being accepted), plus the pending
  ///      management fee deduction, and the next positive accrual then overcharges by exactly
  ///      those forgiven amounts. Call this as soon as possible after a positive performance fee
  ///      charge (when the pending carry and deduction are smallest), not deep into a flat-quote
  ///      period.
  function resetPerformanceReference() external;

  /// @notice Sets the rebalance configuration (max loss and cooldown).
  /// @dev Only callable by the owner. maxRebalanceLoss limits how much totalAssets can decrease
  ///      during a rebalance. rebalanceCooldown enforces a minimum time between consecutive calls.
  /// @param maxRebalanceLoss_ The max rebalance loss in basis points (e.g., 100 = 1%)
  /// @param rebalanceCooldown_ The cooldown period in seconds (0 = disabled)
  function setRebalanceConfig(uint16 maxRebalanceLoss_, uint40 rebalanceCooldown_) external;

  /// @notice Sets the transfer guard contract.
  /// @dev Only callable by the owner. Set to address(0) to disable transfer restrictions.
  /// @param transferGuard_ The address of the transfer guard contract
  function setTransferGuard(address transferGuard_) external;
}
