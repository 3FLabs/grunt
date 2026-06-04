// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {
  IPositionManagerRebalancing,
  RebalancingData
} from "../../../interfaces/manager/base/IPositionManagerRebalancing.sol";
import {IPositionManager} from "../../../interfaces/manager/IPositionManager.sol";
import {IRequest} from "../../../interfaces/request/IRequest.sol";
import {IRequestInteractions} from "../../../interfaces/request/IRequestInteractions.sol";
import {IFund} from "../../../interfaces/funds/IFund.sol";
import {IERC20} from "../../../interfaces/integrations/IERC20.sol";
import {Order, Mode, State} from "../../funds/Order.sol";
import {Action, ActionKind} from "./Action.sol";
import {LibRetargetter, RetargetterStorage, BatchEntry} from "./LibRetargetter.sol";
import {LibRetargetterErrors} from "./LibRetargetterErrors.sol";
import {EnumerableSetLib} from "lib/solady/src/utils/EnumerableSetLib.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";

/// @title LibRetargetterActions
/// @author 3F Protocol
/// @notice Decodes and dispatches every {Action} variant inside a Retargetter proposal.
/// @dev Every function is `internal` so the call sites inline the library bytecode into the
///      calling contract. State changes (approvals, transfers, etc.) therefore mutate the
///      *contract*'s storage / approvals, not the library's. `msg.sender` and `address(this)` are
///      preserved as well, so calls to PositionManagers / Requests / Funds appear to come from the
///      Retargetter as expected.
///
///      Authority model:
///        - REBALANCE / PULL_REQUEST / REPAY_REQUEST verify the target is part of the open batch.
///        - FUND_* operate solely on the fund attached to the batch at {openBatch}; there is no
///          per-action fund address. The batch tracks a single in-flight order, created with
///          `order.owner == order.receiver == address(this)` so output cannot be exfiltrated, and
///          the order is what {closeBatch} inspects before detaching the fund.
///        - TRANSFER sends `amount` of `token` to the proposal's `receiver`, so the rebalancer
///          chooses the destination at propose time (and it gets hash-committed).
library LibRetargetterActions {
  using EnumerableSetLib for EnumerableSetLib.AddressSet;
  using SafeTransferLib for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DISPATCH                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Runs every action in `actions` in order. Forwards `receiver` to TRANSFER actions.
  ///      External (not internal) so this library is deployed separately and the calling contract
  ///      reaches it via DELEGATECALL: keeps the action-dispatch bytecode out of the Retargetter
  ///      under the EIP-170 24KB limit while preserving msg.sender, address(this), and storage
  ///      relative to the Retargetter.
  /// @param actions The action list to execute.
  /// @param receiver The receiver for TRANSFER sweep actions.
  function runActions(Action[] calldata actions, address receiver) external {
    uint256 len = actions.length;
    for (uint256 i; i < len; ++i) {
      _runAction(actions[i], receiver);
    }
  }

  function _runAction(Action calldata action, address receiver) private {
    ActionKind kind = action.kind;
    if (kind == ActionKind.REBALANCE) {
      _doRebalance(action.payload);
    } else if (kind == ActionKind.PULL_REQUEST) {
      _doPullRequest(action.payload);
    } else if (kind == ActionKind.REPAY_REQUEST) {
      _doRepayRequest(action.payload);
    } else if (kind == ActionKind.FUND_CREATE) {
      _doFundCreate(action.payload);
    } else if (kind == ActionKind.FUND_CANCEL) {
      _doFundCancel();
    } else if (kind == ActionKind.FUND_COMMIT) {
      _doFundCommit(action.payload);
    } else if (kind == ActionKind.FUND_UNLOCK) {
      _doFundUnlock();
    } else if (kind == ActionKind.FUND_RECOVER) {
      _doFundRecover();
    } else if (kind == ActionKind.TRANSFER) {
      _doTransfer(action.payload, receiver);
    } else if (kind == ActionKind.APPROVE) {
      _doApprove(action.payload);
    } else {
      revert LibRetargetterErrors.UnknownActionKind();
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         REBALANCE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Approves the PM for `data.collateral` / `data.debt`, calls rebalance, then scrubs
  ///      approvals. Excess collateral / debt are kept on the Retargetter so the following actions
  ///      can consume or sweep them.
  function _doRebalance(bytes calldata payload) private {
    (address positionManager, RebalancingData memory data) = abi.decode(payload, (address, RebalancingData));

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.batch.positionManagers.contains(positionManager)) revert LibRetargetterErrors.ActionTargetNotInBatch();

    address collateralAsset = s.config.collateralAsset;
    address debtAsset = s.config.debtAsset;

    if (data.collateral > 0) collateralAsset.safeApproveWithRetry(positionManager, data.collateral);
    if (data.debt > 0) debtAsset.safeApproveWithRetry(positionManager, data.debt);

    IPositionManagerRebalancing(positionManager).rebalance(data, address(this));

    if (data.collateral > 0) collateralAsset.safeApprove(positionManager, 0);
    if (data.debt > 0) debtAsset.safeApprove(positionManager, 0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       REQUEST OPS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Pulls `amount` of debt asset from the batch Request to the Retargetter.
  function _doPullRequest(bytes calldata payload) private {
    (address request, uint256 amount) = abi.decode(payload, (address, uint256));

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.batch.requests.contains(request)) revert LibRetargetterErrors.ActionTargetNotInBatch();

    IRequestInteractions(request).pullFunds(amount, "");
  }

  /// @dev Tops up `amount` of debt asset to a batch Request and marks it repaid. The action
  ///      payload's `[minBalance, maxBalance]` make any over / under-repayment fail loudly: the
  ///      proposal reverts and the owner has to step in to fix it manually.
  function _doRepayRequest(bytes calldata payload) private {
    (address request, uint256 amount, uint256 minBalance, uint256 maxBalance) =
      abi.decode(payload, (address, uint256, uint256, uint256));

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    if (!s.batch.requests.contains(request)) revert LibRetargetterErrors.ActionTargetNotInBatch();

    if (amount > 0) s.config.debtAsset.safeTransfer(request, amount);
    IRequest(request).setRepaid(minBalance, maxBalance);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          FUND OPS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Creates an order against the batch's attached fund and records it as the single
  ///      in-flight order. Requires a fund to be attached, no live order, and
  ///      `order.owner == order.receiver == address(this)` so unlock / recover output flows back
  ///      to the Retargetter rather than an attacker-controlled address.
  function _doFundCreate(bytes calldata payload) private {
    Order memory order = abi.decode(payload, (Order));

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    address fund = s.batch.fund;
    if (fund == address(0)) revert LibRetargetterErrors.NoBatchFund();
    if (LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.FundOrderAlreadyActive();
    if (order.owner != address(this) || order.receiver != address(this)) {
      revert LibRetargetterErrors.FundOrderOwnershipInvalid();
    }

    IFund(fund).create(order);
    s.batch.order = order;
  }

  /// @dev Cancels the batch's in-flight order and clears it. The fund stays attached.
  function _doFundCancel() private {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    address fund = s.batch.fund;
    if (fund == address(0)) revert LibRetargetterErrors.NoBatchFund();
    if (!LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.NoActiveFundOrder();

    IFund(fund).cancel(s.batch.order);
    delete s.batch.order;
  }

  /// @dev Approves the fund for `approveAmount` of the stored order's input token, commits, then
  ///      scrubs any residual approval. DEPOSIT orders take `asset`; REDEEM orders take `share`.
  function _doFundCommit(bytes calldata payload) private {
    uint256 approveAmount = abi.decode(payload, (uint256));

    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    address fund = s.batch.fund;
    if (fund == address(0)) revert LibRetargetterErrors.NoBatchFund();
    if (!LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.NoActiveFundOrder();

    Order memory order = s.batch.order;
    address inputToken = order.mode == Mode.DEPOSIT ? IFund(fund).asset() : IFund(fund).share();
    if (approveAmount > 0) inputToken.safeApproveWithRetry(fund, approveAmount);

    IFund(fund).commit(order);

    if (approveAmount > 0) inputToken.safeApprove(fund, 0);
  }

  /// @dev Unlocks the stored order; clears it when the fund reports {State.ENDED}.
  function _doFundUnlock() private {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    address fund = s.batch.fund;
    if (fund == address(0)) revert LibRetargetterErrors.NoBatchFund();
    if (!LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.NoActiveFundOrder();

    (State state,) = IFund(fund).unlock(s.batch.order);
    if (state == State.ENDED) delete s.batch.order;
  }

  /// @dev Recovers the stored order's input; clears it when the fund reports {State.ENDED}.
  function _doFundRecover() private {
    RetargetterStorage storage s = LibRetargetter.retargetterStorage();
    address fund = s.batch.fund;
    if (fund == address(0)) revert LibRetargetterErrors.NoBatchFund();
    if (!LibRetargetter.hasFundOrder(s)) revert LibRetargetterErrors.NoActiveFundOrder();

    (State state,) = IFund(fund).recover(s.batch.order);
    if (state == State.ENDED) delete s.batch.order;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          TRANSFER                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Transfers `amount` of `token` to `receiver`. If `amount == type(uint256).max`, transfers
  ///      the full Retargetter balance (which may be zero, a no-op).
  function _doTransfer(bytes calldata payload, address receiver) private {
    (address token, uint256 amount) = abi.decode(payload, (address, uint256));
    if (amount == type(uint256).max) {
      token.safeTransferAll(receiver);
    } else if (amount > 0) {
      token.safeTransfer(receiver, amount);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          APPROVE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Sets `spender`'s allowance over `token` from the Retargetter. `amount == 0` revokes.
  ///      Use {SafeTransferLib.safeApproveWithRetry} so tokens that require a zero-out before a
  ///      non-zero re-approval (e.g., USDT) work transparently.
  function _doApprove(bytes calldata payload) private {
    (address token, address spender, uint256 amount) = abi.decode(payload, (address, address, uint256));
    if (amount == 0) {
      token.safeApprove(spender, 0);
    } else {
      token.safeApproveWithRetry(spender, amount);
    }
  }
}
