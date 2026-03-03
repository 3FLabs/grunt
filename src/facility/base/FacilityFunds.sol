// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FacilityRoles} from "./FacilityRoles.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IFacilityFunds} from "src/interfaces/facility/base/IFacilityFunds.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {LibIntent, Intent, BalanceSnapshot} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {Order, Mode, State, LibOrder} from "src/libs/funds/Order.sol";

/// @title FacilityFunds
/// @author 3F Protocol
/// @notice Abstract contract implementing fund operations for intents.
/// @dev Allows creating, canceling, committing, unlocking, and recovering fund orders.
abstract contract FacilityFunds is IFacilityFunds, ReentrancyGuardTransient, FacilityRoles {
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using SafeTransferLib for address;
  using LibOrder for Order;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityFunds
  function getOrder(uint256 id) external view override returns (Order memory order, bytes32 orderId) {
    Intent storage _intent = LibStorage.facilityStorage().getIntent(id);
    order = _intent.order;
    orderId = order.toId(_intent.fund);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FUND OPERATIONS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IFacilityFunds
  /// @dev Creates a fund order for the intent. The intent must be in resolving state
  ///      and must not have an active order. The order is stored in the intent for later operations.
  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode)
    external
    override
    onlyRoles(FACILITATOR_ROLE)
    nonReentrant
    returns (Order memory order)
  {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // checks that the intent has a fund
    address _fund = _intent.fund;
    if (_fund == address(0)) revert LibFacilityErrors.MissingFund(id);

    // ensure the intent has no pending order
    _intent.checkNoPendingOrder(id);

    // create order with a block/id unique salt
    order = Order({
      mode: mode,
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: minAmountOut,
      salt: keccak256(abi.encode(address(this), block.timestamp, id))
    });
    emit CreatingOrder(id, order.toId(_fund));
    IFund(_fund).create(order);

    // update order in intent
    _intent.order = order;
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Cancels the current fund order for the intent.
  ///      The intent must have an active order.
  function cancel(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // ensure the intent has an active order
    _intent.checkActiveOrder(id);

    // cancel order with the fund and delete it from the intent
    IFund(_intent.fund).cancel(_intent.order);
    _intent.removeOrderAndFund(id);
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Commits the current fund order for the intent.
  ///      Transfers the input tokens to the fund and calls commit on it.
  ///      The intent must have an active order.
  function commit(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // ensure the intent has an active order
    _intent.checkActiveOrder(id);

    // get the order and token to deposit
    Order memory _order = _intent.order;
    address _fund = _intent.fund;
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_fund).asset() : IFund(_fund).share();

    // take snapshot before the operation
    BalanceSnapshot memory snapshot = LibIntent.takeBalanceSnapshot(_tokenIn);

    // commit the funds
    _tokenIn.safeApproveWithRetry(_fund, _order.input);
    (, uint256 _committedAmount) = IFund(_fund).commit(_order);
    if (_committedAmount != _order.input) {
      revert LibFacilityErrors.CommitAmountMismatch(id, _order.input, _committedAmount);
    }
    // reset approval to 0
    _tokenIn.safeApproveWithRetry(_fund, 0);

    // commit snapshot to record the balance change
    _intent.commitBalanceSnapshot(id, snapshot, _fund);
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Unlocks the current fund order for the intent.
  ///      Receives the output tokens from the fund after successful processing.
  ///      Deletes the order if the state reaches ENDED.
  function unlock(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // ensure the intent has an active order
    _intent.checkActiveOrder(id);

    Order memory _order = _intent.order;
    address _fund = _intent.fund;
    // If this is the deposit, an unlock gives shares, otherwise it gives assets
    address _tokenOut = _order.mode == Mode.DEPOSIT ? IFund(_fund).share() : IFund(_fund).asset();

    // take snapshot before the operation
    BalanceSnapshot memory snapshot = LibIntent.takeBalanceSnapshot(_tokenOut);

    // unlock the funds
    (State _state,) = IFund(_fund).unlock(_order);

    // commit snapshot to record the balance change
    _intent.commitBalanceSnapshot(id, snapshot, _fund);

    if (_state == State.ENDED) {
      // if the order is ended, delete the order
      _intent.removeOrderAndFund(id);
    }
  }

  /// @inheritdoc IFacilityFunds
  /// @dev Recovers assets from the current fund order for the intent after failed processing.
  ///      Receives the input tokens back from the fund.
  ///      Deletes the order if the state reaches ENDED.
  function recover(uint256 id) external override onlyRoles(FACILITATOR_ROLE) nonReentrant {
    LibStorage.checkNotPaused();
    Intent storage _intent = LibStorage.facilityStorage().getResolvingIntent(id);

    // ensure the intent has an active order
    _intent.checkActiveOrder(id);

    Order memory _order = _intent.order;
    address _fund = _intent.fund;
    // If this is the deposit, a recover gives assets back, otherwise it gives shares back
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_fund).asset() : IFund(_fund).share();

    // take snapshot before the operation
    BalanceSnapshot memory snapshot = LibIntent.takeBalanceSnapshot(_tokenIn);

    // recover the funds
    (State _state,) = IFund(_fund).recover(_order);

    // commit snapshot to record the balance change
    _intent.commitBalanceSnapshot(id, snapshot, _fund);

    if (_state == State.ENDED) {
      // if the order is ended, delete the order
      _intent.removeOrderAndFund(id);
    }
  }
}
