// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardTransient} from "lib/solady/src/utils/ReentrancyGuardTransient.sol";
import {FacilityRoles} from "./FacilityRoles.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IFacilityFunds} from "src/interfaces/facility/base/IFacilityFunds.sol";
import {IFund} from "src/interfaces/funds/IFund.sol";
import {LibIntent, Intent} from "src/libs/facility/LibIntent.sol";
import {LibStorage, FacilityStorageData} from "src/libs/facility/LibStorage.sol";
import {LibErrors} from "src/libs/facility/LibErrors.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

/// @title FacilityFunds
/// @author 3F Protocol
/// @notice Abstract contract implementing fund operations for intents.
/// @dev Allows creating, canceling, committing, unlocking, and recovering fund orders.
abstract contract FacilityFunds is IFacilityFunds, ReentrancyGuardTransient, FacilityRoles {
  using LibStorage for FacilityStorageData;
  using LibIntent for Intent;
  using SafeTransferLib for address;

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
    if (_fund == address(0)) revert LibErrors.MissingFund(id);

    // ensure the intent has no pending order
    _intent.checkNoPendingOrder(id);

    // create order with a block/id unique salt
    order = Order({
      owner: address(this),
      receiver: address(this),
      input: amount,
      output: minAmountOut,
      mode: mode,
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

    // commit the funds
    _tokenIn.safeApproveWithRetry(_fund, _order.input);
    IFund(_fund).commit(_order);
    // remove tokens from intent (since this is non reentrant, we can call this after sending the funds)
    _intent.transferredTokenTo(id, _tokenIn, _fund, _order.input);
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

    // unlock the funds
    (State _state, uint256 _unlockedAmount) = IFund(_fund).unlock(_order);
    // If this is the deposit, an unlock gives shares, otherwise it gives assets
    address _tokenOut = _order.mode == Mode.DEPOSIT ? IFund(_fund).share() : IFund(_fund).asset();

    // add tokens to intent
    _intent.receivedTokenFrom(id, _tokenOut, _fund, _unlockedAmount);

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

    // recover the funds
    (State _state, uint256 _recoveredAmount) = IFund(_fund).recover(_order);
    // If this is the deposit, a recover gives assets back, otherwise it gives shares back
    address _tokenIn = _order.mode == Mode.DEPOSIT ? IFund(_fund).asset() : IFund(_fund).share();

    // add tokens to intent
    _intent.receivedTokenFrom(id, _tokenIn, _fund, _recoveredAmount);

    if (_state == State.ENDED) {
      // if the order is ended, delete the order
      _intent.removeOrderAndFund(id);
    }
  }
}
