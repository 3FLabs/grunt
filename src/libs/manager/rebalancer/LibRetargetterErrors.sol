// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibRetargetterErrors
/// @author 3F Protocol
/// @notice Custom errors emitted by the Retargetter and its bases.
/// @dev Errors live in a library so every base contract can reference them through a single import
///      and so the 4-byte selectors are guaranteed to be globally unique.
library LibRetargetterErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       CONFIGURATION                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a configured timelock exceeds the protocol cap.
  error TimelockTooLong();

  /// @notice Thrown when a configured horizon falls outside `[MIN_HORIZON, MAX_HORIZON]`.
  error HorizonOutOfRange();

  /// @notice Thrown when a configured yield cap exceeds `MAX_MAX_YIELD_BPS`.
  error MaxYieldTooHigh();

  /// @notice Thrown when a per-PM yield cap exceeds the Retargetter's global cap at batch open.
  error PerPMYieldExceedsCap();

  /// @notice Thrown when the mint-to-repaid delay exceeds `MAX_MINT_TO_REPAID_DELAY`.
  error MintToRepaidDelayTooLong();

  /// @notice Thrown when `pause(duration)` is called with `duration > MAX_PAUSE_DURATION`.
  error PauseDurationTooLong();

  /// @notice Thrown when collateral and debt assets resolve to the same address at init.
  error CollateralEqualsDebt();

  /// @notice Thrown when `tickDuration` is zero or exceeds `MAX_TICK_DURATION`.
  error TickDurationOutOfRange();

  /// @notice Thrown when `tickThreshold` is greater than `tickDuration` (it must fit inside one
  ///         tick to keep the rounding logic monotonic).
  error TickThresholdTooLong();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          BATCH                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when {openBatch} is called while a batch is already open.
  error BatchAlreadyOpen();

  /// @notice Thrown when a batch operation requires an open batch but none is set.
  error NoActiveBatch();

  /// @notice Thrown when {openBatch} is given an empty entry array, a duplicated PM, or > MAX_BATCH_SIZE entries.
  error InvalidBatchSize();

  /// @notice Thrown when a PM in the batch has the wrong (collateral, debt) pair.
  error PositionManagerAssetMismatch();

  /// @notice Thrown when the `repaymentDeadline` supplied to {openBatch} is outside the accepted
  ///         window: must be strictly after `block.timestamp + consumeTimelock` so a consume
  ///         window opens before the Request auto-expires, and must not exceed
  ///         `block.timestamp + MAX_REPAYMENT_DEADLINE_OFFSET`.
  error RepaymentDeadlineOutOfRange();

  /// @notice Thrown when {closeBatch} is called while one of the batch's Requests still has open
  ///         (un-repaid) liabilities.
  error BatchNotFullyRepaid();

  /// @notice Thrown when the optional fund supplied to {openBatch} does not expose
  ///         `asset() == debtAsset` and `share() == collateralAsset`.
  error FundAssetMismatch();

  /// @notice Thrown when {closeBatch} runs while the attached fund still has a live order that has
  ///         not reached the terminal {State.ENDED}. Mirrors the Facility's no-pending-order
  ///         precondition for resolving an intent / abandoning a fund.
  error FundOrderPending();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          AUCTION                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the consume timelock has not yet elapsed for the current batch.
  error ConsumeTimelockNotElapsed();

  /// @notice Thrown when a consume / authorise call targets a PM that is not part of the open batch.
  error PMNotInBatch();

  /// @notice Thrown when the targeted PM has no Request (entry's `maxPrincipal` was zero at open).
  error PMHasNoRequest();

  /// @notice Thrown when a consume / authorise call would push `consumed` past the PM's `maxPrincipal`.
  error PrincipalCapExceeded();

  /// @notice Thrown when the offer's `expectedReturn / amount` exceeds the per-PM `maxYieldBps`.
  error YieldTooHigh();

  /// @notice Thrown when {consumeOffer} is called with `ptAmount == 0`.
  error InvalidPtAmount();

  /// @notice Thrown when {authorizeMinting} is called with `ptAmount == 0`.
  error InvalidAuthAmount();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         PROPOSAL                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when {propose} is called while a proposal is already pending.
  error ProposalAlreadyPending();

  /// @notice Thrown when {executeProposal} / {cancelProposal} is called with no pending proposal.
  error NoPendingProposal();

  /// @notice Thrown when {executeProposal} runs before `executableAt`.
  error ProposalTimelockNotElapsed();

  /// @notice Thrown when the supplied proposal does not match the stored hash.
  error ProposalHashMismatch();

  /// @notice Thrown when the proposal lists a module address that is not on the whitelist.
  error UnauthorisedModule();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ACTIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an action references a PM that is not part of the open batch.
  ///         All rebalance / repay actions must target a batch member to bound the blast radius.
  error ActionTargetNotInBatch();

  /// @notice Thrown when a REPAY_REQUEST action runs while the contract's balance falls outside the
  ///         range `[minBalance, maxBalance]` declared in the action payload.
  error RepayBalanceOutOfRange();

  /// @notice Thrown when an unknown action kind appears in the proposal payload.
  error UnknownActionKind();

  /// @notice Thrown when a FUND_CREATE action's order has `owner` or `receiver` different from
  ///         the Retargetter. Created here so unlock / recover outputs cannot be exfiltrated to a
  ///         third party through the order's receiver slot.
  error FundOrderOwnershipInvalid();

  /// @notice Thrown when a FUND_* action runs but no fund is attached to the open batch.
  error NoBatchFund();

  /// @notice Thrown when a FUND_CREATE action runs while the batch already has a live order.
  error FundOrderAlreadyActive();

  /// @notice Thrown when a FUND_CANCEL / FUND_COMMIT / FUND_UNLOCK / FUND_RECOVER action runs but
  ///         the batch has no live order.
  error NoActiveFundOrder();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     MODULE / CALLBACK                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when {executeProposalCallback} runs outside an active module-driven execution.
  error NotInModuleExecution();

  /// @notice Thrown when {executeProposalCallback} is invoked by anyone other than the in-flight
  ///         module (mismatch against the transient context).
  error UnauthorisedCallback();

  /// @notice Thrown when {addFlashLoanModule} is called with an address already on the whitelist.
  error ModuleAlreadyRegistered();

  /// @notice Thrown when {removeFlashLoanModule} is called with an address not on the whitelist.
  error ModuleNotRegistered();

  /// @notice Thrown when a second module-driven execution would nest inside an active one.
  error NestedModuleExecution();

  /// @notice Thrown when {executeProposal} dispatched to a module but the module returned without
  ///         ever calling {executeProposalCallback}. The proposal is treated as failed.
  error CallbackNotInvoked();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PAUSABLE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a pausable entry point runs while the Retargetter is paused.
  error Paused();
}
