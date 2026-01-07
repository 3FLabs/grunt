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

/// @notice Structure representing a position in the supply queue with its borrow cap.
/// @param position The address of the IBorrowPosition contract
/// @param maxBorrow The maximum amount that can be borrowed from this position in a single deposit
struct SupplyQueueEntry {
  address position;
  uint96 maxBorrow;
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
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the supply queue runs out of capacity during a deposit.
  error InsufficientBorrowCapacity();

  /// @notice Thrown when attempting to deposit collateral but the supply queue is empty.
  error EmptySupplyQueue();

  /// @notice Thrown when attempting to withdraw more collateral than is available.
  error InsufficientAvailableCollateral();

  /// @notice Thrown when a zero amount is passed where non-zero is required.
  error ZeroAmount();

  /// @notice Thrown when share calculation results in zero shares.
  error ZeroShares();

  /// @notice Thrown when fee value exceeds the maximum allowed.
  error FeeExceedsMax();

  /// @notice Thrown when a queue contains a position that is not whitelisted.
  error UnauthorizedPosition();

  /// @notice Thrown when attempting to remove a module that is still in a queue.
  error ModuleStillInQueue();

  /// @notice Thrown when rebalance causes total assets to decrease by more than maxRebalanceLoss.
  error RebalanceLossExceedsMax();

  /// @notice Thrown when attempting to repay more debt than exists across all positions.
  error ExcessDebtRepay();

  /// @notice Thrown when attempting to set an invalid LLTV value (zero or greater than WAD).
  error InvalidLltv();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the supply queue is updated.
  /// @param queue The new supply queue entries
  event SupplyQueueSet(SupplyQueueEntry[] queue);

  /// @notice Emitted when the withdrawal queue is updated.
  /// @param queue The new withdrawal queue (position addresses)
  event WithdrawalQueueSet(address[] queue);

  /// @notice Emitted when the LLTV is updated.
  /// @param lltv The new LLTV value
  event LLTVSet(uint256 lltv);

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
  /// @return lltv The LLTV used for available collateral calculations (WAD precision)
  /// @return maxRebalanceLoss The maximum allowed loss during rebalance in basis points
  function config() external view returns (uint256 lltv, uint16 maxRebalanceLoss);

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
  /// @dev Iterates through the withdrawal queue. Repays debt first, then withdraws collateral.
  ///      - If withdrawing collateral without full debt repayment, checks available collateral based on LLTV
  ///      - Reverts with InsufficientAvailableCollateral if attempting to withdraw locked collateral
  ///      - Accrues fees before the operation
  ///      - Burns shares based on the net value change
  /// @param collateral The total amount of collateral to withdraw (sent to caller)
  /// @param debt The total amount of debt to repay (pulled from caller)
  /// @return shares Positive if shares minted, negative if shares burned
  function withdraw(uint256 collateral, uint256 debt) external returns (int256 shares);

  /// @notice Burns shares by repaying debt and withdrawing collateral proportionally.
  /// @dev This function calculates the proportional amount of debt to repay and collateral
  ///      to withdraw based on the shares being burned, then executes these operations across
  ///      all configured IBorrowPosition contracts. Uses the withdrawal queue for ordering.
  ///      - Debt is repaid first to unlock collateral
  ///      - Collateral is withdrawn proportionally after debt repayment
  ///      - Caller receives collateral, caller provides debt repayment
  /// @param shares The amount of shares to burn
  /// @return collateral The total amount of collateral withdrawn
  /// @return debt The total amount of debt that needs to be repaid (pulled from caller)
  function burn(uint256 shares) external returns (uint256 collateral, uint256 debt);

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

  /// @notice Sets the LLTV used for available collateral calculations.
  /// @dev Only callable by the owner. Should be <= the minimum LLTV of all positions.
  /// @param lltv_ The new LLTV value (WAD precision, 1e18 = 100%)
  function setLltv(uint256 lltv_) external;

  /// @notice Sets the fee configuration data for this PositionManager.
  /// @dev Before updating the fee configuration, this function must accrue and allocate any pending
  ///      fee shares to the current fee recipient. This ensures that the previous fee recipient receives
  ///      all fees that have accrued up to the point of the update. Only callable by the owner.
  /// @param feeRecipient The address that will receive fee payments going forward
  /// @param managementFee The management fee rate in basis points per 365 days (e.g., 200 = 2% per year)
  /// @param performanceFee The performance fee rate in basis points (e.g., 2000 = 20%)
  function setFeeData(address feeRecipient, uint24 managementFee, uint24 performanceFee) external;

  /// @notice Rebalances liquidity across borrow positions without minting or burning shares.
  /// @dev Only callable by accounts with the rebalancer role. This function allows redistribution of collateral and debt across positions
  ///      to achieve desired LTV ratios. The function executes the following steps:
  ///      1. Pulls `data.collateral` amount of collateral asset from the caller
  ///      2. Pulls `data.debt` amount of debt asset from the caller
  ///      3. Executes all operations in `data.operations` array in sequence:
  ///         - REPAY: Repays debt on the specified position (consumes debt asset)
  ///         - WITHDRAW: Withdraws collateral from the specified position (receives collateral asset)
  ///         - BORROW: Borrows debt from the specified position (receives debt asset)
  ///         - SUPPLY: Supplies collateral to the specified position (consumes collateral asset)
  ///      4. Returns any excess collateral and debt assets back to the caller
  ///      5. Verifies totalAssets didn't decrease by more than maxRebalanceLoss
  /// @param data The rebalancing data containing amounts to pull from caller and operations to execute
  /// @return collateralExcess The excess collateral asset amount returned to the caller
  /// @return debtExcess The excess debt asset amount returned to the caller
  function rebalance(RebalancingData calldata data) external returns (uint256 collateralExcess, uint256 debtExcess);

  /// @notice Sets the maximum allowed loss during rebalance operations.
  /// @dev Only callable by the owner. This limits how much totalAssets can decrease during a rebalance.
  /// @param maxRebalanceLoss_ The max rebalance loss in basis points (e.g., 100 = 1%)
  function setMaxRebalanceLoss(uint16 maxRebalanceLoss_) external;
}
