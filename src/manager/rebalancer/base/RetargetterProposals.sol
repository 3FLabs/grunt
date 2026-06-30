// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IRetargetterProposals} from "../../../interfaces/manager/rebalancer/IRetargetterProposals.sol";
import {IFlashLoanModule} from "../../../interfaces/manager/rebalancer/IFlashLoanModule.sol";
import {Action, Proposal, ModuleContext} from "../../../libs/manager/rebalancer/Action.sol";
import {RetargetterBase} from "./RetargetterBase.sol";
import {LibRetargetter, RetargetterStorage, ProposalState} from "../../../libs/manager/rebalancer/LibRetargetter.sol";
import {LibRetargetterErrors} from "../../../libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibRetargetterActions} from "../../../libs/manager/rebalancer/LibRetargetterActions.sol";
import {REBALANCER_ROLE} from "../../../libs/manager/rebalancer/LibRetargetterConstants.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";

/// @title RetargetterProposals
/// @author 3F Protocol
/// @notice Hash-committed, timelocked proposal lifecycle for the Retargetter.
/// @dev A proposal is `keccak256(abi.encode(Proposal))`. The hash is committed at {propose}, the
///      timelock elapses, then {executeProposal} is called with the full proposal payload. If the
///      proposal carries a non-zero `module`, the Retargetter delegates orchestration to that
///      module which re-enters via {executeProposalCallback} to run the actions. Otherwise the
///      actions run inline.
abstract contract RetargetterProposals is IRetargetterProposals, RetargetterBase {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PROPOSE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterProposals
  function propose(bytes32 hash)
    external
    override
    onlyRoles(REBALANCER_ROLE)
    whenNotPaused
    returns (uint40 executableAt)
  {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (s.proposal.active) revert LibRetargetterErrors.ProposalAlreadyPending();

    // Safe: block.timestamp fits in uint40 for ~35,000 years; proposalTimelock is bounded by
    // MAX_PROPOSAL_TIMELOCK.
    // forge-lint: disable-next-line(unsafe-typecast)
    executableAt = uint40(block.timestamp) + s.config.proposalTimelock;

    s.proposal = ProposalState({hash: hash, active: true, executableAt: executableAt});

    emit ProposalSubmitted(hash, executableAt);
  }

  /// @inheritdoc IRetargetterProposals
  /// @dev Cancellation is allowed even while paused; pausing is exactly the situation in which
  ///      governance needs to tear down an in-flight proposal.
  function cancelProposal() external override onlyOwnerOrRoles(REBALANCER_ROLE) {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.proposal.active) revert LibRetargetterErrors.NoPendingProposal();
    bytes32 hash = s.proposal.hash;
    _clearProposal(s);
    emit ProposalCancelled(hash);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EXECUTE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterProposals
  /// @dev Intentionally not `nonReentrant`: a module-driven execution re-enters via
  ///      {executeProposalCallback} synchronously. Re-entrancy protection comes from the
  ///      moduleContext transient slot plus the proposalActive flag (cleared before any external
  ///      call). A second {executeProposal} call inside the module would see
  ///      `proposalActive == false` and revert with {NoPendingProposal}.
  function executeProposal(Proposal calldata proposal) external override onlyRoles(REBALANCER_ROLE) whenNotPaused {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.proposal.active) revert LibRetargetterErrors.NoPendingProposal();
    if (block.timestamp < s.proposal.executableAt) revert LibRetargetterErrors.ProposalTimelockNotElapsed();
    if (keccak256(abi.encode(proposal)) != s.proposal.hash) revert LibRetargetterErrors.ProposalHashMismatch();

    address module = proposal.module;
    if (module != address(0) && !s.modules.contains(module)) revert LibRetargetterErrors.UnauthorisedModule();

    bytes32 hash = s.proposal.hash;
    // Effects: clear the proposal slot before any external call so a downstream contract that
    // attempted to call {executeProposal} again during interactions would see no pending
    // proposal.
    _clearProposal(s);

    if (module == address(0)) {
      LibRetargetterActions.runActions(proposal.actions, proposal.receiver);
    } else {
      _runWithModule(module, proposal);
    }

    emit ProposalExecuted(hash, module, proposal.actions.length);
  }

  /// @dev Hands control to `module` after staging the transient context. Verifies the module
  ///      called {executeProposalCallback} exactly once before returning.
  function _runWithModule(address module, Proposal calldata proposal) private {
    if (LibRetargetter.moduleContext() != address(0)) revert LibRetargetterErrors.NestedModuleExecution();
    LibRetargetter.setModuleContext(module);

    ModuleContext memory ctx =
      ModuleContext({moduleData: proposal.moduleData, actions: proposal.actions, receiver: proposal.receiver});
    IFlashLoanModule(module).executeProposal(address(this), ctx);

    // The callback clears the transient context. If it's still set, the module returned without
    // invoking the callback and the proposal must be treated as failed.
    if (LibRetargetter.moduleContext() != address(0)) revert LibRetargetterErrors.CallbackNotInvoked();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CALLBACK                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterProposals
  /// @dev Intentionally not `nonReentrant`: this IS the reentry point. Authentication is via the
  ///      transient moduleContext slot. The slot is cleared at the top of this function so that
  ///      any further callback attempt from inside the action sequence reverts with
  ///      {NotInModuleExecution}.
  function executeProposalCallback(Action[] calldata actions, address receiver) external override {
    address module = LibRetargetter.moduleContext();
    if (module == address(0)) revert LibRetargetterErrors.NotInModuleExecution();
    if (msg.sender != module) revert LibRetargetterErrors.UnauthorisedCallback();

    // Defence-in-depth: an owner may have removed the module from the whitelist between the outer
    // call and this callback. Re-check before doing any work.
    if (!LibRetargetter.retargetterStorage().modules.contains(module)) {
      revert LibRetargetterErrors.UnauthorisedModule();
    }

    LibRetargetter.setModuleContext(address(0));

    LibRetargetterActions.runActions(actions, receiver);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            VIEWS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IRetargetterProposals
  function proposalInfo() external view override returns (bool active, bytes32 hash, uint40 executableAt) {
    ProposalState storage p = LibRetargetter.retargetterStorage().proposal;
    return (p.active, p.hash, p.executableAt);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          INTERNAL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Clears the pending-proposal slot. Single `delete` since {ProposalState} is all value-typed.
  function _clearProposal(RetargetterStorage storage s) private {
    delete s.proposal;
  }
}
