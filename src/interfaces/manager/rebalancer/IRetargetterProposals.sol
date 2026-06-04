// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Action, Proposal} from "../../../libs/manager/rebalancer/Action.sol";

/// @title IRetargetterProposals
/// @author 3F Protocol
/// @notice Proposal surface of the Retargetter: propose (hash-commit), execute, cancel, callback.
/// @dev A proposal carries an ordered list of actions plus an optional module that may wrap the
///      execution in a flash loan / orchestration step. The hash binds (module, moduleData,
///      actions, receiver, salt) so the executor cannot substitute different actions later. Only
///      one proposal is pending at a time.
interface IRetargetterProposals {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           EVENTS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when a proposal is submitted.
  /// @param hash The proposal hash (= keccak256(abi.encode(proposal))).
  /// @param executableAt The earliest timestamp at which the proposal can be executed.
  event ProposalSubmitted(bytes32 indexed hash, uint40 executableAt);

  /// @notice Emitted when a proposal is cancelled.
  /// @param hash The cancelled proposal's hash.
  event ProposalCancelled(bytes32 indexed hash);

  /// @notice Emitted when a proposal completes execution.
  /// @param hash The executed proposal's hash.
  /// @param module The module that drove execution (zero for direct execution).
  /// @param actionCount The number of actions in the proposal.
  event ProposalExecuted(bytes32 indexed hash, address indexed module, uint256 actionCount);

  /// @notice Emitted when a single action runs.
  /// @param hash The proposal hash for context.
  /// @param actionIndex The 0-based index of the action within the proposal.
  /// @param kind The action's discriminant (`uint8` cast of {ActionKind}).
  event ActionExecuted(bytes32 indexed hash, uint256 actionIndex, uint8 kind);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PROPOSE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Submits a proposal hash for later execution.
  /// @dev REBALANCER-only, blocked while paused. Reverts if a proposal is already pending. The
  ///      caller is trusted to keep the matching {Proposal} off-chain until execution.
  /// @param hash `keccak256(abi.encode(proposal))`.
  /// @return executableAt The timestamp at which {executeProposal} becomes callable.
  function propose(bytes32 hash) external returns (uint40 executableAt);

  /// @notice Cancels the pending proposal.
  /// @dev Owner or REBALANCER can call. Allowed while paused so governance can clear in-flight
  ///      state during incidents.
  function cancelProposal() external;

  /// @notice Executes the pending proposal.
  /// @dev REBALANCER-only, blocked while paused. Re-hashes `proposal` and compares against the
  ///      stored hash. With no module, runs the actions directly; otherwise, hands control to the
  ///      module via {IFlashLoanModule.executeProposal} which is expected to re-enter via
  ///      {executeProposalCallback} exactly once.
  /// @param proposal The full proposal payload.
  function executeProposal(Proposal calldata proposal) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CALLBACK                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Re-entry point used by an in-flight module to run the proposal's actions.
  /// @dev Reverts unless the caller matches the transient module context set by
  ///      {executeProposal}. The action list and receiver must be the ones the module received in
  ///      its {ModuleContext}; this function does not re-check the proposal hash, so passing
  ///      different actions is a trust violation by the module.
  /// @param actions The action list to execute.
  /// @param receiver The receiver to sweep residuals to.
  function executeProposalCallback(Action[] calldata actions, address receiver) external;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the pending proposal's state in one call.
  /// @return active Whether a proposal is currently pending.
  /// @return hash The stored hash of the pending proposal (zero if none).
  /// @return executableAt The timestamp at which the pending proposal becomes executable.
  function proposalInfo() external view returns (bool active, bytes32 hash, uint40 executableAt);
}
