// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {RebalancingData} from "../../../interfaces/manager/base/IPositionManagerRebalancing.sol";
import {Order} from "../../funds/Order.sol";

/// @notice Discriminant for the tagged union {Action}.
/// @dev Action kinds are intentionally narrow: the Retargetter dispatches on `kind` and decodes
///      `payload` accordingly. Adding a new kind requires updating the executor library.
enum ActionKind {
  /// @notice Rebalance a PositionManager.
  /// @custom:payload (address positionManager, RebalancingData data)
  /// @custom:semantics Pulls `data.collateral` / `data.debt` from the Retargetter's balance, executes
  ///                   the PM's rebalance, and forwards any excess back to the Retargetter so the
  ///                   following actions can consume it.
  REBALANCE,
  /// @notice Pull funds from a batch Request to the Retargetter.
  /// @custom:payload (address request, uint256 amount)
  /// @custom:semantics Calls `Request.pullFunds(amount, "")`. The request must belong to the open
  ///                   batch. Used after consumption to bring debt asset into the Retargetter.
  PULL_REQUEST,
  /// @notice Top up and mark a batch Request as repaid.
  /// @custom:payload (address request, uint256 amount, uint256 minBalance, uint256 maxBalance)
  /// @custom:semantics Transfers `amount` debt asset to the Request then calls
  ///                   `Request.setRepaid(minBalance, maxBalance)`. `[minBalance, maxBalance]` makes
  ///                   over / under-repayments fail loudly so they require owner intervention.
  REPAY_REQUEST,
  /// @notice Create a fund order against the batch's attached fund.
  /// @custom:payload (Order order)
  /// @custom:semantics Reverts if no fund is attached to the batch or a live order already exists.
  ///                   Requires `order.owner == order.receiver == address(this)` so unlock/recover
  ///                   output cannot be exfiltrated. Calls `IFund.create(order)` and records the
  ///                   order as the batch's single in-flight order.
  FUND_CREATE,
  /// @notice Cancel the batch's in-flight fund order.
  /// @custom:payload () (empty)
  /// @custom:semantics Calls `IFund.cancel(order)` on the stored order and clears it. The fund
  ///                   stays attached to the batch (unlike the Facility, where cancel abandons the
  ///                   fund); detachment happens only at {closeBatch}.
  FUND_CANCEL,
  /// @notice Commit funds to the batch's accepted fund order.
  /// @custom:payload (uint256 approveAmount)
  /// @custom:semantics Pre-approves the fund for `approveAmount` of the stored order's input
  ///                   (asset for DEPOSIT, share for REDEEM), calls `IFund.commit(order)`, then
  ///                   scrubs the approval.
  FUND_COMMIT,
  /// @notice Claim the output of the batch's processed fund order.
  /// @custom:payload () (empty)
  /// @custom:semantics Calls `IFund.unlock(order)`; output lands on the Retargetter. Clears the
  ///                   stored order when the fund reports {State.ENDED}.
  FUND_UNLOCK,
  /// @notice Recover the input of the batch's failed fund order.
  /// @custom:payload () (empty)
  /// @custom:semantics Calls `IFund.recover(order)`. Clears the stored order on {State.ENDED}.
  FUND_RECOVER,
  /// @notice Sweep a token balance to a receiver.
  /// @custom:payload (address token, uint256 amount)
  /// @custom:semantics If `amount == type(uint256).max`, transfers the full Retargetter balance to
  ///                   the proposal's `receiver`; otherwise transfers exactly `amount`. Used to
  ///                   forward leftover funds at the end of a proposal, or to push the loan back
  ///                   to a push-style flash-loan module (with `receiver == module`).
  TRANSFER,
  /// @notice Grant a spender an ERC20 allowance.
  /// @custom:payload (address token, address spender, uint256 amount)
  /// @custom:semantics Issues `safeApproveWithRetry(spender, amount)` for `amount > 0`, or
  ///                   `safeApprove(spender, 0)` to revoke. Used inside the callback to let a
  ///                   pull-style flash-loan module pull back the loan via transferFrom.
  APPROVE
}

/// @notice A single step inside a Retargetter proposal.
/// @dev Tagged union: `kind` selects how `payload` is decoded. Kept generic to avoid combinatorial
///      explosion of typed arrays in {Proposal}. Encoded with `abi.encode` so calldata layout is
///      stable across compiler versions.
struct Action {
  ActionKind kind;
  bytes payload;
}

/// @notice The full payload of a Retargetter proposal.
/// @dev Hashed at propose time and re-hashed at execute time to ensure the rebalancer cannot
///      substitute different actions after the timelock has elapsed. Field order is fixed; do not
///      reorder without invalidating in-flight proposals.
/// @param module Optional flash-loan / orchestration module. `address(0)` means the actions are
///        executed directly inside {executeProposal}; otherwise the module receives control and is
///        expected to call {executeProposalCallback} with the same `actions` and `receiver`.
/// @param moduleData Opaque calldata handed to the module (e.g., loan amount, asset, callback hooks).
///        Ignored when `module == address(0)`.
/// @param actions The ordered list of steps to run. Order is significant: pulls must precede
///        commits, rebalances must precede repayments, etc.
/// @param receiver Address that receives any residual collateral / debt at the end of execution.
///        The actions themselves may also reference this address through their payloads.
/// @param salt Free-form bytes32 that lets the rebalancer differentiate two otherwise-identical
///        proposals (e.g., re-submitting after a cancel). Has no on-chain semantics beyond changing
///        the hash.
struct Proposal {
  address module;
  bytes moduleData;
  Action[] actions;
  address receiver;
  bytes32 salt;
}

/// @notice Payload bundle handed to a flash-loan / orchestration module at execution time.
/// @dev Defined here so the module ABI is shared with the Retargetter without a circular import.
///      The module is expected to source liquidity (or otherwise set the stage) and then call back
///      into the Retargetter, passing the `actions` and `receiver` it received, so the proposal's
///      hash-binding still holds across the indirection.
/// @param moduleData Opaque calldata forwarded from the proposal.
/// @param actions The proposal's actions list, to be relayed back via {executeProposalCallback}.
/// @param receiver The proposal's receiver address.
struct ModuleContext {
  bytes moduleData;
  Action[] actions;
  address receiver;
}
