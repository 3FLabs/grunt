// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ModuleContext} from "../../../libs/manager/rebalancer/Action.sol";

/// @title IFlashLoanModule
/// @author 3F Protocol
/// @notice Interface every Retargetter execution module must implement.
/// @dev The name is "flash-loan module" by convention but the abstraction is intentionally broader:
///      a module is any contract that orchestrates a single Retargetter proposal end-to-end. It may
///      source liquidity from a flash-loan provider (Morpho, Aave, ...), drive a synchronous
///      IFund commit/unlock cycle, or simply pre-stage approvals before the proposal's actions run.
///
///      Lifecycle (driven by {RetargetterProposals.executeProposal}):
///        1. The Retargetter calls {executeProposal}(ctx). The module receives the full
///           {ModuleContext} (loan params it parses out of `moduleData`, the proposal's `actions`,
///           and the proposal's `receiver`).
///        2. The module sources whatever liquidity / state-of-the-world the proposal needs and
///           pushes any required tokens to the Retargetter (msg.sender of the original call).
///        3. The module calls `retargetter.executeProposalCallback(ctx.actions, ctx.receiver)`.
///           That call runs the proposal's actions atomically and reverts on any failure.
///        4. On return, the module pulls back any owed amount (typically via an allowance set by
///           the callback) and repays its underlying provider.
///
///      Security expectations:
///        - The module MUST be on the Retargetter's whitelist; otherwise the outer call reverts.
///        - The module MUST relay `ctx.actions` and `ctx.receiver` verbatim back to
///          {executeProposalCallback}. Substituting either is detectable because the Retargetter
///          authenticates the callback against the transient module context but does not re-check
///          the hash inside the callback; passing different actions is a trust violation.
///        - The module MUST be re-entry-safe; the Retargetter calls back synchronously and the
///          callback runs arbitrary `actions` which may themselves touch external contracts.
interface IFlashLoanModule {
  /// @notice Entry point invoked by the Retargetter for module-driven proposal execution.
  /// @dev Called exactly once per top-level {executeProposal}. The module is expected to call
  ///      `retargetter.executeProposalCallback(ctx.actions, ctx.receiver)` exactly once before
  ///      returning. The Retargetter clears the transient module context after this function
  ///      returns, so a second callback in the same transaction is rejected with
  ///      {LibRetargetterErrors.UnauthorisedCallback}.
  /// @param retargetter The Retargetter address (= msg.sender). Provided explicitly so the module
  ///        does not have to trust msg.sender alone.
  /// @param ctx The proposal context: parsed `moduleData`, the action list, and the receiver.
  function executeProposal(address retargetter, ModuleContext calldata ctx) external;
}
