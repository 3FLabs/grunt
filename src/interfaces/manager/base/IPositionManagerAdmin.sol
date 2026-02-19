// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Structure representing a position in the supply queue with its borrow cap.
/// @param position The address of the IBorrowPosition contract
/// @param maxBorrow The maximum amount that can be borrowed from this position in a single deposit
struct SupplyQueueEntry {
  address position;
  uint96 maxBorrow;
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

  /// @notice Emitted when a borrow module is added to the whitelist.
  /// @param module The address of the borrow module added
  event BorrowModuleAdded(address indexed module);

  /// @notice Emitted when a borrow module is removed from the whitelist.
  /// @param module The address of the borrow module removed
  event BorrowModuleRemoved(address indexed module);

  /// @notice Emitted when the max rebalance loss is updated.
  /// @param maxRebalanceLoss The new max rebalance loss value in basis points
  event MaxRebalanceLossSet(uint16 maxRebalanceLoss);

  /// @notice Emitted when the transfer guard is updated.
  /// @param transferGuard The new transfer guard address (address(0) to disable)
  event TransferGuardSet(address indexed transferGuard);

  /// @notice Emitted when the rebalance cooldown is updated.
  /// @param rebalanceCooldown The new cooldown period in seconds
  event RebalanceCooldownSet(uint40 rebalanceCooldown);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Adds a borrow module to the whitelist.
  /// @dev Only callable by the owner. Whitelisted modules can be used in supply/withdrawal queues.
  /// @param module The address of the borrow module to add
  function addBorrowModule(address module) external;

  /// @notice Removes a borrow module from the whitelist.
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
  /// @param managementFee The management fee rate in basis points per 365 days (e.g., 200 = 2% per year)
  /// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%)
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external;

  /// @notice Sets the maximum allowed loss during rebalance operations.
  /// @dev Only callable by the owner. This limits how much totalAssets can decrease during a rebalance.
  /// @param maxRebalanceLoss_ The max rebalance loss in basis points (e.g., 100 = 1%)
  function setMaxRebalanceLoss(uint16 maxRebalanceLoss_) external;

  /// @notice Sets the transfer guard contract.
  /// @dev Only callable by the owner. Set to address(0) to disable transfer restrictions.
  /// @param transferGuard_ The address of the transfer guard contract
  function setTransferGuard(address transferGuard_) external;

  /// @notice Sets the minimum cooldown period between consecutive rebalance calls.
  /// @dev Only callable by the owner. Set to 0 to disable the cooldown.
  /// @param rebalanceCooldown_ The cooldown period in seconds
  function setRebalanceCooldown(uint40 rebalanceCooldown_) external;
}
